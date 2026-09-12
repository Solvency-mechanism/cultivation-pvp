--!strict
--[[
	Neutral patrolling NPCs -- the first thing in the world that is neither a
	player nor a command-spawned test rig. Boot-spawned from
	ArenaService.patrols(), each walks a multi-waypoint route (ping-pong or
	loop, per its own entry) and respawns to its route start after dying.

	Neutral in the MMO sense, corrected by the human: does NOT aggro on
	proximity, but DOES retaliate once hit. Built as CombatService's existing
	caster-dummy fire loop (dummyCast) behind a has-been-hit flag held here,
	flipped by CombatService.setNpcHitHandler -- the same injected-handler
	shape setKillHandler/setDrainedHandler/setRefusalHandler already use for
	every other cross-service signal in this codebase. Cleared once the
	attacker is dead or gone, checked via CombatService.isCombatantAlive.
	No threat table, no aggro radius, no target selection, no pathing.

	Built from the same parts DummyService already has -- registerCombatant,
	the negative combatant-id scheme, SlowMultiplier, no Humanoid, for
	exactly the reasons DummyService's own header gives (a real Humanoid's
	Health locks into Dead and cannot be revived, fatal for something that
	respawns rather than gets rebuilt) -- but as a separate service, not a
	third DummyService kind: an NPC's lifecycle (boot-spawned, permanent,
	respawns to a route start) shares too little with a dummy's
	(chat-spawned, ephemeral, resets in place) for one file to hold both
	without every existing DummyService function growing a kind check it
	never needed. Full argument in npcs.md's ruling 3.

	Has no bracket relation to anyone (npcs.md ruling 1): CombatService's
	damageCombatant and validateLockTarget both exempt an npc-kind
	combatant from the cross-bracket check entirely, on either side of a
	hit, so a Lance from any stage lands here with no bracket notice.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Combat = require(ReplicatedStorage.Shared.Combat)
local Config = require(ReplicatedStorage.Shared.Config)
local ArenaService = require(script.Parent.ArenaService)
local CombatService = require(script.Parent.CombatService)

local NpcService = {}

--[[ The placement-table shape confirmed in npcs.md: `stage` is a stage NAME
	string, resolved the same way `/dummy`'s own `[stage]` argument already
	is, and `pingPong` is a real per-entry choice, not a single stated
	default -- landscape's own routes need both traversal modes. Declared
	here rather than imported from `ArenaService.Patrol`: this is the
	contract both sides agreed to, and either side can point at this
	declaration if the other one drifts. ]]
export type Patrol = {
	name: string,
	region: string,
	stage: string,
	walkSpeed: number,
	pingPong: boolean,
	route: { Vector3 },
}

type Npc = {
	model: Model,
	root: BasePart,
	target: BasePart,
	actor: Combat.Actor,
	route: { Vector3 },
	pingPong: boolean,
	walkSpeed: number,
	waypointIndex: number,
	direction: number,
	hasBeenHit: boolean,
	attackerCombatantId: number?,
	nextCastAt: number?,
	deadAt: number?,
}

local npcs: { Npc } = {}
local npcFolder: Folder? = nil

local NPC_COLOR = Color3.fromRGB(120, 200, 150)
local ARRIVE_RADIUS = 2
local RESPAWN_SECONDS = 30

-- Independent of any technique's own cooldown, same reason DummyService's
-- own caster variant states this: dummyCast is a scripted loop, not gated
-- by Combat.use.
local RETALIATE_INTERVAL = 5
local RETALIATE_DELAY = 1.5
-- Ruler, so dummyCast will fire it (only kind == "ruler" is wired there).
local RETALIATE_TECH = "tempest"

local function ensureFolder(): Folder
	if npcFolder and npcFolder.Parent then
		return npcFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "Npcs"
	folder.Parent = Workspace
	npcFolder = folder
	return folder
end

local function stageIndexOf(stageName: string): number
	local target = string.lower(stageName)
	for i, stage in Config.Stages do
		if string.lower(stage.name) == target then
			return i
		end
	end
	return 1
end

--[[ Unanchored and constraint-driven, not a direct CFrame write, per the
	human's own live-session finding: an anchored part's CFrame replicates
	as discrete throttled property updates with no client interpolation, so
	a perfectly continuous server-side step() was still thrown away at the
	network boundary and read as teleporting. `target` is a separate,
	invisible, anchored part the tick moves along the route; `root` is
	unanchored and physics-driven toward it by AlignPosition (rigid --
	exact tracking, not spring lag, since the smoothing this fixes comes
	from the network layer interpolating an unanchored physics body, not
	from slack in the constraint) and AlignOrientation (bounded angular
	velocity, deliberately NOT rigid, so a ping-pong reversal turns over a
	fraction of a second instead of snapping -- the same complaint,
	"reads as an object on rails," closed in the same fix).

	`root:SetNetworkOwner(nil)` happens in `spawnPatrol`, after parenting --
	it errors on a part not yet descended from Workspace. Permanent server
	ownership, not the engine's default nearest-player heuristic, is what
	makes "not shovable by players" true: without it, whichever player
	walks closest could be handed simulation of an NPC standing right next
	to them. `CanCollide = false` on both parts is the other half of that --
	nothing to push, nothing pushes them off their own path either. ]]
local function buildRig(name: string): (Model, BasePart, BasePart)
	local model = Instance.new("Model")
	model.Name = name

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 5, 1)
	root.Color = NPC_COLOR
	root.Material = Enum.Material.SmoothPlastic
	root.Anchored = false
	root.CanCollide = false
	root.TopSurface = Enum.SurfaceType.Smooth
	root.BottomSurface = Enum.SurfaceType.Smooth
	root.Parent = model

	local rootAttachment = Instance.new("Attachment")
	rootAttachment.Name = "PatrolAttachment"
	rootAttachment.Parent = root

	-- Invisible and unqueryable: a raycast or GetPartBoundsInRadius must
	-- find `root` for a lock or a hit, never this. CanQuery = false is
	-- what excludes it, the same property the ruling's own projectile
	-- dressing relies on the client never needing to touch.
	local target = Instance.new("Part")
	target.Name = "PatrolTarget"
	target.Size = Vector3.new(0.2, 0.2, 0.2)
	target.Transparency = 1
	target.Anchored = true
	target.CanCollide = false
	target.CanQuery = false
	target.CanTouch = false
	target.Parent = model

	local targetAttachment = Instance.new("Attachment")
	targetAttachment.Name = "PatrolTargetAttachment"
	targetAttachment.Parent = target

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Attachment0 = rootAttachment
	alignPosition.Attachment1 = targetAttachment
	alignPosition.RigidityEnabled = true
	alignPosition.Parent = root

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Attachment0 = rootAttachment
	alignOrientation.Attachment1 = targetAttachment
	alignOrientation.MaxAngularVelocity = 6
	alignOrientation.Parent = root

	model.PrimaryPart = root
	model:SetAttribute("DisplayName", name)
	-- Interface's own ask (npcs.md, Presentation): a marker that says "this
	-- is not a player and it will not fight back," read off the model the
	-- same way every other attribute already is. Name and exact
	-- presentation are interface's to adjust.
	model:SetAttribute("Neutral", true)

	return model, root, target
end

local function findByModel(model: Model): Npc?
	for _, npc in npcs do
		if npc.model == model then
			return npc
		end
	end
	return nil
end

--[[ Ping-pong reverses at each end; a loop wraps last back to first.
	Landscape's own routes need both -- the Barrens rim's closing chord
	crosses the blight and cannot loop; the Wellspring ring is loop-safe --
	so both are real traversal modes, not one default with an exception. ]]
local function advanceWaypoint(npc: Npc)
	local count = #npc.route
	if count <= 1 then
		return
	end
	if npc.pingPong then
		local nextIndex = npc.waypointIndex + npc.direction
		if nextIndex < 1 or nextIndex > count then
			npc.direction = -npc.direction
			nextIndex = npc.waypointIndex + npc.direction
		end
		npc.waypointIndex = nextIndex
	else
		npc.waypointIndex = (npc.waypointIndex % count) + 1
	end
end

--[[ Moves the ATTACHMENT TARGET along the route at walkSpeed, not `root`
	itself -- `root` is physics-driven toward wherever `target` is by the
	constraints `buildRig` set up, which is what gives the network layer an
	unanchored body to interpolate instead of a discrete CFrame write to
	replicate as-is. `target`'s own CFrame is built facing the direction of
	travel, so AlignOrientation turns `root` to face it for free -- an NPC
	that walks its route now looks like it is walking it, not sliding along
	rails with the same facing throughout. ]]
local function walk(npc: Npc, deltaSeconds: number)
	local waypoint = npc.route[npc.waypointIndex]
	if not waypoint then
		return
	end
	local current = npc.target.Position
	local toWaypoint = waypoint - current
	local distance = toWaypoint.Magnitude
	if distance <= ARRIVE_RADIUS then
		advanceWaypoint(npc)
		return
	end
	local step = math.min(npc.walkSpeed * deltaSeconds, distance)
	local direction = toWaypoint.Unit
	local nextPosition = current + direction * step
	npc.target.CFrame = CFrame.lookAt(nextPosition, nextPosition + direction)
end

--[[ Sets `target` and `root` to the SAME CFrame together, per the human's
	own constraint: resetting only `root` would leave `target` wherever the
	route last put it, and a rigid AlignPosition would snap `root` straight
	back across the map toward it the instant physics next stepped.
	Velocity is zeroed too, so momentum from the moment of death does not
	carry into the teleport. ]]
local function respawn(npc: Npc)
	npc.deadAt = nil
	npc.waypointIndex = 1
	npc.direction = 1
	npc.hasBeenHit = false
	npc.attackerCombatantId = nil
	npc.nextCastAt = nil

	local start = CFrame.new(npc.route[1])
	npc.target.CFrame = start
	npc.root.CFrame = start
	npc.root.AssemblyLinearVelocity = Vector3.zero
	npc.root.AssemblyAngularVelocity = Vector3.zero

	CombatService.resetCombatantHealth(npc.model)
end

local function spawnPatrol(spec: Patrol)
	if #spec.route == 0 then
		warn(`[npc] {spec.name} has an empty route, skipped`)
		return
	end

	local model, root, target = buildRig(spec.name)
	local start = CFrame.new(spec.route[1])
	root.CFrame = start
	target.CFrame = start
	model.Parent = ensureFolder()
	-- Only meaningful once the part is descended from Workspace, hence
	-- after parenting -- permanent server ownership, not a one-time grab.
	root:SetNetworkOwner(nil)

	local actor = CombatService.registerCombatant(model, stageIndexOf(spec.stage), "npc")
	if not actor then
		warn(`[npc] registerCombatant refused for {spec.name}`)
		model:Destroy()
		return
	end

	table.insert(npcs, {
		model = model,
		root = root,
		target = target,
		actor = actor,
		route = spec.route,
		pingPong = spec.pingPong,
		walkSpeed = spec.walkSpeed,
		waypointIndex = 1,
		direction = 1,
		hasBeenHit = false,
		attackerCombatantId = nil,
		nextCastAt = nil,
		deadAt = nil,
	})
end

--[[ Respawn timing and the retaliation loop -- deliberately NOT the walk
	step, which needs a frame's cadence and gets its own Heartbeat
	connection in `start` below. Whatever cadence external wiring calls
	this at (the coarse, once-a-second tickService loop CombatService's own
	non-motion ticking already runs on) is fine for both: a respawn timer
	and a retaliation cast schedule are event-driven checks, not continuous
	motion, the same reason DummyService's own reset/cast scheduling has
	never needed a finer cadence either. `now` is the only argument, so
	whichever tickService wiring calls DummyService.tick calls this
	identically. ]]
function NpcService.tick(now: number)
	for _, npc in npcs do
		if npc.actor.health <= 0 then
			if not npc.deadAt then
				npc.deadAt = now + RESPAWN_SECONDS
			elseif now >= npc.deadAt then
				respawn(npc)
			end
			continue
		end

		if npc.hasBeenHit then
			if
				npc.attackerCombatantId
				and not CombatService.isCombatantAlive(npc.attackerCombatantId)
			then
				-- Cleared, per npcs.md ruling 1: the attacker is dead or
				-- gone, so there is nothing left to retaliate against.
				npc.hasBeenHit = false
				npc.attackerCombatantId = nil
				npc.nextCastAt = nil
			elseif npc.nextCastAt and now >= npc.nextCastAt then
				CombatService.dummyCast(npc.model, RETALIATE_TECH)
				npc.nextCastAt = now + RETALIATE_INTERVAL
			end
		end
	end
end

function NpcService.start()
	for _, spec in ArenaService.patrols() do
		spawnPatrol(spec)
	end

	--[[ The walk step's own Heartbeat connection, NOT the coarse tick above
		-- this is the actual fix for the human's live-session finding.
		CombatService.tick runs at Config.Field.cycleTickSeconds (1s),
		coarse on purpose for regen and construct zoning, and moving
		`target` only once a second would still read as teleporting no
		matter how the physics between `root` and `target` is set up:
		rigid tracking follows `target` exactly, so a choppy target produces
		a choppy root regardless. Motion needs a frame's cadence; nothing
		else about an NPC does -- the identical reasoning CombatService's
		own stepProjectiles already established for exactly this shape of
		problem. ]]
	RunService.Heartbeat:Connect(function(deltaSeconds: number)
		for _, npc in npcs do
			if npc.actor.health > 0 then
				walk(npc, deltaSeconds)
			end
		end
	end)

	--[[ The has-been-hit flag itself lives here, not in CombatService --
		damageCombatant only ever tells this service a hit happened, the
		same division setKillHandler/setDrainedHandler/setRefusalHandler
		already draw for every other cross-service signal. attackerActor.id
		round-trips through tonumber the same way every other combatant id
		in this codebase already does. ]]
	CombatService.setNpcHitHandler(function(model: Model, attackerActor: Combat.Actor)
		local npc = findByModel(model)
		if not npc then
			return
		end
		npc.hasBeenHit = true
		npc.attackerCombatantId = tonumber(attackerActor.id)
		if not npc.nextCastAt then
			npc.nextCastAt = os.clock() + RETALIATE_DELAY
		end
	end)
end

return NpcService
