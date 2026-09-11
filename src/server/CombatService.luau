--!strict
--[[
	Binds the pure Combat rules to Roblox: actors, the UseTechnique remote, hit
	resolution, constructs, death and respawn.

	Server-authoritative throughout. The client sends a *slot name* and nothing
	else; cost, cooldown, target selection and damage are all resolved here.
	Every rule this applies comes from the Combat module, so this file stays a
	thin binding layer in the same shape as CultivationService.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Combat = require(ReplicatedStorage.Shared.Combat)
local Config = require(ReplicatedStorage.Shared.Config)
local Progression = require(ReplicatedStorage.Shared.Progression)
local ArenaService = require(script.Parent.ArenaService)
local AwarenessService = require(script.Parent.AwarenessService)
local CultivationService = require(script.Parent.CultivationService)
local NodeService = require(script.Parent.NodeService)

local CombatService = {}

type Construct = {
	id: string,
	ownerId: number,
	stageIndex: number,
	techId: string,
	position: Vector3,
	radius: number,
	damagePerTick: number,
	expiresAt: number,
	nextTickAt: number,
	part: BasePart,
}

--[[ A resolvable side of an engagement, player or dummy, behind one shape.

	The whole point of a combat dummy is that it behaves exactly as a player
	does under fire -- that is what makes it a measuring instrument rather
	than a second thing to debug. So there is one resolution function and one
	damage function for both, `combatantFromInstance` and `damageCombatant`
	below, and `Combat.canEngage`'s bracket check applies to a dummy exactly
	as it does to a player: honouring it, not skipping it, is the entire
	value of a dummy set to a different stage than another.

	`combatantId` is one id space, agreed directly with interface: a player's
	is their `UserId` (always positive); a dummy's is negative, minted once at
	registration and stable for its lifetime. The same number goes everywhere
	a broadcast wants an id -- `Impact`'s attacker/target, `CastStarted`'s
	caster -- and onto the dummy model itself as a `CombatantId` attribute, so
	a client can bind a telegraph or a hit to the right plate without a second
	id space to keep in sync. Negative rather than a fresh positive counter
	because every existing `== someUserId` comparison then stays correct for
	free, and a combatant sitting at `0` would collide with `Impact.luau`'s own
	`localId = 0` fallback and read as the viewer's own hit -- a real hazard
	interface's own code review caught, not a theoretical one.

	`player` is set only for `kind == "player"`. ]]
export type Combatant = {
	kind: "player" | "dummy",
	combatantId: number,
	actor: Combat.Actor,
	model: Model,
	root: BasePart,
	humanoid: Humanoid?,
	player: Player?,
}

local actors: { [number]: Combat.Actor } = {}
local loadouts: { [number]: { [string]: string } } = {}
local constructs: { Construct } = {}
local dying: { [number]: boolean } = {}
local lastRequestAt: { [number]: number } = {}

-- Dummies, keyed by their own Model rather than a UserId they do not have.
-- `dummyCounter` seeds each new dummy's `combatantId`, negated so it can
-- never collide with a real UserId.
local dummies: { [Model]: Combatant } = {}
local dummyCounter = 0

local techniqueFiredRemote: RemoteEvent? = nil
local castStartedRemote: RemoteEvent? = nil
local impactRemote: RemoteEvent? = nil
local constructCounter = 0
local constructFolder: Folder? = nil

--[[ Fired once per confirmed kill, with the killer only -- the victim side of
	a kill already has AwarenessService.notify's "death" line, and this exists
	for whoever wants to tally the other side of it (PresenceService's
	leaderstats). Injected rather than required directly: CombatService is a
	leaf other services read from, and it should stay that way rather than
	pick up a reason to know PresenceService exists. Same shape
	CultivationService.setRefusalHandler already uses for the identical
	problem. ]]
local killHandler: ((Player) -> ())? = nil

function CombatService.setKillHandler(handler: (Player) -> ())
	killHandler = handler
end

-- A refused request still costs the server work. The global cooldown already
-- caps legitimate use at one per 0.4s; this only blunts a flood of rejects.
local MIN_REQUEST_INTERVAL = 0.05

local CONSTRUCT_COLOR = Color3.fromRGB(255, 140, 90)

--[[ Techniques whose entire effect is the self-buff Combat.use already applied.
	Listed rather than inferred, so a new construct-backed forger technique
	fails loudly instead of silently doing nothing. ]]
local SELF_BUFF_FORGERS: { [string]: boolean } = { barrier = true }

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- `combatantFromInstance`, which replaces the old player-only version of
-- this lookup, is defined after `ensureActor` below -- it needs to call it
-- for the player branch, and `ensureActor` is not declared yet at this point
-- in the file.

local function stageIndexOf(player: Player): number?
	local state = CultivationService.getState(player)
	return if state then state.stageIndex else nil
end

local function powerOf(player: Player): number
	local state = CultivationService.getState(player)
	if not state then
		return Config.Combat.referencePower
	end
	return Progression.effectivePower(Config, state)
end

--[[ The caster's terrain richness, which is what Ruler techniques scale on.

	The intent was always that terrain-scaled techniques peak exactly where the
	fights are, and that intent is still right. It was unreachable until now: a
	node's region is rolled from a flat, position-blind table in
	`NodeService.placer`, so "peaks where the fights are" had silently become
	"peaks where a coin flip says," and standing off a node -- true of a caster
	almost everywhere on a 440-stud map -- always read "open" regardless of the
	ground underfoot. Measured live, two clients, before this change: a
	wellspring-floor Siphon landed for 55, the exact open-ground number, because
	nobody was standing inside a node. Simulated against the full kit: Upheaval
	took 56 seconds to kill, Tempest 40, against Lance's 11.5 -- not a weak
	kind, a switched-off one, sitting in every player's default loadout.

	This closes the gap between "open" and the real ground: off a node, the
	static aura geography the terrain is actually painted with now answers
	instead of a blanket fallback. It does not fully deliver the original
	intent by itself -- nodes still roll their region blind, so a node can
	still sit on Barrens ground and read `wellspring`, or vice versa -- that is
	tomorrow's fix, landscape's weighted-anchor work deriving node placement
	from this same geography. Once nodes sit where the ground says they do,
	Ruler peaks both on rich ground and at nodes, because the nodes will be on
	it. This is a step toward that, not a replacement for it. ]]
local function regionAtPosition(position: Vector3): string
	local node = NodeService.nodeAt(position)
	if node then
		return node.region
	end
	return ArenaService.regionAt(position)
end

local function regionOf(player: Player): string
	local root = rootOf(player)
	if not root then
		return "open"
	end
	return regionAtPosition(root.Position)
end

--[[ Tell every client that a technique resolved, so they can draw it.

	Presentation only. Nothing here decides an outcome -- the damage is already
	applied by the time this fires -- so a client that ignores or fakes it changes
	nothing but its own screen. ]]
local function broadcastVfx(
	casterId: number,
	techId: string,
	origin: Vector3,
	target: Vector3?,
	hit: boolean
)
	if not techniqueFiredRemote then
		return
	end
	local tech = Config.Techniques[techId]
	techniqueFiredRemote:FireAllClients({
		techId = techId,
		kind = tech.kind,
		casterId = casterId,
		origin = origin,
		target = target,
		hit = hit,
	})
end

--[[ Tell every client that a cast has *begun*, at intent time.

	The telegraph. Until now `broadcastVfx` was the only thing clients heard
	about a technique, and it fires from `resolveEffect` -- which runs after
	`task.delay(tech.windup)`. An opponent therefore saw nothing at all until the
	technique had already landed: a 1.8s Tempest windup was, from the defender's
	side, instantaneous. Every piece of dodge arithmetic in the combat spec
	assumes a telegraph that did not exist.

	This leaks nothing. Cost, cooldown and the global cooldown were all paid by
	`Combat.use` before this fires, so the cast is already committed; announcing
	it early only reveals, a windup earlier, what the resolution would reveal
	anyway. Presentation only -- no client reply is read, and a client that
	ignores this changes nothing but its own screen.

	`windup` travels as a duration rather than a deadline on purpose: `os.clock`
	is not a shared clock between a server and a client, so a timestamp would be
	meaningless on arrival. Each client starts its own bar on receipt and eats
	the one-way latency as a small head start for the defender, which is the
	right direction to be wrong in. ]]
local function broadcastCastStart(casterId: number, techId: string)
	if not castStartedRemote then
		return
	end
	local tech = Config.Techniques[techId]
	if not tech then
		return
	end
	castStartedRemote:FireAllClients({
		casterId = casterId,
		techId = techId,
		kind = tech.kind,
		windup = tech.windup,
	})
end

--[[ Health/MaxHealth, published under the same attribute names for a player
	or a dummy -- interface's nameplate reads them off whichever instance
	carries them (the Player for a player, the Model for a dummy) with one
	code path rather than two, which is the entire point of the same-names
	agreement: nothing here for a future consumer to forget to generalise. ]]
local function publishHealth(instance: Instance, actor: Combat.Actor)
	instance:SetAttribute("Health", math.floor(actor.health))
	instance:SetAttribute("MaxHealth", math.floor(Combat.maxHealth(Config, actor.stageIndex)))
end

local function publish(player: Player)
	local actor = actors[player.UserId]
	if not actor then
		return
	end
	publishHealth(player, actor)
	player:SetAttribute("Madra", math.floor(actor.madra))
	player:SetAttribute("MaxMadra", math.floor(Combat.maxMadra(Config, actor.stageIndex)))
end

--[[ The actor is authoritative; the Humanoid is a readout, so the default health
	bar and death animation reflect it. Nothing reads back from the Humanoid
	except its Died signal, which covers deaths this service did not cause.
	Takes the Humanoid directly rather than a Player, so a dummy's Humanoid
	mirrors exactly the same way a player's does. ]]
local function mirrorHumanoid(humanoid: Humanoid?, actor: Combat.Actor)
	if not humanoid then
		return
	end
	humanoid.MaxHealth = Combat.maxHealth(Config, actor.stageIndex)
	humanoid.Health = actor.health
end

local function ensureActor(player: Player): Combat.Actor?
	-- No actor exists between death and respawn, so a corpse cannot be hit
	-- again and the dead player cannot spend madra.
	if dying[player.UserId] then
		return nil
	end

	local stageIndex = stageIndexOf(player)
	if not stageIndex then
		return nil
	end

	local existing = actors[player.UserId]
	if existing and existing.stageIndex == stageIndex then
		return existing
	end

	-- A breakthrough changes both pools, so the actor is rebuilt on stage
	-- change. Polling for it here keeps CultivationService from needing to know
	-- this service exists at all.
	local actor = Combat.newActor(Config, tostring(player.UserId), stageIndex)
	actors[player.UserId] = actor
	mirrorHumanoid(humanoidOf(player), actor)
	publish(player)
	return actor
end

--[[ Resolves any instance -- a striker raycast hit, an overlap sweep part,
	whatever a construct tick finds nearby -- to a `Combatant`, player or
	dummy, behind one shape. Replaces the old player-only `playerFromInstance`
	for the reason at the top of this file: a dummy that went through a
	different lookup would not be measuring anything.

	The player branch routes through `ensureActor` rather than a raw table
	read, preserving exactly the freshness guarantee it already gave
	`damagePlayer` -- a stage change rebuilds the actor before it is ever
	used to resolve damage. This is why `combatantFromInstance` has to live
	after `ensureActor` in the file rather than replacing `playerFromInstance`
	in place: it needs to call it. ]]
local function combatantFromInstance(instance: Instance): Combatant?
	local model = instance:FindFirstAncestorWhichIsA("Model")
	while model do
		local player = Players:GetPlayerFromCharacter(model)
		if player then
			local actor = ensureActor(player)
			local root = rootOf(player)
			if not actor or not root then
				return nil
			end
			return {
				kind = "player",
				combatantId = player.UserId,
				actor = actor,
				model = model,
				root = root,
				humanoid = humanoidOf(player),
				player = player,
			}
		end
		local dummy = dummies[model]
		if dummy then
			return dummy
		end
		model = model:FindFirstAncestorWhichIsA("Model")
	end
	return nil
end

--[[ `attackerActor` is optional and only ever supplied by `damagePlayer` --
	the raw `Humanoid.Died` path below has no attacker to give, because a fall
	has no killer. Everything downstream of it stays silent about a killer
	that does not exist rather than guessing one. ]]
local function handleDeath(player: Player, attackerActor: Combat.Actor?)
	if dying[player.UserId] then
		return
	end

	-- Resolved at death rather than captured at spawn, so a player who dies
	-- before their state has loaded is charged nothing instead of being charged
	-- at the wrong stage. Routed through ensureActor, not a raw table read, so
	-- a death landing in the brief window after a stage change still charges
	-- the current stage -- the same discipline damagePlayer already applies to
	-- every combat death. Must run before the dying flag below, since
	-- ensureActor itself refuses to act once dying[player.UserId] is set.
	local actor = ensureActor(player)
	dying[player.UserId] = true

	local killer: Player? = if attackerActor
		then Players:GetPlayerByUserId(tonumber(attackerActor.id) or -1)
		else nil

	local stageIndex = if actor then actor.stageIndex else stageIndexOf(player)
	if stageIndex then
		-- Amount comes from Combat, the ratchet lives in Progression, and the
		-- write is routed through CultivationService so state has one owner.
		local loss = Combat.deathLoss(Config, stageIndex)
		CultivationService.applyDeathLoss(player, loss)

		--[[ A kill produced no output at all before this: the killer was never
			told, the victim was never told who killed them or that they had just
			been charged refinement, and nobody else in the server heard anything
			happened. In a game whose entire economy is contested ground, that is
			the most important moment producing the least feedback. The channel
			already exists -- this only spends it.

			`kill`/`death` are interface's priority notice kinds -- gold/red, held
			longer, and immune to being overwritten by a lower-priority notice for
			a few seconds, so a kill cannot be erased by a Prime spawn landing half
			a second later. The victim's line carries the number, not just the
			fraction: "your refinement falls" is the first time a player learns
			what a death actually costs, and a raw number teaches that in one line
			a percentage does not. ]]
		local lossAmount = math.floor(loss)
		if killer then
			if killHandler then
				killHandler(killer)
			end
			-- DisplayName, not Name: interface's nameplates and target frame
			-- both read DisplayName, and a notice naming someone by their
			-- username instead would be a different person to look for mid-fight.
			AwarenessService.notify(killer, "kill", `You kill {player.DisplayName}.`)
			AwarenessService.notify(
				player,
				"death",
				`{killer.DisplayName} kills you. Your refinement falls {lossAmount}.`
			)
			-- Everyone else gets the public version, which is what turns a kill
			-- into a shared story in a small server instead of a silence only
			-- two people noticed.
			for _, spectator in Players:GetPlayers() do
				if spectator ~= player and spectator ~= killer then
					AwarenessService.notify(
						spectator,
						"server",
						`{killer.DisplayName} kills {player.DisplayName}.`
					)
				end
			end
		else
			AwarenessService.notify(
				player,
				"death",
				`You fall. Your refinement falls {lossAmount}.`
			)
		end
	end
	actors[player.UserId] = nil

	local humanoid = humanoidOf(player)
	if humanoid and humanoid.Health > 0 then
		humanoid.Health = 0
	end
end

--[[ Damage from one actor to one combatant, player or dummy. Cross-bracket
	engagements are refused outright here rather than scaled down --
	`Combat.canEngage` applies to a dummy exactly as it does to a player,
	which is the entire value of being able to set a dummy's stage: this is
	the one thing that could never be exercised with a second real player at
	a different stage, and never has been.

	`source.id` is expected to be `tostring` of a `combatantId` -- a player's
	`UserId` or a dummy's negative pseudo-id -- so `tonumber(source.id)` below
	always round-trips. The `math.huge` fallback (never a real fallback in
	practice, since every registered actor's `id` is always numeric) exists
	only to retire the `0` collision interface's review caught: `Impact.luau`
	falls back to `localId = 0` when there is no local player, so a combatant
	that ever sat at `0` would read as the viewer. `math.huge` can never equal
	any real id, by construction, not by remembering. ]]
local function damageCombatant(source: Combat.Actor, target: Combatant, raw: number, now: number)
	if target.actor.health <= 0 then
		return
	end
	if not Combat.canEngage(source, target.actor) then
		return
	end

	local result = Combat.applyDamage(Config, target.actor, raw, now)
	if result.dealt <= 0 then
		return
	end

	mirrorHumanoid(target.humanoid, target.actor)
	publishHealth((target.player :: Instance?) or target.model, target.actor)
	if target.kind == "player" and target.player then
		-- Madra/MaxMadra are player-only; dummies neither spend nor need to
		-- show them.
		publish(target.player)
	end

	--[[ Every applied hit, from one place, so a Ruler sweep and a construct tick
		land the same feedback a striker bolt does. Presentation only: the damage
		above is already final, and read before death is processed so the body is
		still where it was struck. ]]
	if impactRemote then
		impactRemote:FireAllClients({
			attackerId = tonumber(source.id) or math.huge,
			targetId = target.combatantId,
			position = target.root.Position,
			damage = result.dealt,
			stageIndex = target.actor.stageIndex,
			died = result.died,
		})
	end

	if result.died then
		if target.kind == "player" and target.player then
			handleDeath(target.player, source)
		end
		-- A dummy's "death" is not routed anywhere: DummyService holds the
		-- same `Combat.Actor` table this mutated and polls `health <= 0` on
		-- its own tick to schedule the reset, rather than CombatService
		-- needing to know DummyService exists to tell it.
	end
end

--[[ Registers a Model as a full combatant -- same damage-resolution path,
	same `Combat.canEngage` bracket check a player already goes through.
	`stageIndex` is fixed at registration rather than derived, unlike a
	player's: a dummy's bracket is something a tester sets deliberately, to
	exercise `canEngage`'s refusal for the first time without needing two
	real players parked at two different stages, which is why it has never
	been properly exercised.

	Tags and attributes follow the scheme agreed directly with interface:
	CollectionService tag `"Combatant"`, and `CombatantId`/`Health`/
	`MaxHealth`/`StageIndex`/`Stage` set on the model using the exact names a
	player already carries, so one nameplate read path covers both. Returns
	the actor so the caller (DummyService) can poll `actor.health` on its own
	tick rather than CombatService needing a reason to know DummyService
	exists. ]]
function CombatService.registerDummy(model: Model, stageIndex: number): Combat.Actor?
	local stage = Config.Stages[stageIndex]
	local root = model:FindFirstChild("HumanoidRootPart")
	if not stage or not root or not root:IsA("BasePart") then
		return nil
	end

	dummyCounter += 1
	local combatantId = -dummyCounter
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local actor = Combat.newActor(Config, tostring(combatantId), stageIndex)

	dummies[model] = {
		kind = "dummy",
		combatantId = combatantId,
		actor = actor,
		model = model,
		root = root :: BasePart,
		humanoid = humanoid,
		player = nil,
	}

	CollectionService:AddTag(model, "Combatant")
	model:SetAttribute("CombatantId", combatantId)
	model:SetAttribute("StageIndex", stageIndex)
	model:SetAttribute("Stage", stage.name)
	mirrorHumanoid(humanoid, actor)
	publishHealth(model, actor)

	return actor
end

function CombatService.unregisterDummy(model: Model)
	dummies[model] = nil
end

--[[ Heals a registered dummy to full and republishes -- the auto-reset a
	dummy needs to be a continuous instrument rather than a respawn chore.
	No-ops for a model that was never registered or has since been
	unregistered, so a reset scheduled just before a `/cleardummies` cannot
	resurrect one. ]]
function CombatService.resetDummyHealth(model: Model)
	local dummy = dummies[model]
	if not dummy then
		return
	end
	dummy.actor.health = Combat.maxHealth(Config, dummy.actor.stageIndex)
	mirrorHumanoid(dummy.humanoid, dummy.actor)
	publishHealth(model, dummy.actor)
end

--[[ A scripted loop-caster, for DummyService's telegraphed-cast variant.
	Goes through the exact same broadcast/windup/resolve shape a player's own
	cast already does -- `CastStarted` at intent time, `TechniqueFired` and
	damage at resolve -- so the defender-side cast bar, never once witnessed
	by a human, has a real cast to test against rather than a fake timer.

	Only `kind == "ruler"` is wired: a striker needs an aim direction and a
	forger needs a placement point, neither of which a stationary loop-caster
	has, and a ruler technique (tempest, upheaval, siphon) is exactly what
	"casts on a loop" asks for. Power is fixed at `referencePower` -- a dummy
	has no cultivation state to derive one from, and does not need build
	diversity, only to exist as a source of a real, telegraphed cast. ]]
function CombatService.dummyCast(model: Model, techId: string)
	local dummy = dummies[model]
	if not dummy or dummy.actor.health <= 0 then
		return
	end
	local tech = Config.Techniques[techId]
	if not tech or tech.kind ~= "ruler" then
		return
	end

	broadcastCastStart(dummy.combatantId, techId)

	task.delay(tech.windup, function()
		local stillThere = dummies[model]
		if not stillThere or stillThere.actor.health <= 0 then
			return
		end
		local now = os.clock()
		local raw = Combat.outgoingDamage(
			Config,
			dummy.actor,
			techId,
			Config.Combat.referencePower,
			regionAtPosition(dummy.root.Position),
			now
		)
		broadcastVfx(dummy.combatantId, techId, dummy.root.Position, nil, false)

		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { model }
		local seen: { [Model]: boolean } = {}
		local parts =
			Workspace:GetPartBoundsInRadius(dummy.root.Position, Config.Combat.ranges.ruler, params)
		for _, part in parts do
			local target = combatantFromInstance(part)
			if target and target.model ~= model and not seen[target.model] then
				seen[target.model] = true
				damageCombatant(dummy.actor, target, raw, now)
			end
		end
	end)
end

local function ensureConstructFolder(): Folder
	if constructFolder and constructFolder.Parent then
		return constructFolder
	end
	local existing = Workspace:FindFirstChild("Constructs")
	if existing and existing:IsA("Folder") then
		constructFolder = existing
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "Constructs"
	created.Parent = Workspace
	constructFolder = created
	return created
end

--[[ The persistent damaging construct that caltrops and sentry place.

	Damage is snapshotted at cast time, so buffs active when it was placed are
	baked in and buffs gained later are not: a construct is something you left
	behind, not a channel you are still feeding. ]]
local function spawnConstruct(
	owner: Player,
	actor: Combat.Actor,
	techId: string,
	position: Vector3,
	now: number
)
	local tech = Config.Techniques[techId]
	local radius = Config.Combat.ranges.forger
	constructCounter += 1

	local part = Instance.new("Part")
	part.Name = "construct_" .. constructCounter
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Shape = Enum.PartType.Cylinder
	part.Material = Enum.Material.Neon
	part.Color = CONSTRUCT_COLOR
	part.Transparency = 0.6
	part.Size = Vector3.new(1, radius * 2, radius * 2)
	part.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.pi / 2)
	part:SetAttribute("Technique", techId)
	part:SetAttribute("Owner", owner.UserId)
	part.Parent = ensureConstructFolder()

	table.insert(constructs, {
		id = part.Name,
		ownerId = owner.UserId,
		stageIndex = actor.stageIndex,
		techId = techId,
		position = position,
		radius = radius,
		damagePerTick = Combat.outgoingDamage(
			Config,
			actor,
			techId,
			powerOf(owner),
			regionOf(owner),
			now
		),
		expiresAt = now + tech.buffDuration,
		nextTickAt = now + Config.Combat.constructTickSeconds,
		part = part :: BasePart,
	})
end

--[[ Where a cast is pointed.

	The client sends this because it is the one thing the client genuinely knows
	better than the server: where the player is looking. Aiming by the
	character's facing instead reads as broken the moment the camera is free of
	the body.

	This is not a security hole. The server still owns range, cost, cooldown,
	bracket, the raycast itself and therefore every wall between the two of you;
	a lying direction buys nothing a real aimbot would not already have, and
	aimbots cannot be prevented from the server side of a client-authoritative
	camera. What is checked is only that the value is usable. ]]
local function aimOf(caster: Player, supplied: unknown): Vector3
	local root = rootOf(caster)
	local fallback = if root then root.CFrame.LookVector else Vector3.new(0, 0, -1)
	if typeof(supplied) ~= "Vector3" then
		return fallback
	end
	local aim = supplied :: Vector3
	-- Reject NaN and infinities before they reach Raycast, where a bad vector
	-- is an error rather than a miss.
	if aim ~= aim or aim.Magnitude ~= aim.Magnitude then
		return fallback
	end
	if aim.Magnitude < 1e-3 or aim.Magnitude > 1e6 then
		return fallback
	end
	return aim.Unit
end

local function resolveStriker(
	caster: Player,
	actor: Combat.Actor,
	techId: string,
	aim: Vector3,
	now: number
)
	local root = rootOf(caster)
	local character = caster.Character
	if not root or not character then
		return
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }

	local direction = aim * Config.Combat.ranges.striker
	local origin = root.Position
	local hit = Workspace:Raycast(origin, direction, params)
	local landing = if hit then hit.Position else origin + direction

	local target = if hit then combatantFromInstance(hit.Instance) else nil
	-- `target.player ~= caster` reads correctly for a dummy target too: its
	-- `player` field is always nil, and `nil ~= caster` is always true, since
	-- `caster` is a real Player and never nil.
	local struck = target ~= nil and target.player ~= caster
	-- Broadcast before resolving, so a miss still draws. A shot that shows
	-- nothing when it misses reads as a broken button.
	broadcastVfx(caster.UserId, techId, origin, landing, struck)

	if not struck or not target then
		return
	end

	local raw = Combat.outgoingDamage(Config, actor, techId, powerOf(caster), regionOf(caster), now)
	damageCombatant(actor, target, raw, now)
end

local function resolveRuler(caster: Player, actor: Combat.Actor, techId: string, now: number)
	local root = rootOf(caster)
	local character = caster.Character
	if not root or not character then
		return
	end

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }

	-- Region is read once for the whole cast, so a Ruler technique scales by
	-- where the caster stands rather than where each victim happens to be.
	local raw = Combat.outgoingDamage(Config, actor, techId, powerOf(caster), regionOf(caster), now)

	broadcastVfx(caster.UserId, techId, root.Position, nil, false)

	-- Deduped by Model rather than UserId, so a dummy (no UserId) dedupes
	-- exactly the same way a player does.
	local seen: { [Model]: boolean } = {}
	local parts = Workspace:GetPartBoundsInRadius(root.Position, Config.Combat.ranges.ruler, params)
	for _, part in parts do
		local target = combatantFromInstance(part)
		if target and target.player ~= caster and not seen[target.model] then
			seen[target.model] = true
			damageCombatant(actor, target, raw, now)
		end
	end
end

--[[ Land a technique after its windup. Cost and cooldown were paid at cast; this
	is only the effect, and it is dropped if the caster died during the
	telegraph. ]]
local function resolveEffect(caster: Player, actor: Combat.Actor, techId: string, aim: Vector3)
	if actors[caster.UserId] ~= actor or actor.health <= 0 then
		return
	end

	local tech = Config.Techniques[techId]
	local now = os.clock()

	if tech.kind == "striker" then
		resolveStriker(caster, actor, techId, aim, now)
	elseif tech.kind == "ruler" then
		resolveRuler(caster, actor, techId, now)
	elseif tech.kind == "enforcer" then
		-- Self-only. Combat.use already applied the buff.
		local root = rootOf(caster)
		if root then
			broadcastVfx(caster.UserId, techId, root.Position, nil, true)
		end
		publish(caster)
	elseif tech.kind == "forger" then
		local root = rootOf(caster)
		if root then
			broadcastVfx(caster.UserId, techId, root.Position, nil, true)
		end
		if SELF_BUFF_FORGERS[techId] then
			publish(caster)
		elseif root then
			spawnConstruct(caster, actor, techId, root.Position, now)
		end
	end
end

--[[ `Combat.use`'s refusal reasons, given a voice. Every one of them was
	previously silent: press a key, pay nothing, nothing happens, no
	explanation -- indistinguishable from lag, a dropped input, or a broken
	build. `global_cooldown` is deliberately absent and stays that way: it is
	0.4s and fires constantly during ordinary fast play, so a notice on every
	GCD-blocked press would spam the channel and teach players to ignore it,
	which would cost the weight `kill`/`death` notices just earned. The slot
	bar's own cooldown sweep already shows it as a shape; that is enough. ]]
local REFUSAL_MESSAGES: { [string]: string } = {
	insufficient_madra = "Not enough madra.",
	dead = "You cannot act while dead.",
}

local function onUseTechnique(player: Player, slot: unknown, suppliedAim: unknown)
	local now = os.clock()
	local last = lastRequestAt[player.UserId]
	if last and now - last < MIN_REQUEST_INTERVAL then
		return
	end
	lastRequestAt[player.UserId] = now

	local actor = ensureActor(player)
	if not actor then
		return
	end

	local loadout = loadouts[player.UserId]
	if not loadout then
		return
	end

	local techId = Combat.resolveSlot(Config, loadout, slot)
	if not techId then
		return
	end

	local result = Combat.use(Config, actor, techId, now)
	if not result.ok then
		if result.reason == "cooling_down" then
			local tech = Config.Techniques[techId]
			AwarenessService.notify(player, "refused", `{tech.name} is still cooling.`)
		elseif result.reason ~= "global_cooldown" then
			AwarenessService.notify(
				player,
				"refused",
				REFUSAL_MESSAGES[result.reason] or result.reason
			)
		end
		return
	end

	publish(player)

	-- Announced before the windup rather than after it, which is the whole
	-- point: the defender's reaction window is the windup.
	broadcastCastStart(player.UserId, techId)

	-- Aim is sampled at cast, not at resolution: a long windup is a commitment,
	-- and letting it track the camera through the telegraph would erase the
	-- counterplay the windup is there to buy.
	local aim = aimOf(player, suppliedAim)

	local tech = Config.Techniques[techId]
	if tech.windup > 0 then
		task.delay(tech.windup, function()
			resolveEffect(player, actor, techId, aim)
		end)
	else
		resolveEffect(player, actor, techId, aim)
	end
end

--[[ Change one slot's technique. The client sends slot + techId and nothing
	else -- the same register `UseTechnique` already uses for slot + aim.
	Every check here is a trust-boundary check: known slot, known technique,
	the technique's kind matches the slot, the player is alive, and the
	technique currently occupying the slot is not mid-cooldown. That last one
	is the one real exploit swapping opens up: without it a player could hot-
	swap away from a technique the instant it goes on cooldown and install a
	fresh one in its place, cycling through every technique of a kind almost
	as fast as the global cooldown allows instead of waiting each one out. ]]
local function onSetLoadout(player: Player, slot: unknown, techId: unknown)
	local loadout = loadouts[player.UserId]
	if not loadout then
		return
	end

	if type(slot) ~= "string" then
		return
	end
	local isKnownSlot = false
	for _, valid in Config.LoadoutSlots do
		if slot == valid then
			isKnownSlot = true
			break
		end
	end
	if not isKnownSlot then
		return
	end

	if type(techId) ~= "string" then
		return
	end
	local tech = Config.Techniques[techId]
	if not tech or tech.kind ~= slot then
		return
	end

	local actor = ensureActor(player)
	if not actor or actor.health <= 0 then
		AwarenessService.notify(player, "refused", "You cannot change your loadout while dead.")
		return
	end

	local now = os.clock()
	local outgoingId = loadout[slot]
	local outgoingReadyAt = if outgoingId then actor.cooldowns[outgoingId] else nil
	if outgoingReadyAt and now < outgoingReadyAt then
		local outgoingTech = Config.Techniques[outgoingId]
		local name = if outgoingTech then outgoingTech.name else outgoingId
		AwarenessService.notify(player, "refused", `{name} is still cooling.`)
		return
	end

	loadout[slot] = techId
	player:SetAttribute("Slot_" .. slot, techId)
end

local function onCharacterAdded(player: Player)
	dying[player.UserId] = nil
	actors[player.UserId] = nil

	-- Connected before the actor is built, and independently of whether it can
	-- be: cultivation state may still be loading when the character spawns, and
	-- a character with no death handler never respawns cleanly.
	local humanoid = humanoidOf(player)
	if humanoid then
		humanoid.Died:Connect(function()
			-- Covers deaths this service did not cause, so falling off the map
			-- costs the same refinement that losing a fight does.
			handleDeath(player)
		end)
	end

	ensureActor(player)
end

function CombatService.onPlayerAdded(player: Player)
	local loadout = table.clone(Config.DefaultLoadout)
	loadouts[player.UserId] = loadout
	-- Published so the client can label its keys. The loadout itself stays
	-- server-side; this is a readout, and the client still sends only a slot.
	for _, slot in Config.LoadoutSlots do
		player:SetAttribute("Slot_" .. slot, loadout[slot])
	end
	player.CharacterAdded:Connect(function()
		onCharacterAdded(player)
	end)
	if player.Character then
		onCharacterAdded(player)
	end
end

function CombatService.onPlayerRemoving(player: Player)
	actors[player.UserId] = nil
	loadouts[player.UserId] = nil
	dying[player.UserId] = nil
	lastRequestAt[player.UserId] = nil
	for i = #constructs, 1, -1 do
		if constructs[i].ownerId == player.UserId then
			constructs[i].part:Destroy()
			table.remove(constructs, i)
		end
	end
end

local function stepConstructs(now: number)
	for i = #constructs, 1, -1 do
		local construct = constructs[i]
		if now >= construct.expiresAt then
			construct.part:Destroy()
			table.remove(constructs, i)
			continue
		end
		if now < construct.nextTickAt then
			continue
		end
		construct.nextTickAt = now + Config.Combat.constructTickSeconds

		local owner = Players:GetPlayerByUserId(construct.ownerId)
		local ownerActor = if owner then actors[owner.UserId] else nil
		if not ownerActor then
			continue
		end

		-- Deduped by Model rather than UserId, so a dummy standing in a
		-- construct dedupes exactly the same way a player does.
		local seen: { [Model]: boolean } = {}
		local parts = Workspace:GetPartBoundsInRadius(construct.position, construct.radius)
		for _, part in parts do
			local target = combatantFromInstance(part)
			if target and target.player ~= owner and not seen[target.model] then
				seen[target.model] = true
				damageCombatant(ownerActor, target, construct.damagePerTick, now)
			end
		end
	end
end

function CombatService.tick(deltaSeconds: number, now: number)
	for _, player in Players:GetPlayers() do
		local actor = ensureActor(player)
		if actor and actor.health > 0 then
			Combat.regen(Config, actor, deltaSeconds)
			publish(player)
		end
	end
	stepConstructs(now)
end

function CombatService.start()
	Players.RespawnTime = Config.Combat.respawnSeconds

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local fired = remotes:WaitForChild("TechniqueFired")
	assert(fired:IsA("RemoteEvent"), "TechniqueFired must be a RemoteEvent")
	techniqueFiredRemote = fired

	local castStarted = remotes:WaitForChild("CastStarted")
	assert(castStarted:IsA("RemoteEvent"), "CastStarted must be a RemoteEvent")
	castStartedRemote = castStarted

	local impact = remotes:WaitForChild("Impact")
	assert(impact:IsA("RemoteEvent"), "Impact must be a RemoteEvent")
	impactRemote = impact

	local useTechnique = remotes:WaitForChild("UseTechnique")
	assert(useTechnique:IsA("RemoteEvent"), "UseTechnique must be a RemoteEvent")

	useTechnique.OnServerEvent:Connect(function(player: Player, slot: unknown, aim: unknown)
		onUseTechnique(player, slot, aim)
	end)

	local setLoadout = remotes:WaitForChild("SetLoadout")
	assert(setLoadout:IsA("RemoteEvent"), "SetLoadout must be a RemoteEvent")

	setLoadout.OnServerEvent:Connect(function(player: Player, slot: unknown, techId: unknown)
		onSetLoadout(player, slot, techId)
	end)
end

return CombatService
