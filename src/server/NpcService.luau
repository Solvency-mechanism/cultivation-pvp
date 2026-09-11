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

local function buildRig(name: string): (Model, BasePart)
	local model = Instance.new("Model")
	model.Name = name

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 5, 1)
	root.Color = NPC_COLOR
	root.Material = Enum.Material.SmoothPlastic
	root.Anchored = true
	root.CanCollide = true
	root.TopSurface = Enum.SurfaceType.Smooth
	root.BottomSurface = Enum.SurfaceType.Smooth
	root.Parent = model

	model.PrimaryPart = root
	model:SetAttribute("DisplayName", name)
	-- Interface's own ask (npcs.md, Presentation): a marker that says "this
	-- is not a player and it will not fight back," read off the model the
	-- same way every other attribute already is. Name and exact
	-- presentation are interface's to adjust.
	model:SetAttribute("Neutral", true)

	return model, root
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

local function walk(npc: Npc, deltaSeconds: number)
	local target = npc.route[npc.waypointIndex]
	if not target then
		return
	end
	local current = npc.root.Position
	local toTarget = target - current
	local distance = toTarget.Magnitude
	if distance <= ARRIVE_RADIUS then
		advanceWaypoint(npc)
		return
	end
	local step = math.min(npc.walkSpeed * deltaSeconds, distance)
	npc.root.CFrame = CFrame.new(current + toTarget.Unit * step)
end

local function respawn(npc: Npc)
	npc.deadAt = nil
	npc.waypointIndex = 1
	npc.direction = 1
	npc.hasBeenHit = false
	npc.attackerCombatantId = nil
	npc.nextCastAt = nil
	npc.root.CFrame = CFrame.new(npc.route[1])
	CombatService.resetCombatantHealth(npc.model)
end

local function spawnPatrol(spec: Patrol)
	if #spec.route == 0 then
		warn(`[npc] {spec.name} has an empty route, skipped`)
		return
	end

	local model, root = buildRig(spec.name)
	root.CFrame = CFrame.new(spec.route[1])
	model.Parent = ensureFolder()

	local actor = CombatService.registerCombatant(model, stageIndexOf(spec.stage), "npc")
	if not actor then
		warn(`[npc] registerCombatant refused for {spec.name}`)
		model:Destroy()
		return
	end

	table.insert(npcs, {
		model = model,
		root = root,
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

--[[ Patrol, respawn, and the retaliation loop, all in one pass -- the exact
	shape DummyService.tick already has for its own three variants. `now` is
	the only argument, matching DummyService's own tick signature, so
	whichever tickService wiring calls one calls the other identically;
	delta is derived internally the same way DummyService's patrol phase
	accumulator already does. ]]
local lastTickAt: number? = nil

function NpcService.tick(now: number)
	local delta = if lastTickAt then now - lastTickAt else 0
	lastTickAt = now

	for _, npc in npcs do
		if npc.actor.health <= 0 then
			if not npc.deadAt then
				npc.deadAt = now + RESPAWN_SECONDS
			elseif now >= npc.deadAt then
				respawn(npc)
			end
			continue
		end

		walk(npc, delta)

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
