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
	expiresAt: number,
}

export type Actor = {
	id: string,
	stageIndex: number,
	health: number,
	madra: number,
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

function Combat.maxMadra(config: any, stageIndex: number): number
	return stageData(config, stageIndex).basePower * config.Combat.madraMultiplier
end

function Combat.newActor(config: any, id: string, stageIndex: number): Actor
	return {
		id = id,
		stageIndex = stageIndex,
		health = Combat.maxHealth(config, stageIndex),
		madra = Combat.maxMadra(config, stageIndex),
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

--[[ Brackets never mix. An out-of-bracket engagement is refused outright
	rather than balanced. ]]
function Combat.canEngage(a: Actor, b: Actor): boolean
	return a.stageIndex == b.stageIndex
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
	if actor.madra < tech.madraCost then
		return false, "insufficient_madra"
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

--[[ Spend madra, start cooldowns, and apply any self-buff the technique
	carries. Mutates and returns the actor. ]]
function Combat.use(config: any, actor: Actor, techId: string, now: number): UseResult
	local ok, reason = Combat.canUse(config, actor, techId, now)
	if not ok then
		return { ok = false, reason = reason, damage = 0 }
	end

	local tech = techniqueData(config, techId)
	actor.madra -= tech.madraCost
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

function Combat.regen(config: any, actor: Actor, deltaSeconds: number)
	local pool = Combat.maxMadra(config, actor.stageIndex)
	actor.madra =
		math.min(pool, actor.madra + pool * config.Combat.madraRegenFraction * deltaSeconds)
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
