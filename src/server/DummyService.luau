--!strict
--[[
	Combat training dummies: throwaway Combatants for measuring damage,
	exercising `Combat.canEngage` bracket refusal, and driving the
	defender-side cast bar, none of which has ever run against a real target
	in this project. A dummy is registered through CombatService's Combatant
	API (registerDummy/resetDummyHealth/dummyCast) and takes damage through
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
	[stage] [techId]`, `/dummy clear`) so this needs no client work: type
	`/dummy stationary lowgold` and one is standing near the pad. A command
	rather than a plain chat message for two reasons: this place uses
	TextChatService, under which the legacy `Player.Chatted` event this
	originally used does not fire at all; and a command does not broadcast
	to every other player's chat window the way a parsed chat message would.
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
	local actor = CombatService.registerDummy(model, stageIndex)
	if not actor then
		warn(`[dummy] registerDummy refused stage index {stageIndex}`)
		model:Destroy()
		return nil
	end
	local dummy: Dummy = { kind = kind, model = model, root = root, actor = actor }
	table.insert(dummies, dummy)
	return dummy
end

function DummyService.spawnStationary(stageName: string?)
	local model, root = buildRig("Training Dummy", STATIONARY_COLOR)
	root.CFrame = CFrame.new(nextSpawnPosition())
	register(model, root, stageIndexOf(stageName), "stationary")
end

function DummyService.spawnMoving(stageName: string?)
	local model, root = buildRig("Training Dummy (Moving)", MOVING_COLOR)
	local center = nextSpawnPosition()
	root.CFrame = CFrame.new(center)
	local dummy = register(model, root, stageIndexOf(stageName), "moving")
	if dummy then
		dummy.patrolA = center - Vector3.new(PATROL_RADIUS, 0, 0)
		dummy.patrolB = center + Vector3.new(PATROL_RADIUS, 0, 0)
		dummy.patrolPeriod = PATROL_PERIOD
	end
end

function DummyService.spawnCaster(stageName: string?, techId: string?)
	local tech = techId and Config.Techniques[techId]
	local resolvedTechId = if tech and tech.kind == "ruler"
		then techId :: string
		else DEFAULT_CASTER_TECH
	local model, root = buildRig("Training Dummy (Casting)", CASTER_COLOR)
	root.CFrame = CFrame.new(nextSpawnPosition())
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
		CombatService.unregisterDummy(dummy.model)
		dummy.model:Destroy()
	end
end

--[[ Patrol, cast scheduling, and the auto-reset poll, all in one pass so a
	dummy needs nothing from outside this file once spawned. Health is read
	off `actor` directly -- the same table `registerDummy` returned, mutated
	in place by every hit -- rather than through a CombatService getter,
	which is the reason `registerDummy` hands the actor back at all. ]]
function DummyService.tick(now: number)
	for _, dummy in dummies do
		if dummy.actor.health <= 0 then
			if not dummy.resetAt then
				dummy.resetAt = now + RESET_DELAY
			elseif now >= dummy.resetAt then
				CombatService.resetDummyHealth(dummy.model)
				dummy.resetAt = nil
			end
			continue
		end

		if dummy.kind == "moving" and dummy.patrolA and dummy.patrolB and dummy.patrolPeriod then
			local a = dummy.patrolA :: Vector3
			local b = dummy.patrolB :: Vector3
			local t = (math.sin((now / (dummy.patrolPeriod :: number)) * math.pi * 2) + 1) / 2
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

local function handleCommand(player: Player, message: string)
	local words = string.split(message, " ")
	local sub = words[2]
	if sub == "stationary" then
		DummyService.spawnStationary(words[3])
	elseif sub == "moving" then
		DummyService.spawnMoving(words[3])
	elseif sub == "caster" then
		DummyService.spawnCaster(words[3], words[4])
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
