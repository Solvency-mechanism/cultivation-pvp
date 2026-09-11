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
local RunService = game:GetService("RunService")
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

-- The last refused-cast notice already told to each player, so mashing a
-- blocked key notifies once rather than once per press. See `onUseTechnique`.
local lastCastRefusalNotice: { [number]: string } = {}

-- Dummies, keyed by their own Model rather than a UserId they do not have.
-- `dummyCounter` seeds each new dummy's `combatantId`, negated so it can
-- never collide with a real UserId.
local dummies: { [Model]: Combatant } = {}
local dummyCounter = 0

--[[ One channel in flight per player, keyed by UserId -- only a player ever
	channels a technique today, the same reason `loadouts`/`dying` are
	UserId-keyed rather than combatantId-keyed. `startedAt` is not read for
	timing (the `task.delay` scheduled alongside an entry owns that); it
	exists so a stray reference to a superseded or interrupted cast is
	obviously stale rather than silently plausible. ]]
type ActiveCast = {
	player: Player,
	techId: string,
	targetCombatantId: number?,
	startedAt: number,
}
local activeCasts: { [number]: ActiveCast } = {}

local techniqueFiredRemote: RemoteEvent? = nil
local castStartedRemote: RemoteEvent? = nil
local castInterruptedRemote: RemoteEvent? = nil
local castCompletedRemote: RemoteEvent? = nil
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

-- Combat.Vec3 is a plain {x,y,z} table, not Roblox's Vector3 -- the two are
-- not interchangeable, so every pure-module boundary crossing here builds
-- one explicitly, the same as NodeService.placer's own callers already do.
local function toVec3(position: Vector3): Combat.Vec3
	return { x = position.X, y = position.Y, z = position.Z }
end

--[[ The injected half of Combat.canUseOnTarget's line-of-sight check.
	Excludes both models rather than just their root parts, so the caster's
	own limbs cannot self-block the ray at the origin and the target's own
	body does not count as an obstruction at the destination -- hitting the
	target IS the clear-sight case, not the blocked one. Built fresh per
	validation call: a RaycastParams is cheap, and there is no state worth
	caching across casts. ]]
local function hasLineOfSight(
	casterModel: Model,
	targetModel: Model
): (Combat.Vec3, Combat.Vec3) -> boolean
	return function(from: Combat.Vec3, to: Combat.Vec3): boolean
		local origin = Vector3.new(from.x, from.y, from.z)
		local destination = Vector3.new(to.x, to.y, to.z)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { casterModel, targetModel }
		return Workspace:Raycast(origin, destination - origin, params) == nil
	end
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
--[[ A technique's one commit duration: castTime for a channel, windup for
	everything else, per the frostbolt ruling's addendum. A technique never
	carries both -- roster's own invariant test in tests/combat.test.luau
	refuses one that does -- so this has no ambiguous case to resolve. ]]
local function commitOf(tech: Config.Technique): number
	if tech.castTime > 0 then
		return tech.castTime
	end
	return tech.windup
end

--[[ `duration` and `targetId` are additive, per the shapes fixed in
	frostbolt-ruling.md's REMOTES section -- that file is authoritative over
	this comment, not the other way around. `duration` is commitOf(tech),
	ALWAYS present, because the client reads it for every bar regardless of
	kind. `windup` is untouched: still tech.windup, still sent, since
	interface's sub-0.15s flash rule and the striker telegraph floor key off
	commitOf separately, not off this field. `targetId` is the locked
	combatant id for a lock technique, nil for aim. ]]
local function broadcastCastStart(casterId: number, techId: string, targetId: number?)
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
		duration = commitOf(tech),
		targetId = targetId,
	})
end

--[[ Fired from the interrupt check in damageCombatant and nowhere else, per
	the ruling. ]]
local function broadcastCastInterrupted(casterId: number, techId: string)
	if not castInterruptedRemote then
		return
	end
	castInterruptedRemote:FireAllClients({ casterId = casterId, techId = techId })
end

--[[ Channels only -- never fired for an ordinary windup technique, which
	still clears its own bar on the client's timer exactly as it does today.
	`fizzled` distinguishes "the effect fired" from "completion re-validation
	failed and nothing happened," so the client can draw the same broken-bar
	snap it draws for an interrupt rather than a clean finish that would be a
	lie. ]]
local function broadcastCastCompleted(casterId: number, techId: string, fizzled: boolean)
	if not castCompletedRemote then
		return
	end
	castCompletedRemote:FireAllClients({ casterId = casterId, techId = techId, fizzled = fizzled })
end

--[[ Health/MaxHealth, published under the same attribute names for a player
	or a dummy -- interface's nameplate reads them off whichever instance
	carries them (the Player for a player, the Model for a dummy) with one
	code path rather than two, which is the entire point of the same-names
	agreement: nothing here for a future consumer to forget to generalise. ]]
local function publishHealth(instance: Instance, actor: Combat.Actor)
	instance:SetAttribute("Health", math.floor(actor.health))
	instance:SetAttribute("MaxHealth", math.floor(Combat.maxHealth(Config, actor.stageIndex)))
	-- Published here rather than only where a slow is applied, so it is
	-- never stale: pruning is lazy (Combat.pruneBuffs runs wherever a buff
	-- total is read), so the attribute is only ever as current as the last
	-- publish, exactly like Health already is. 1.0 when not slowed -- a
	-- dummy has no Humanoid to read WalkSpeed off, so this is the one read
	-- path a status cue has for both a player and a dummy, and it carries
	-- the magnitude a boolean could not.
	instance:SetAttribute("SlowMultiplier", Combat.slowMultiplierOf(actor, os.clock()))
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

--[[ WalkSpeed seam, agreed with interface before either side wrote anything:
	the client predicts and writes this property locally the instant a
	strider slot is pressed, inside its own leased window, and stops the
	moment that window ends or the server confirms. Everything past that
	lease is this function's alone -- it is called immediately on a
	successful `Combat.use` (so the real value replicates down and overwrites
	the prediction with no fight, since only one side is writing once the
	client's window closes), again on a refusal (so an over-eager client
	prediction gets corrected even though nothing else runs for a refused
	cast), and once more at the buff's own expiry (scheduled below, since
	nothing else polls a lapsed buff into existence). `Combat.moveSpeedOf`
	already returns 0 when nothing is live, which is exactly the cue to fall
	back to `baseWalkSpeed`. ]]
local function mirrorMoveSpeed(humanoid: Humanoid?, actor: Combat.Actor, now: number)
	if not humanoid then
		return
	end
	local override = Combat.moveSpeedOf(actor, now)
	humanoid.WalkSpeed = if override > 0 then override else Config.Combat.baseWalkSpeed
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

--[[ The reverse of `combatantFromInstance`: given a combatantId rather than
	a world Instance, for a lock technique whose target is chosen by id, not
	by ray. Positive ids resolve the same way the player branch above does;
	negative ids linear-scan `dummies` -- a handful of entries at once in
	practice, and cheaper than keeping a second table in sync with `dummies`
	purely for this lookup. ]]
local function combatantById(combatantId: number): Combatant?
	if combatantId > 0 then
		local player = Players:GetPlayerByUserId(combatantId)
		if not player then
			return nil
		end
		local character = player.Character
		local actor = ensureActor(player)
		local root = rootOf(player)
		if not character or not actor or not root then
			return nil
		end
		return {
			kind = "player",
			combatantId = combatantId,
			actor = actor,
			model = character,
			root = root,
			humanoid = humanoidOf(player),
			player = player,
		}
	end
	for _, dummy in dummies do
		if dummy.combatantId == combatantId then
			return dummy
		end
	end
	return nil
end

--[[ Resolve and validate a lock technique's target in one place, used both
	when a cast starts and again when a channel completes -- the same check
	both times, so "still valid" means the same thing at both ends rather
	than two hand-written copies drifting. `targetCombatantId` is already a
	number by the time this is called; the `unknown` from the remote is
	narrowed by the caller. Returns the reason Combat.canUseOnTarget gives,
	or "no_target" for the cases before that -- an unresolvable id or a
	caster with no root to measure from. ]]
local function validateLockTarget(
	tech: Config.Technique,
	player: Player,
	actor: Combat.Actor,
	targetCombatantId: number
): (Combatant?, string?)
	local target = combatantById(targetCombatantId)
	if not target then
		return nil, "no_target"
	end
	local character = player.Character
	local casterRoot = rootOf(player)
	if not character or not casterRoot then
		return nil, "no_target"
	end
	local range = Config.Combat.ranges[tech.kind] or 0
	local ok, reason = Combat.canUseOnTarget(
		actor,
		toVec3(casterRoot.Position),
		target.actor,
		toVec3(target.root.Position),
		range,
		hasLineOfSight(character, target.model)
	)
	if not ok then
		return nil, reason
	end
	return target, nil
end

--[[ `attackerActor` is optional and only ever supplied by `damageCombatant`,
	and only when the target killed was a player -- the raw `Humanoid.Died`
	path below has no attacker to give, because a fall has no killer.
	Everything downstream of it stays silent about a killer that does not
	exist rather than guessing one. ]]
local function handleDeath(player: Player, attackerActor: Combat.Actor?)
	if dying[player.UserId] then
		return
	end

	-- Resolved at death rather than captured at spawn, so a player who dies
	-- before their state has loaded is charged nothing instead of being charged
	-- at the wrong stage. Routed through ensureActor, not a raw table read, so
	-- a death landing in the brief window after a stage change still charges
	-- the current stage -- the same discipline damageCombatant already applies
	-- to every combat death against a player target. Must run before the dying
	-- flag below, since ensureActor itself refuses to act once
	-- dying[player.UserId] is set.
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

	--[[ THE interrupt check, and the only one -- per the frostbolt ruling,
		this is the one chokepoint every hit against a player already passes
		through regardless of source (a striker bolt, a ruler sweep, a
		construct tick, another dummy's cast), so it is also the one place a
		channel needs to be broken from. Gated on the technique's own
		`interruptible`, so a future uninterruptible channel is a Config
		value, not a second code path. ]]
	if target.kind == "player" and target.player then
		local cast = activeCasts[target.player.UserId]
		if cast then
			local castTech = Config.Techniques[cast.techId]
			if castTech and castTech.interruptible then
				activeCasts[target.player.UserId] = nil
				broadcastCastInterrupted(target.player.UserId, cast.techId)
			end
		end
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

--[[ A channel's payoff against a target already re-validated by
	validateLockTarget. Resolves through the same
	Combat.outgoingDamage/damageCombatant path every other technique uses --
	no parallel damage math for a channel or a projectile. Used both for an
	instant (non-projectile) channel and as the landing effect a homing
	projectile calls once it arrives, below.

	The slow is authored on the technique as an absolute WalkSpeed
	(`tech.slow.walkSpeed`, the same way strider techniques author moveSpeed)
	but applied as a multiplier via `Combat.applySlow` -- the frostbolt-
	ruling seam decided in Combat.luau. Converting here, at the one call
	site, keeps the authoring convenience without teaching the pure module
	two representations. ]]
--[[ The one place a technique's slow is ever applied, per the projectile-
	variations finding that it was previously load-bearing on castTime > 0:
	only landEffect read tech.slow, so an instant (non-channel) technique
	carrying a slow -- Chill Touch -- silently dropped it. Called from every
	resolver that lands a hit, channelled or not, so slow is a property of
	landing a hit, not of any one path to landing one. ]]
local function applySlowIfAny(
	techId: string,
	tech: Config.Technique,
	target: Combatant,
	now: number
)
	if tech.slow and target.actor.health > 0 then
		local multiplier = tech.slow.walkSpeed / Config.Combat.baseWalkSpeed
		Combat.applySlow(target.actor, techId, multiplier, tech.slow.duration, now)
		mirrorMoveSpeed(target.humanoid, target.actor, now)
		if target.kind == "player" and target.player then
			publish(target.player)
		end
	end
end

local function landEffect(
	player: Player,
	actor: Combat.Actor,
	techId: string,
	tech: Config.Technique,
	target: Combatant,
	now: number
)
	local root = rootOf(player)
	if root then
		broadcastVfx(player.UserId, techId, root.Position, target.root.Position, true)
	end

	local raw = Combat.outgoingDamage(Config, actor, techId, powerOf(player), regionOf(player), now)
	damageCombatant(actor, target, raw, now)
	applySlowIfAny(techId, tech, target, now)
end

--[[ A server-driven homing bolt, per Layer 5 and interface's own tagging
	ask: the client finds it with CollectionService:GetTagged("Projectile")
	and dresses it (trail, glow) without ever owning its motion or its
	lifetime, the same division the Combatant tag already draws between a
	dummy's state and its presentation. TechId/CasterId are the read path
	interface asked for -- the same names Impact and CastStarted already use
	for "which technique, whose". The server holds the actual state in
	`projectiles`, stepped from CombatService.tick; the part is the
	presentation of that state, not a second copy of it. ]]
type Projectile = {
	part: BasePart,
	techId: string,
	player: Player,
	casterActor: Combat.Actor,
	targetCombatantId: number,
	expiresAt: number,
}
local projectiles: { Projectile } = {}
local projectileFolder: Folder? = nil

local HOMING_PROJECTILE_SPEED = 90
local PROJECTILE_ARRIVAL_RADIUS = 4
-- A safety net against a target that never becomes reachable again after
-- launch (not already caught by the dead/gone check every tick), not a
-- number tuned for feel.
local PROJECTILE_MAX_LIFETIME = 5

local function ensureProjectileFolder(): Folder
	if projectileFolder and projectileFolder.Parent then
		return projectileFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "Projectiles"
	folder.Parent = Workspace
	projectileFolder = folder
	return folder
end

local function launchHomingProjectile(
	player: Player,
	actor: Combat.Actor,
	techId: string,
	target: Combatant,
	now: number
)
	local root = rootOf(player)
	if not root then
		return
	end

	local part = Instance.new("Part")
	part.Name = `projectile_{techId}`
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(1.4, 1.4, 1.4)
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CFrame = CFrame.new(root.Position)
	part.Parent = ensureProjectileFolder()

	CollectionService:AddTag(part, "Projectile")
	part:SetAttribute("TechId", techId)
	part:SetAttribute("CasterId", player.UserId)

	table.insert(projectiles, {
		-- Widened explicitly: table.insert's generic signature wants an
		-- exact match against `{Projectile}`'s element type, and the
		-- literal's own inferred shape is `Part` (from Instance.new
		-- itself), narrower than the field's declared `BasePart`.
		part = part :: BasePart,
		techId = techId,
		player = player,
		casterActor = actor,
		targetCombatantId = target.combatantId,
		expiresAt = now + PROJECTILE_MAX_LIFETIME,
	})
end

--[[ Advances every in-flight projectile by one step, re-aiming at its
	target's CURRENT position each step rather than a position captured at
	launch -- that is what makes it homing rather than a straight-line shot.
	A target that died or is otherwise unresolvable drops the projectile
	with no landing, same as a channel fizzling; arrival calls `landEffect`,
	the identical resolver an instant channel uses.

	Driven by its own Heartbeat connection in CombatService.start, NOT from
	CombatService.tick: `tick` runs at Config.Field.cycleTickSeconds (1s),
	coarse on purpose for regen and construct zoning, and a 90 stud/s bolt
	advancing once a second would jump in 90-stud teleports rather than
	travel. Motion needs a frame's cadence; the rest of combat does not. ]]
local function stepProjectiles(deltaSeconds: number, now: number)
	for i = #projectiles, 1, -1 do
		local projectile = projectiles[i]
		if not projectile.part.Parent then
			table.remove(projectiles, i)
			continue
		end

		local target = combatantById(projectile.targetCombatantId)
		local tech = Config.Techniques[projectile.techId]
		if not target or not tech or target.actor.health <= 0 or now >= projectile.expiresAt then
			projectile.part:Destroy()
			table.remove(projectiles, i)
			continue
		end

		local toTarget = target.root.Position - projectile.part.Position
		local distance = toTarget.Magnitude
		if distance <= PROJECTILE_ARRIVAL_RADIUS then
			landEffect(
				projectile.player,
				projectile.casterActor,
				projectile.techId,
				tech,
				target,
				now
			)
			projectile.part:Destroy()
			table.remove(projectiles, i)
			continue
		end

		local step = math.min(HOMING_PROJECTILE_SPEED * deltaSeconds, distance)
		projectile.part.CFrame = CFrame.new(projectile.part.Position + toTarget.Unit * step)
	end
end

--[[ Completion, always exactly `tech.castTime` after the cast started via
	the `task.delay` scheduled in `onUseTechnique`. Staleness-guarded the
	same way a dummy's own delayed reset is: if this exact cast is no longer
	the player's current `activeCasts` entry -- interrupted, or superseded by
	a new one -- it was already handled and this is a no-op rather than a
	second resolution. Re-validates against the target at completion time,
	not cast time, since the whole point of a channel is that the world can
	change out from under it: the target may have died, left range, or broken
	line of sight during the wait.

	`fizzled` is decided here even for a projectile technique: the channel
	itself completed and committed to a real shot, which is what "not
	fizzled" means. Whether that shot goes on to connect is the projectile's
	own question, answered later by whether landEffect ever runs -- exactly
	like a raycast striker's own cast can resolve cleanly and still miss. ]]
local function completeChannel(cast: ActiveCast)
	if activeCasts[cast.player.UserId] ~= cast then
		return
	end
	activeCasts[cast.player.UserId] = nil

	local player = cast.player
	local actor = actors[player.UserId]
	local tech = Config.Techniques[cast.techId]
	local now = os.clock()

	local fizzled = true
	if actor and actor.health > 0 and tech and cast.targetCombatantId then
		local target = validateLockTarget(tech, player, actor, cast.targetCombatantId)
		if target then
			fizzled = false
			if tech.projectile == "homing" then
				launchHomingProjectile(player, actor, cast.techId, target, now)
			else
				landEffect(player, actor, cast.techId, tech, target, now)
			end
		end
	end

	broadcastCastCompleted(player.UserId, cast.techId, fizzled)
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
	-- Item (1) of the projectile-variations set: the instant aim path never
	-- read a technique's slow before this, which Chill Touch (aim, instant,
	-- no projectile, slow) exists to prove closed.
	applySlowIfAny(techId, Config.Techniques[techId], target, now)
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
	elseif tech.kind == "strider" then
		-- Self-only, same shape as enforcer. The WalkSpeed itself was already
		-- applied at press time in `onUseTechnique`, not deferred to here --
		-- see `mirrorMoveSpeed`'s doc comment for why a movement effect can't
		-- wait for the windup the way a hit needs to.
		local root = rootOf(caster)
		if root then
			broadcastVfx(caster.UserId, techId, root.Position, nil, true)
		end
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
	no_target = "You have no target.",
	out_of_range = "Target is out of range.",
	out_of_bracket = "Target is out of your bracket.",
	target_dead = "That target has already fallen.",
	no_line_of_sight = "You cannot see your target.",
}

-- Debounced by (reason, techId) rather than reason alone: cooling_down is
-- per-technique, so a different slot also on cooldown is genuinely new
-- information and still notifies once, while mashing the same blocked slot
-- notifies only the first time. Shared between Combat.use's own refusal
-- reasons and a lock technique's target-validation reasons, which reach
-- this the same way and read the same table.
local function notifyCastRefusal(player: Player, tech, techId: string, reason: string)
	if reason == "global_cooldown" then
		return
	end
	local noticeKey = if reason == "cooling_down" then `cooling_down:{techId}` else reason
	if lastCastRefusalNotice[player.UserId] == noticeKey then
		return
	end
	lastCastRefusalNotice[player.UserId] = noticeKey
	if reason == "cooling_down" then
		AwarenessService.notify(player, "refused", `{tech.name} is still cooling.`)
	else
		AwarenessService.notify(player, "refused", REFUSAL_MESSAGES[reason] or reason)
	end
end

local function onUseTechnique(
	player: Player,
	slot: unknown,
	suppliedAim: unknown,
	suppliedTargetId: unknown
)
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

	local tech = Config.Techniques[techId]

	--[[ A lock technique's target is resolved and validated before anything
		is spent -- the same ordering principle Combat.use already applies to
		cost and cooldown, extended to the one more thing a lock technique can
		be refused over. An aim technique skips this entirely; `target` stays
		nil and `targetId` on CastStarted stays nil, exactly as it always has. ]]
	local target: Combatant? = nil
	if tech.targeting == "lock" then
		if type(suppliedTargetId) ~= "number" then
			notifyCastRefusal(player, tech, techId, "no_target")
			return
		end
		local resolvedTarget, reason = validateLockTarget(tech, player, actor, suppliedTargetId)
		if not resolvedTarget then
			notifyCastRefusal(player, tech, techId, reason or "no_target")
			return
		end
		target = resolvedTarget
	end

	local result = Combat.use(Config, actor, techId, now)
	if not result.ok then
		notifyCastRefusal(player, tech, techId, result.reason)
		if tech.moveSpeed > 0 then
			-- Kind-agnostic: not just strider. A rooted enforcer, a kiting
			-- striker, a heavy ruler that slows its own caster all carry
			-- moveSpeed too, and every one of them needs the same
			-- correction. Corrects an over-eager client prediction: the
			-- seam agreed with interface has the client lease itself a
			-- speed pulse on keypress and stop writing on refusal, but a
			-- slow or dropped refusal notice must not leave a fast client
			-- stuck at the wrong speed. `actor.buffs` was untouched by the
			-- failed `Combat.use`, so this just reasserts whatever is
			-- already true.
			mirrorMoveSpeed(humanoidOf(player), actor, now)
		end
		return
	end
	lastCastRefusalNotice[player.UserId] = nil

	publish(player)

	if tech.moveSpeed > 0 then
		-- Kind-agnostic, the same as the refusal branch above: any
		-- technique that carries moveSpeed gets it mirrored onto the
		-- Humanoid, not only strider. Applied immediately rather than
		-- after the windup, unlike every other effect a technique can
		-- carry: a movement effect that waited for a windup wouldn't be a
		-- burst, and the enforcer damage/mitigation buffs beside it already
		-- take hold at press time too -- only their VFX broadcast waits for
		-- resolveEffect. This write is also the server half of the latency
		-- seam agreed with interface: the client already predicted this the
		-- instant the key was pressed, and this is what actually reaches
		-- every other client's view of this player, and what corrects the
		-- caster's own client the moment it replicates down.
		mirrorMoveSpeed(humanoidOf(player), actor, now)
		task.delay(tech.buffDuration, function()
			if actors[player.UserId] == actor then
				mirrorMoveSpeed(humanoidOf(player), actor, os.clock())
			end
		end)
	end

	-- Announced before the windup (or the channel) rather than after it,
	-- which is the whole point: the defender's reaction window is the
	-- commit.
	broadcastCastStart(player.UserId, techId, if target then target.combatantId else nil)

	if tech.castTime > 0 then
		--[[ A channel, dispatched entirely separately from the windup path
			below: its commit is castTime (windup is 0 on any such technique,
			roster's own invariant), and its effect fires at completion, not
			after a task.delay(windup) into resolveEffect. Overwriting a
			player's own prior activeCasts entry (there should never be one --
			Combat.use's cooldown already blocks re-casting the same slot
			mid-channel, and only one channel technique exists today) would
			leave that earlier cast's own completion callback to find itself
			stale and no-op via the guard in completeChannel, rather than
			double-resolve. ]]
		local cast: ActiveCast = {
			player = player,
			techId = techId,
			targetCombatantId = if target then target.combatantId else nil,
			startedAt = now,
		}
		activeCasts[player.UserId] = cast
		task.delay(tech.castTime, function()
			completeChannel(cast)
		end)
		return
	end

	-- Aim is sampled at cast, not at resolution: a long windup is a commitment,
	-- and letting it track the camera through the telegraph would erase the
	-- counterplay the windup is there to buy.
	local aim = aimOf(player, suppliedAim)

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

	-- A fresh actor's buffs are always empty, so this reverts to
	-- baseWalkSpeed explicitly rather than assuming a new Humanoid's own
	-- default happens to already match it.
	local actor = ensureActor(player)
	if actor then
		mirrorMoveSpeed(humanoid, actor, os.clock())
	end
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
	lastCastRefusalNotice[player.UserId] = nil
	-- No CastInterrupted for a leaving caster's own in-flight channel: its
	-- completeChannel is still scheduled and will find this entry gone,
	-- fizzle silently, and broadcast nothing to clients that no longer have
	-- a reason to care about a player who already left.
	activeCasts[player.UserId] = nil
	for i = #constructs, 1, -1 do
		if constructs[i].ownerId == player.UserId then
			constructs[i].part:Destroy()
			table.remove(constructs, i)
		end
	end
end

--[[ The tick-before-expiry ordering itself lives in Combat.stepConstructTimer,
	a pure function Lune can exercise directly. Config's own doc comment on
	Technique used to instruct designers to sit a duration a half second
	past a multiple to dodge the old bug -- that was documenting it as a
	rule rather than fixing it. ]]
local function stepConstructs(now: number)
	for i = #constructs, 1, -1 do
		local construct = constructs[i]
		local shouldTick, expired =
			Combat.stepConstructTimer(construct, now, Config.Combat.constructTickSeconds)

		if shouldTick then
			local owner = Players:GetPlayerByUserId(construct.ownerId)
			local ownerActor = if owner then actors[owner.UserId] else nil
			if ownerActor then
				-- Deduped by Model rather than UserId, so a dummy standing in
				-- a construct dedupes exactly the same way a player does.
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

		if expired then
			construct.part:Destroy()
			table.remove(constructs, i)
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

	local castInterrupted = remotes:WaitForChild("CastInterrupted")
	assert(castInterrupted:IsA("RemoteEvent"), "CastInterrupted must be a RemoteEvent")
	castInterruptedRemote = castInterrupted

	local castCompleted = remotes:WaitForChild("CastCompleted")
	assert(castCompleted:IsA("RemoteEvent"), "CastCompleted must be a RemoteEvent")
	castCompletedRemote = castCompleted

	local impact = remotes:WaitForChild("Impact")
	assert(impact:IsA("RemoteEvent"), "Impact must be a RemoteEvent")
	impactRemote = impact

	local useTechnique = remotes:WaitForChild("UseTechnique")
	assert(useTechnique:IsA("RemoteEvent"), "UseTechnique must be a RemoteEvent")

	-- targetId is the fourth argument, additive: an aim technique's client
	-- never sends one, and onUseTechnique already treats a non-number there
	-- as "no target", which is exactly what a nil argument is.
	useTechnique.OnServerEvent:Connect(
		function(player: Player, slot: unknown, aim: unknown, targetId: unknown)
			onUseTechnique(player, slot, aim, targetId)
		end
	)

	local setLoadout = remotes:WaitForChild("SetLoadout")
	assert(setLoadout:IsA("RemoteEvent"), "SetLoadout must be a RemoteEvent")

	setLoadout.OnServerEvent:Connect(function(player: Player, slot: unknown, techId: unknown)
		onSetLoadout(player, slot, techId)
	end)

	-- Its own connection rather than folded into CombatService.tick -- see
	-- stepProjectiles's own doc comment for why the coarse combat tick
	-- cadence would make a homing bolt teleport instead of travel.
	RunService.Heartbeat:Connect(function(deltaSeconds: number)
		stepProjectiles(deltaSeconds, os.clock())
	end)
end

return CombatService
