--!strict
--[[
	Combat training dummies: throwaway Combatants for measuring damage,
	exercising `Combat.canEngage` bracket refusal, and driving the
	defender-side cast bar, none of which has ever run against a real target
	in this project. A dummy is registered through CombatService's Combatant
	API (registerCombatant/resetCombatantHealth/dummyCast) and takes damage through
	the exact same resolution and damage functions a player does -- there is
	no dummy-specific combat logic here, only spawning, patrol, and the
	auto-reset poll.

	Deliberately has no Humanoid. `mirrorHumanoid` already treats a nil
	Humanoid as a no-op, and once a real Humanoid's Health crosses to zero it
	locks into the Dead state and cannot be revived by setting Health back up
	-- fatal for something that needs to reset continuously rather than
	respawn. The visible health readout is the Health/MaxHealth attributes
	`publishHealth` already writes unconditionally, which is also exactly
	what interface's Nameplates reads, so nothing about the dummy's health is
	lost by skipping the Humanoid. The "moving" variant patrols by lerping
	the root's CFrame directly rather than Humanoid:MoveTo, for the same
	reason and because a two-point back-and-forth needs no pathfinding.

	Summon and dismiss are a TextChatCommand (`/dummy stationary|moving|caster
	[stage] [techId] [ahead]`, `/dummy clear`) so this needs no client work:
	type `/dummy stationary lowgold` and one is standing near the pad. A
	command rather than a plain chat message for two reasons: this place uses
	TextChatService, under which the legacy `Player.Chatted` event this
	originally used does not fire at all; and a command does not broadcast
	to every other player's chat window the way a parsed chat message would.

	The trailing `ahead` places the dummy on the CALLER's own centre ray
	(root position plus root LookVector, five studs out) instead of the
	fixed row, and shapes it as a ground-anchored ten-stud POST rather than
	the row's 5-stud slab -- the only way to get a lockable target when the
	input surface reaching this place is keyboard only, confirmed by
	landscape: world clicks and a synthetic camera drag do not reach the
	game, and the slab's own height was too short to catch a default-
	pitched centre ray even on the yaw it did land on.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")
local Workspace = game:GetService("Workspace")

local Combat = require(ReplicatedStorage.Shared.Combat)
local Config = require(ReplicatedStorage.Shared.Config)
local ArenaService = require(script.Parent.ArenaService)
local CombatService = require(script.Parent.CombatService)

local DummyService = {}

type Kind = "stationary" | "moving" | "caster"

type Dummy = {
	kind: Kind,
	model: Model,
	root: BasePart,
	actor: Combat.Actor,
	patrolA: Vector3?,
	patrolB: Vector3?,
	patrolPeriod: number?,
	patrolPhase: number?,
	techId: string?,
	nextCastAt: number?,
	resetAt: number?,
}

local dummies: { Dummy } = {}
local spawnCount = 0

local DUMMIES_FOLDER_NAME = "Dummies"
local DEFAULT_STAGE = "Foundation"
--[[ The original -108 was chosen for "a few strides north of the pad and
	into the open field, not on top of it" -- an intent, not a checked
	outcome. It put the row beside the ramp on open dirt twenty studs below
	eye level (dummy one) and fourteen studs under the ramp's surface
	(dummies two through four): landscape verified on the live published
	place that /dummy worked end to end and a player standing on the pad
	still saw nothing. -60 is landscape's own number: eighteen studs past
	the ramp foot at -78, on the plate at y = 3, forty-four studs clear of
	the nearest region-lobe edge (so a row here reads consistent ruler
	damage, not a straddled-edge artifact), directly ahead of a player
	walking down the ramp, none of the five row slots under anything. ]]
local BASE_POSITION = Vector3.new(0, 0, -60)
local ROW_SPACING = 10
local ROW_WIDTH = 5

local PATROL_RADIUS = 12
local PATROL_PERIOD = 6 -- seconds for one full A -> B -> A cycle

-- Independent of the technique's own cooldown -- `dummyCast` is a scripted
-- loop, not gated by `Combat.use`, so cadence is entirely DummyService's call.
local CAST_INTERVAL = 5
local INITIAL_CAST_DELAY = 2
-- Ruler, 0.9s+ windup, so the telegraphed cast reliably draws a defender-side
-- cast bar rather than resolving too fast to see one.
local DEFAULT_CASTER_TECH = "tempest"

local RESET_DELAY = 1.5 -- seconds a dummy sits at zero before it comes back up

local STATIONARY_COLOR = Color3.fromRGB(90, 170, 230)
local MOVING_COLOR = Color3.fromRGB(230, 170, 90)
local CASTER_COLOR = Color3.fromRGB(200, 90, 200)

local function ensureFolder(): Folder
	local existing = Workspace:FindFirstChild(DUMMIES_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = DUMMIES_FOLDER_NAME
	folder.Parent = Workspace
	return folder
end

local function stageIndexOf(stageName: string?): number
	local target = string.lower(stageName or DEFAULT_STAGE)
	for i, stage in Config.Stages do
		if string.lower(stage.name) == target then
			return i
		end
	end
	return 1
end

local function nextSpawnPosition(): Vector3
	spawnCount += 1
	local column = (spawnCount - 1) % ROW_WIDTH
	local row = math.floor((spawnCount - 1) / ROW_WIDTH)
	local flat = BASE_POSITION
		+ Vector3.new((column - (ROW_WIDTH - 1) / 2) * ROW_SPACING, 0, row * ROW_SPACING)
	local groundY = ArenaService.groundYAt(flat)
	return Vector3.new(flat.X, (groundY or flat.Y) + 3, flat.Z)
end

--[[ Five studs, not six: six was tuned for YAW alone (root facing landing
	the ray's X/Z), and landscape found it misses on PITCH -- the aim ray
	leaves the root along the camera look, pitched down by default, and at
	six studs it passes under a 5-stud slab centred at root height. A
	synthetic camera drag cannot level the pitch to compensate (seven tries,
	uncontrollable), so the target has to cover the pitch instead of the
	camera controlling it. ]]
local AHEAD_DISTANCE = 5

-- Ground to about ten studs tall rather than the row's 5-stud slab
-- centred at root height: from a root three studs up, five out, this
-- covers any downward pitch to about 30 degrees and upward to about 50.
-- Nothing under test cares about the target's height -- the lock is a
-- raycast hit, the send is an id, the channel and projectile aim at the
-- root, the slow scales the lerp -- the post only decides whether the ray
-- lands at all.
local AHEAD_POST_HEIGHT = 10
local AHEAD_POST_SIZE = Vector3.new(2, AHEAD_POST_HEIGHT, 1)

--[[ The centre of the post to place, or nil to fall back to the row --
	ground-anchored rather than root-height, so the post's bottom actually
	sits on the ground instead of floating or clipping into it. Placement,
	not a targeting shortcut: this only decides where a dummy appears, never
	sends a cast or a lock on the caller's behalf. ]]
local function anchorFor(aheadOf: Player?): Vector3?
	if not aheadOf then
		return nil
	end
	local character = aheadOf.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	local aheadPoint = root.Position + root.CFrame.LookVector * AHEAD_DISTANCE
	local groundY = ArenaService.groundYAt(aheadPoint)
	local baseY = groundY or aheadPoint.Y
	return Vector3.new(aheadPoint.X, baseY + AHEAD_POST_HEIGHT / 2, aheadPoint.Z)
end

local function buildRig(displayName: string, color: Color3): (Model, BasePart)
	local model = Instance.new("Model")
	model.Name = "Dummy"

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 5, 1)
	root.Color = color
	root.Material = Enum.Material.Neon
	root.Anchored = true
	root.CanCollide = true
	root.TopSurface = Enum.SurfaceType.Smooth
	root.BottomSurface = Enum.SurfaceType.Smooth
	root.Parent = model

	model.PrimaryPart = root
	model:SetAttribute("DisplayName", displayName)

	return model, root
end

local function register(model: Model, root: BasePart, stageIndex: number, kind: Kind): Dummy?
	model.Parent = ensureFolder()
	local actor = CombatService.registerCombatant(model, stageIndex, "dummy")
	if not actor then
		warn(`[dummy] registerCombatant refused stage index {stageIndex}`)
		model:Destroy()
		return nil
	end
	local dummy: Dummy = { kind = kind, model = model, root = root, actor = actor }
	table.insert(dummies, dummy)
	return dummy
end

--[[ `aheadOf`, when given, places the dummy on that player's own centre ray
	instead of the fixed row, and resizes the root from the row's 5-stud
	slab to the ten-stud post -- the only way to get a dummy under a lock
	key when the input surface reaching this place is keyboard only
	(confirmed by landscape: world clicks and synthetic camera drag do not
	reach the game, and the row's own slab was too short to catch a
	default-pitched centre ray even where it landed on yaw). Falls back to
	the row, at the row's own slab size, if the caller's character is not
	resolvable, same as it always has. ]]
function DummyService.spawnStationary(stageName: string?, aheadOf: Player?)
	local model, root = buildRig("Training Dummy", STATIONARY_COLOR)
	local anchor = anchorFor(aheadOf)
	if anchor then
		root.Size = AHEAD_POST_SIZE
	end
	root.CFrame = CFrame.new(anchor or nextSpawnPosition())
	register(model, root, stageIndexOf(stageName), "stationary")
end

--[[ "Ahead" for the moving variant means the patrol STARTS on the caller's
	ray and crosses it, not merely that it exists somewhere nearby -- the
	lock has to be takeable before the dummy walks off. Reusing `center` as
	both the patrol's midpoint and the spawn position already gives this for
	free: phase starts at 0, which is t = 0.5, the exact midpoint between
	patrolA and patrolB -- so a fresh spawn is already standing at `center`,
	and the sine patrol crosses back through that same point every half
	cycle after. The post rides along at its own fixed elevation while
	patrolling; nothing under test reads the target's height, only its
	position and whether the lock ray reaches it. ]]
function DummyService.spawnMoving(stageName: string?, aheadOf: Player?)
	local model, root = buildRig("Training Dummy (Moving)", MOVING_COLOR)
	local anchor = anchorFor(aheadOf)
	if anchor then
		root.Size = AHEAD_POST_SIZE
	end
	local center = anchor or nextSpawnPosition()
	root.CFrame = CFrame.new(center)
	local dummy = register(model, root, stageIndexOf(stageName), "moving")
	if dummy then
		dummy.patrolA = center - Vector3.new(PATROL_RADIUS, 0, 0)
		dummy.patrolB = center + Vector3.new(PATROL_RADIUS, 0, 0)
		dummy.patrolPeriod = PATROL_PERIOD
	end
end

function DummyService.spawnCaster(stageName: string?, techId: string?, aheadOf: Player?)
	local tech = techId and Config.Techniques[techId]
	local resolvedTechId = if tech and tech.kind == "ruler"
		then techId :: string
		else DEFAULT_CASTER_TECH
	local model, root = buildRig("Training Dummy (Casting)", CASTER_COLOR)
	local anchor = anchorFor(aheadOf)
	if anchor then
		root.Size = AHEAD_POST_SIZE
	end
	root.CFrame = CFrame.new(anchor or nextSpawnPosition())
	local dummy = register(model, root, stageIndexOf(stageName), "caster")
	if dummy then
		dummy.techId = resolvedTechId
		dummy.nextCastAt = os.clock() + INITIAL_CAST_DELAY
	end
end

function DummyService.clearAll()
	local snapshot = table.clone(dummies)
	table.clear(dummies)
	for _, dummy in snapshot do
		CombatService.unregisterCombatant(dummy.model)
		dummy.model:Destroy()
	end
end

-- Shared across every dummy rather than per-dummy: all of them tick from
-- the same call, so one delta serves all, and a dummy spawned mid-session
-- starts at phase 0 without needing its own first-tick special case.
local lastTickAt: number? = nil

--[[ Patrol, cast scheduling, and the auto-reset poll, all in one pass so a
	dummy needs nothing from outside this file once spawned. Health is read
	off `actor` directly -- the same table `registerDummy` returned, mutated
	in place by every hit -- rather than through a CombatService getter,
	which is the reason `registerDummy` hands the actor back at all.

	Patrol is a phase accumulator now, not a stateless function of absolute
	time: the moving variant is the instrument a slow is measured against
	(a stationary lock target proves the lock, a moving one proves the
	slow), and a stateless sin(now / period) has no notion of "how far
	along" to scale down. Advancing phase by delta * slowMultiplierOf each
	tick means a slowed dummy visibly drags rather than continuing to patrol
	at full, unaffected speed. ]]
function DummyService.tick(now: number)
	local delta = if lastTickAt then now - lastTickAt else 0
	lastTickAt = now

	for _, dummy in dummies do
		if dummy.actor.health <= 0 then
			if not dummy.resetAt then
				dummy.resetAt = now + RESET_DELAY
			elseif now >= dummy.resetAt then
				CombatService.resetCombatantHealth(dummy.model)
				dummy.resetAt = nil
			end
			continue
		end

		if dummy.kind == "moving" and dummy.patrolA and dummy.patrolB and dummy.patrolPeriod then
			local a = dummy.patrolA :: Vector3
			local b = dummy.patrolB :: Vector3
			local period = dummy.patrolPeriod :: number
			local slow = Combat.slowMultiplierOf(dummy.actor, now)
			local phase = ((dummy.patrolPhase or 0) + (delta / period) * slow) % 1
			dummy.patrolPhase = phase
			local t = (math.sin(phase * math.pi * 2) + 1) / 2
			dummy.root.CFrame = CFrame.new(a:Lerp(b, t))
		elseif
			dummy.kind == "caster"
			and dummy.techId
			and dummy.nextCastAt
			and now >= dummy.nextCastAt
		then
			CombatService.dummyCast(dummy.model, dummy.techId)
			dummy.nextCastAt = now + CAST_INTERVAL
		end
	end
end

--[[ `ahead` is a trailing word rather than a fixed position, since the
	number of preceding args varies by kind (caster takes a tech id, the
	others don't) -- checking the last word rather than a fixed index handles
	all three without three separate parses. `handleCommand` already has
	`player`; passing it through as the placement anchor costs nothing new to
	the trust boundary, since it only ever affects where a dummy spawns. ]]
local function handleCommand(player: Player, message: string)
	local words = string.split(message, " ")
	local sub = words[2]
	local ahead = words[#words] == "ahead"
	local argEnd = if ahead then #words - 1 else #words
	local stageArg = if argEnd >= 3 then words[3] else nil
	local techArg = if argEnd >= 4 then words[4] else nil
	local aheadOf: Player? = if ahead then player else nil

	if sub == "stationary" then
		DummyService.spawnStationary(stageArg, aheadOf)
	elseif sub == "moving" then
		DummyService.spawnMoving(stageArg, aheadOf)
	elseif sub == "caster" then
		DummyService.spawnCaster(stageArg, techArg, aheadOf)
	elseif sub == "clear" then
		DummyService.clearAll()
	else
		warn(`[dummy] {player.Name} sent an unrecognized command: {message}`)
	end
end

--[[ A real TextChatCommand rather than Player.Chatted, which does not fire
	in this place -- confirmed by landscape with an oracle (the handler's own
	unrecognized-command warn never appeared in Output for a bogus command
	that visibly reached chat), and understood well enough rather than
	guessed: this place uses TextChatService, and Player.Chatted is the
	legacy chat path it leaves behind. A command instance also means /dummy
	no longer broadcasts to every other player's chat window the way a
	Chatted-based parse necessarily would have. ]]
function DummyService.start()
	local command = Instance.new("TextChatCommand")
	command.Name = "DummyCommand"
	command.PrimaryAlias = "/dummy"
	command.Parent = TextChatService

	command.Triggered:Connect(function(originTextSource: TextSource, message: string)
		local player = Players:GetPlayerByUserId(originTextSource.UserId)
		if player then
			handleCommand(player, message)
		end
	end)
end

return DummyService
