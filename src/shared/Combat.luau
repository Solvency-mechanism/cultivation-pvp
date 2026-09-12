--!strict
--[[
	Combat resources, technique gating and damage resolution.

	Pure and dependency-free. Effective power is passed in as a number rather
	than recomputed here, so the refinement formula lives in exactly one place
	(Progression) and cannot drift between the two modules.

	Health scales per stage but is flat within one, while damage scales with
	refinement. That asymmetry is what pins the intra-bracket advantage at the
	intended 18% instead of letting it compound.
]]

export type Buff = {
	source: string,
	damageBuff: number,
	mitigation: number,
	moveSpeed: number,
	slowMultiplier: number,
	expiresAt: number,
}

--[[ A plain position, not Roblox's Vector3, so this module loads under Lune
	as well as Roblox -- same reason AuraNodes.Vec3 exists, and the same
	shape. Not the same declared type only because this module takes no
	internal requires. Vector3 is a distinct builtin, not a table, so it
	does not satisfy this on its own -- NodeService.placer's own callers
	already construct `{ x = v.X, y = v.Y, z = v.Z }` at the boundary rather
	than pass a Vector3 through, and CombatService does the same here. ]]
export type Vec3 = { x: number, y: number, z: number }

export type Actor = {
	id: string,
	stageIndex: number,
	health: number,
	aura: number,
	cooldowns: { [string]: number },
	gcdUntil: number,
	buffs: { Buff },
}

export type UseResult = {
	ok: boolean,
	reason: string,
	damage: number,
}

export type DamageResult = {
	dealt: number,
	died: boolean,
}

local Combat = {}

local MAX_MITIGATION = 0.80

local function techniqueData(config: any, techId: string)
	local tech = config.Techniques[techId]
	assert(tech ~= nil, `unknown technique "{techId}"`)
	return tech
end

local function stageData(config: any, stageIndex: number)
	local stage = config.Stages[stageIndex]
	assert(stage ~= nil, `invalid stageIndex {stageIndex}`)
	return stage
end

function Combat.maxHealth(config: any, stageIndex: number): number
	return stageData(config, stageIndex).basePower * config.Combat.healthMultiplier
end

function Combat.auraCapacity(config: any, stageIndex: number): number
	return stageData(config, stageIndex).basePower * config.Combat.auraMultiplier
end

function Combat.newActor(config: any, id: string, stageIndex: number): Actor
	return {
		id = id,
		stageIndex = stageIndex,
		health = Combat.maxHealth(config, stageIndex),
		aura = Combat.auraCapacity(config, stageIndex),
		cooldowns = {},
		gcdUntil = 0,
		buffs = {},
	}
end

--[[ Drop lapsed buffs. Called wherever buff totals are read so expiry needs no
	separate timer. ]]
function Combat.pruneBuffs(actor: Actor, now: number)
	for i = #actor.buffs, 1, -1 do
		if now >= actor.buffs[i].expiresAt then
			table.remove(actor.buffs, i)
		end
	end
end

function Combat.damageBuffOf(actor: Actor, now: number): number
	Combat.pruneBuffs(actor, now)
	local total = 0
	for _, buff in actor.buffs do
		total += buff.damageBuff
	end
	return total
end

--[[ Mitigation stacks multiplicatively so several sources can never reach
	total immunity, then is clamped as a backstop. ]]
function Combat.mitigationOf(actor: Actor, now: number): number
	Combat.pruneBuffs(actor, now)
	local remaining = 1.0
	for _, buff in actor.buffs do
		remaining *= (1 - buff.mitigation)
	end
	return math.min(1 - remaining, MAX_MITIGATION)
end

--[[ The highest live moveSpeed override, or 0 if none -- the caller's cue to
	fall back to base WalkSpeed. "Highest wins" rather than stacking, so a
	burst popped mid-sustain reads as a burst on top of a sustain rather than
	an arbitrary sum of two speeds nobody tuned together. ]]
function Combat.moveSpeedOf(actor: Actor, now: number): number
	Combat.pruneBuffs(actor, now)
	local highest = 0
	for _, buff in actor.buffs do
		if buff.moveSpeed > highest then
			highest = buff.moveSpeed
		end
	end
	return highest
end

--[[ Multiplicative, applied on top of whatever moveSpeedOf already resolved
	(an override or base speed) -- deliberately NOT represented as another
	moveSpeed buff, per the frostbolt-ruling seam: moveSpeedOf takes the
	HIGHEST live override, so a slow expressed as a low moveSpeed would lose
	outright to any unrelated buff already live at or above it (windstride's
	sustain 24 alone would silently cancel an 8 slow, with no dash spent and
	nothing to counter). A multiplier always bites, proportionally, on
	whatever speed is actually in effect -- so a caster mid-lunge (80) who
	gets slowed 0.5 drops to 40, a real, costed escape, while someone merely
	sustaining at 24 drops to 12, genuinely slowed. Stacks multiplicatively
	like mitigation, for the same never-reaches-zero reason. ]]
function Combat.slowMultiplierOf(actor: Actor, now: number): number
	Combat.pruneBuffs(actor, now)
	local total = 1.0
	for _, buff in actor.buffs do
		total *= buff.slowMultiplier
	end
	return total
end

--[[ Inflicted on a target by a hit landing, not a self-buff -- so this does
	not go through Combat.use, which only ever touches the calling actor.
	Refreshes rather than stacks with itself, same discipline Combat.use's
	own self-buff insertion already uses, keyed by `source` so a second
	frostbolt from a different caster is a distinct entry rather than a
	refresh of this one. ]]
function Combat.applySlow(
	actor: Actor,
	source: string,
	multiplier: number,
	duration: number,
	now: number
)
	for i = #actor.buffs, 1, -1 do
		if actor.buffs[i].source == source then
			table.remove(actor.buffs, i)
		end
	end
	table.insert(actor.buffs, {
		source = source,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 0,
		slowMultiplier = multiplier,
		expiresAt = now + duration,
	})
end

--[[ Brackets never mix. An out-of-bracket engagement is refused outright
	rather than balanced. ]]
function Combat.canEngage(a: Actor, b: Actor): boolean
	return a.stageIndex == b.stageIndex
end

--[[ From the ATTACKER's (a's) view, per bracket-tone.md: "below" means the
	target is below the attacker -- punching down -- and "above" means the
	target is above -- punching up. Pure and decides nothing about what
	happens next; canEngage above is unchanged and still the only thing that
	decides whether brackets mix. The caller (damageCombatant, in
	CombatService) decides what a mismatch means under whichever
	crossBracket mode is active. ]]
function Combat.bracketRelation(a: Actor, b: Actor): "same" | "above" | "below"
	if a.stageIndex == b.stageIndex then
		return "same"
	elseif b.stageIndex > a.stageIndex then
		return "above"
	else
		return "below"
	end
end

local function distance(a: Vec3, b: Vec3): number
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return (dx * dx + dy * dy + dz * dz) ^ 0.5
end

--[[ Whether a lock technique may resolve against a specific target right
	now: alive, same bracket, in range, with line of sight. The distance
	check is pure arithmetic; the line-of-sight raycast is a Roblox API and
	cannot live in a pure module, so it is injected -- the same pattern
	NodeService.placer and CultivationService's refusal handler already use
	for the identical problem. Lune passes a stub; CombatService passes a
	real Workspace:Raycast wrapper. Interface's reach pip calls this exact
	function for a lock technique too, so there is exactly one answer to
	"can I hit this" rather than a client copy that can drift from the
	server's. ]]
--[[ `ignoreBracket`, per npcs.md: an NPC has no bracket relation to anyone,
	and `Actor` itself carries no `kind` to detect that from -- only the
	caller (CombatService, which knows a target's `Combatant.kind`) can tell.
	This does not touch `canEngage`, which the bracket-tone ruling keeps pure
	and unchanged; it only lets THIS function's own bracket check be skipped
	by a caller that already knows it should be. ]]
function Combat.canUseOnTarget(
	caster: Actor,
	casterPosition: Vec3,
	target: Actor,
	targetPosition: Vec3,
	range: number,
	hasLineOfSight: (Vec3, Vec3) -> boolean,
	ignoreBracket: boolean?
): (boolean, string)
	if target.health <= 0 then
		return false, "target_dead"
	end
	if not ignoreBracket and not Combat.canEngage(caster, target) then
		return false, "out_of_bracket"
	end
	if distance(casterPosition, targetPosition) > range then
		return false, "out_of_range"
	end
	if not hasLineOfSight(casterPosition, targetPosition) then
		return false, "no_line_of_sight"
	end
	return true, "ok"
end

function Combat.canUse(config: any, actor: Actor, techId: string, now: number): (boolean, string)
	local tech = techniqueData(config, techId)
	if actor.health <= 0 then
		return false, "dead"
	end
	if now < actor.gcdUntil then
		return false, "global_cooldown"
	end
	local readyAt = actor.cooldowns[techId]
	if readyAt and now < readyAt then
		return false, "cooling_down"
	end
	if actor.aura < tech.auraCost then
		return false, "insufficient_aura"
	end
	return true, "ok"
end

--[[ Outgoing damage before the target's mitigation.

	Ruler techniques multiply by terrain richness, which is what makes map
	position matter without any content authored for it. ]]
function Combat.outgoingDamage(
	config: any,
	actor: Actor,
	techId: string,
	power: number,
	region: string,
	now: number
): number
	local tech = techniqueData(config, techId)
	if tech.damage <= 0 then
		return 0
	end
	local damage = tech.damage * (power / config.Combat.referencePower)
	if tech.regionScaled then
		damage *= config.StaticRegionMultipliers[region] or 1.0
	end
	damage *= (1 + Combat.damageBuffOf(actor, now))
	return damage
end

--[[ Spend aura, start cooldowns, and apply any self-buff the technique
	carries. Mutates and returns the actor. ]]
function Combat.use(config: any, actor: Actor, techId: string, now: number): UseResult
	local ok, reason = Combat.canUse(config, actor, techId, now)
	if not ok then
		return { ok = false, reason = reason, damage = 0 }
	end

	local tech = techniqueData(config, techId)
	actor.aura -= tech.auraCost
	actor.cooldowns[techId] = now + tech.cooldown
	actor.gcdUntil = now + config.Combat.globalCooldown

	if
		tech.buffDuration > 0 and (tech.damageBuff > 0 or tech.mitigation > 0 or tech.moveSpeed > 0)
	then
		-- Reapplying a technique refreshes rather than stacks with itself.
		for i = #actor.buffs, 1, -1 do
			if actor.buffs[i].source == techId then
				table.remove(actor.buffs, i)
			end
		end
		table.insert(actor.buffs, {
			source = techId,
			damageBuff = tech.damageBuff,
			mitigation = tech.mitigation,
			moveSpeed = tech.moveSpeed,
			-- 1.0, not 0: this is the multiplier's identity value, unlike
			-- every field beside it where 0 means "no effect". Nothing self-
			-- slows through Combat.use today -- a slow lands on a target via
			-- Combat.applySlow, inflicted by a hit, never by casting.
			slowMultiplier = 1.0,
			expiresAt = now + tech.buffDuration,
		})
	end

	return { ok = true, reason = "ok", damage = 0 }
end

-- config is unused here but kept so every entry point shares one shape.
function Combat.applyDamage(_config: any, target: Actor, raw: number, now: number): DamageResult
	if target.health <= 0 then
		return { dealt = 0, died = false }
	end
	local mitigated = raw * (1 - Combat.mitigationOf(target, now))
	local dealt = math.min(mitigated, target.health)
	target.health -= dealt
	local died = target.health <= 0
	if died then
		target.health = 0
	end
	return { dealt = dealt, died = died }
end

--[[ Refinement lost on death, for the caller to hand to Progression.applyLoss.
	Returned rather than applied so the ratchet stays in one module. ]]
function Combat.deathLoss(config: any, stageIndex: number): number
	local stage = stageData(config, stageIndex)
	return stage.perTierProgress * config.Combat.deathLossTierFraction
end

--[[ A construct's tick/expiry decision for one step, extracted out of
	CombatService's Roblox-coupled stepConstructs so it is unit-testable
	under Lune without instantiating that whole binding layer. Tick is
	decided before expiry and mutates `timer.nextTickAt` in place when it
	fires, so a duration landing exactly on a tick still delivers that tick
	before the caller removes the construct -- checking expiry first would
	silently eat the last tick of any duration that is an exact multiple of
	`tickSeconds`. ]]
function Combat.stepConstructTimer(
	timer: { nextTickAt: number, expiresAt: number },
	now: number,
	tickSeconds: number
): (boolean, boolean)
	local shouldTick = now >= timer.nextTickAt
	if shouldTick then
		timer.nextTickAt = now + tickSeconds
	end
	return shouldTick, now >= timer.expiresAt
end

--[[ Resolve a client-supplied slot name against the server-held loadout.

	This is the trust boundary. The client sends a slot name and nothing else,
	so an unknown slot, an empty slot, an unknown technique or a technique whose
	kind does not match its slot is refused here -- in a module that is unit
	tested -- rather than deeper inside the service.  ]]
function Combat.resolveSlot(
	config: any,
	loadout: { [string]: string },
	slot: unknown
): (string?, string)
	if type(slot) ~= "string" then
		return nil, "invalid_slot"
	end
	local isKnownSlot = false
	for _, valid in config.LoadoutSlots do
		if slot == valid then
			isKnownSlot = true
			break
		end
	end
	if not isKnownSlot then
		return nil, "unknown_slot"
	end
	local techId = loadout[slot]
	if not techId then
		return nil, "empty_slot"
	end
	local tech = config.Techniques[techId]
	if not tech then
		return nil, "unknown_technique"
	end
	if tech.kind ~= slot then
		return nil, "slot_kind_mismatch"
	end
	return techId, "ok"
end

--[[ A loadout is exactly one technique per slot, each matching its slot kind. ]]
function Combat.validateLoadout(config: any, loadout: { [string]: string }): (boolean, string)
	for _, slot in config.LoadoutSlots do
		local techId = loadout[slot]
		if not techId then
			return false, `missing slot "{slot}"`
		end
		local tech = config.Techniques[techId]
		if not tech then
			return false, `unknown technique "{techId}"`
		end
		if tech.kind ~= slot then
			return false, `"{techId}" is a {tech.kind}, not a {slot}`
		end
	end
	for slot in loadout do
		local known = false
		for _, valid in config.LoadoutSlots do
			if slot == valid then
				known = true
				break
			end
		end
		if not known then
			return false, `unexpected slot "{slot}"`
		end
	end
	return true, "ok"
end

return Combat
