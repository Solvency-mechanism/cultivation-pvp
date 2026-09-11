--!strict
--[[ Run with: lune run tests/combat.test ]]

local process = require("@lune/process")
local Combat = require("../src/shared/Combat")
local Config = require("../src/shared/Config")
local Progression = require("../src/shared/Progression")

local passed, failed = 0, 0
local failures: { string } = {}

local function check(name: string, ok: boolean, detail: string?)
	if ok then
		passed += 1
	else
		failed += 1
		table.insert(failures, `{name}{if detail then ` -- {detail}` else ""}`)
	end
end

local function eq(name: string, actual: any, expected: any)
	check(name, actual == expected, `expected {expected}, got {actual}`)
end

local function near(name: string, actual: number, expected: number, tol: number)
	check(name, math.abs(actual - expected) <= tol, `expected ~{expected}, got {actual}`)
end

local LOWGOLD, TRUEGOLD = 5, #Config.Stages

local function stateAt(stageIndex: number, tier: number): Progression.State
	return { stageIndex = stageIndex, tier = tier, progress = 0, catalysts = 0 }
end

local function powerAt(stageIndex: number, tier: number): number
	return Progression.effectivePower(Config, stateAt(stageIndex, tier))
end

-- Resource pools
eq("Lowgold health", Combat.maxHealth(Config, LOWGOLD), 100 * 4)
eq("Lowgold madra", Combat.maxMadra(Config, LOWGOLD), 100 * 2)
check(
	"health grows across brackets",
	Combat.maxHealth(Config, TRUEGOLD) > Combat.maxHealth(Config, LOWGOLD)
)

--[[ The central balance claim: a maxed cultivator advantage over a fresh one
	in the same bracket is exactly the 18% refinement spread -- no more. If
	health also scaled with refinement this would compound to roughly 64%. ]]
local freshPower = powerAt(LOWGOLD, 1)
local maxedPower = powerAt(LOWGOLD, Config.RefinementTiers)
local hp = Combat.maxHealth(Config, LOWGOLD)

local dummy = Combat.newActor(Config, "dummy", LOWGOLD)
local freshHit = Combat.outgoingDamage(Config, dummy, "lance", freshPower, "open", 0)
local maxedHit = Combat.outgoingDamage(Config, dummy, "lance", maxedPower, "open", 0)

local hitsMaxedToKillFresh = hp / maxedHit
local hitsFreshToKillMaxed = hp / freshHit
near(
	"intra-bracket TTK advantage is exactly 18%",
	hitsFreshToKillMaxed / hitsMaxedToKillFresh,
	1.18,
	1e-9
)

-- Time-to-kill should hold steady across brackets, so higher stages feel
-- bigger without fights getting longer.
local function ttkAt(stageIndex: number): number
	local a = Combat.newActor(Config, "a", stageIndex)
	local dmg = Combat.outgoingDamage(Config, a, "lance", powerAt(stageIndex, 1), "open", 0)
	return Combat.maxHealth(Config, stageIndex) / dmg
end
near("TTK constant Lowgold vs Highgold", ttkAt(LOWGOLD), ttkAt(6), 1e-9)
near("TTK constant Lowgold vs Truegold", ttkAt(LOWGOLD), ttkAt(TRUEGOLD), 1e-9)

-- Madra gating
local actor = Combat.newActor(Config, "p1", LOWGOLD)
check("can open with a striker", (Combat.canUse(Config, actor, "lance", 0)))
actor.madra = 5
local okPoor, reasonPoor = Combat.canUse(Config, actor, "lance", 0)
check("blocked when drained", not okPoor)
eq("drained reason", reasonPoor, "insufficient_madra")

-- Cooldowns and the global cooldown
local a2 = Combat.newActor(Config, "p2", LOWGOLD)
local used = Combat.use(Config, a2, "lance", 100)
check("use succeeded", used.ok)
near("madra spent", a2.madra, 200 - Config.Techniques.lance.madraCost, 1e-9)

local okGcd, reasonGcd = Combat.canUse(Config, a2, "volley", 100.1)
check("global cooldown blocks a follow-up", not okGcd)
eq("gcd reason", reasonGcd, "global_cooldown")
check(
	"other technique frees after gcd",
	(Combat.canUse(Config, a2, "volley", 100 + Config.Combat.globalCooldown))
)

local okCd, reasonCd = Combat.canUse(Config, a2, "lance", 100.9)
check("same technique still cooling", not okCd)
eq("cooldown reason", reasonCd, "cooling_down")
check(
	"ready after its cooldown",
	(Combat.canUse(Config, a2, "lance", 100 + Config.Techniques.lance.cooldown))
)

-- Buffs
local b = Combat.newActor(Config, "p3", LOWGOLD)
Combat.use(Config, b, "surge", 0)
near(
	"surge grants its damage buff",
	Combat.damageBuffOf(b, 1),
	Config.Techniques.surge.damageBuff,
	1e-9
)
local buffedHit = Combat.outgoingDamage(Config, b, "lance", freshPower, "open", 1)
near("buff multiplies outgoing damage", buffedHit, freshHit * 1.35, 1e-6)
near("buff lapses on schedule", Combat.damageBuffOf(b, 99), 0, 1e-9)
eq("lapsed buffs are pruned", #b.buffs, 0)

-- Reapplying refreshes rather than stacking with itself
local r = Combat.newActor(Config, "p4", LOWGOLD)
Combat.use(Config, r, "surge", 0)
r.cooldowns.surge = 0
Combat.use(Config, r, "surge", 1)
eq("one surge buff, not two", #r.buffs, 1)
near("refreshed damage buff", Combat.damageBuffOf(r, 2), Config.Techniques.surge.damageBuff, 1e-9)

-- Mitigation stacks multiplicatively and is capped
local m = Combat.newActor(Config, "p5", LOWGOLD)
Combat.use(Config, m, "bulwark", 0)
near("single mitigation source", Combat.mitigationOf(m, 1), 0.40, 1e-9)
Combat.use(Config, m, "barrier", 0.5)
near("two sources stack multiplicatively", Combat.mitigationOf(m, 1), 1 - (0.6 * 0.45), 1e-9)
check("stacked mitigation stays under 1", Combat.mitigationOf(m, 1) < 1)

-- Ruler techniques read the terrain; others ignore it
local t = Combat.newActor(Config, "p6", LOWGOLD)
local siphonOpen = Combat.outgoingDamage(Config, t, "siphon", freshPower, "open", 0)
local siphonWell = Combat.outgoingDamage(Config, t, "siphon", freshPower, "wellspring", 0)
local siphonBarren = Combat.outgoingDamage(Config, t, "siphon", freshPower, "barren", 0)
near("ruler scales up in a wellspring", siphonWell / siphonOpen, 2.6, 1e-9)
near("ruler scales down on barren ground", siphonBarren / siphonOpen, 0.5, 1e-9)
local lanceWell = Combat.outgoingDamage(Config, t, "lance", freshPower, "wellspring", 0)
near("striker ignores terrain", lanceWell, freshHit, 1e-9)

-- Damage application
local target = Combat.newActor(Config, "t1", LOWGOLD)
local hit = Combat.applyDamage(Config, target, 100, 0)
near("full damage with no mitigation", hit.dealt, 100, 1e-9)
check("survivor is not dead", not hit.died)
local lethal = Combat.applyDamage(Config, target, 99999, 0)
check("lethal blow kills", lethal.died)
eq("health floors at zero", target.health, 0)
near("overkill is clamped to remaining health", lethal.dealt, 400 - 100, 1e-9)
eq("corpses take no further damage", Combat.applyDamage(Config, target, 50, 0).dealt, 0)

local mitigated = Combat.newActor(Config, "t2", LOWGOLD)
Combat.use(Config, mitigated, "bulwark", 0)
near("mitigation reduces incoming", Combat.applyDamage(Config, mitigated, 100, 1).dealt, 60, 1e-9)

local deadActor = Combat.newActor(Config, "t3", LOWGOLD)
deadActor.health = 0
local okDead, reasonDead = Combat.canUse(Config, deadActor, "lance", 0)
check("the dead cannot act", not okDead)
eq("dead reason", reasonDead, "dead")

--[[ Madra regen. The expectation is DERIVED from Config rather than written as
	a literal: what this proves is that `Combat.regen` applies the configured
	fraction of the pool per second, not that the fraction holds any particular
	value. The development tuning profile legitimately raises it to 0.60 so that
	cooldowns become the only constraint while testing, and a literal here turned
	that into a test failure when nothing was broken. ]]
local g = Combat.newActor(Config, "p7", LOWGOLD)
local madraPool = Combat.maxMadra(Config, LOWGOLD)
g.madra = 0
Combat.regen(Config, g, 1)
near(
	"regen is the configured fraction of the pool per second",
	g.madra,
	math.min(madraPool, madraPool * Config.Combat.madraRegenFraction),
	1e-9
)
Combat.regen(Config, g, 9999)
near("regen never exceeds the pool", g.madra, madraPool, 1e-9)

-- Brackets
local low = Combat.newActor(Config, "low", LOWGOLD)
local high = Combat.newActor(Config, "high", 6)
check("same bracket can engage", Combat.canEngage(low, Combat.newActor(Config, "low2", LOWGOLD)))
check("cross bracket cannot", not Combat.canEngage(low, high))

-- Loadouts: one per slot, kinds must match
check("default loadout is valid", (Combat.validateLoadout(Config, Config.DefaultLoadout)))
local okKind, reasonKind = Combat.validateLoadout(Config, {
	striker = "surge",
	enforcer = "surge",
	forger = "barrier",
	ruler = "siphon",
})
check("wrong kind in a slot is rejected", not okKind)
check("rejection explains why", string.find(reasonKind, "not a striker") ~= nil, reasonKind)
check("missing slot rejected", not (Combat.validateLoadout(Config, { striker = "lance" })))
check(
	"unknown technique rejected",
	not (
			Combat.validateLoadout(
				Config,
				{ striker = "nope", enforcer = "surge", forger = "barrier", ruler = "siphon" }
			)
		)
)

-- Every technique in the pool is well formed and slotable
local byKind: { [string]: number } = {}
for id, tech in Config.Techniques do
	eq(`{id} id matches its key`, tech.id, id)
	check(`{id} costs madra`, tech.madraCost > 0)
	check(`{id} has a cooldown`, tech.cooldown > 0)
	byKind[tech.kind] = (byKind[tech.kind] or 0) + 1
end
for _, slot in Config.LoadoutSlots do
	eq(`three options for {slot}`, byKind[slot], 3)
end

-- Death feeds the ratchet: costly, but never a demotion.
local loss = Combat.deathLoss(Config, LOWGOLD)
near("death costs 35% of a tier", loss, Config.Stages[LOWGOLD].perTierProgress * 0.35, 1e-9)
local afterDeath = Progression.applyLoss(Config, stateAt(LOWGOLD, 1), loss)
eq("death never demotes the stage", afterDeath.stageIndex, LOWGOLD)
eq("death floors at the stage bottom", afterDeath.tier, 1)

-- Slot resolution is the trust boundary: the client sends a slot name, and the
-- server must refuse everything that is not one of its own four slots.
do
	local techId, reason = Combat.resolveSlot(Config, Config.DefaultLoadout, "striker")
	eq("resolves a real slot", techId, Config.DefaultLoadout.striker)
	eq("resolve reason is ok", reason, "ok")
end
for _, bad in { "damage", "Striker", "", "../src/shared/Config" } do
	eq(`refuses slot "{bad}"`, Combat.resolveSlot(Config, Config.DefaultLoadout, bad), nil)
end
for _, bad in { 1, true, {} } do
	eq(
		`refuses non-string slot {typeof(bad)}`,
		Combat.resolveSlot(Config, Config.DefaultLoadout, bad),
		nil
	)
end
eq("refuses a nil slot", Combat.resolveSlot(Config, Config.DefaultLoadout, nil), nil)
do
	-- A loadout whose technique does not match its slot kind is refused rather
	-- than silently firing a Ruler out of the Striker key.
	local crossed =
		{ striker = "tempest", enforcer = "surge", forger = "barrier", ruler = "siphon" }
	local techId, reason = Combat.resolveSlot(Config, crossed, "striker")
	eq("refuses a kind mismatch", techId, nil)
	eq("kind mismatch is named", reason, "slot_kind_mismatch")
end

-- A fresh player must have no dead key.
for _, slot in Config.LoadoutSlots do
	check(
		`default loadout fills {slot}`,
		Combat.resolveSlot(Config, Config.DefaultLoadout, slot) ~= nil
	)
end

--[[ Constructs are zoning pressure, not kill buttons. Their damage is per tick,
	so the tick cadence decides whether standing in one is a mistake or a death
	sentence. If either bound trips, constructTickSeconds is wrong. ]]
local tickSeconds = Config.Combat.constructTickSeconds
check("construct tick cadence is set", tickSeconds > 0)
for _, techId in { "caltrops", "sentry" } do
	local tech = Config.Techniques[techId]
	local owner = Combat.newActor(Config, "construct-owner", LOWGOLD)
	local perTick = Combat.outgoingDamage(Config, owner, techId, powerAt(LOWGOLD, 1), "open", 0)
	local total = perTick * math.floor(tech.buffDuration / tickSeconds)
	check(`{techId} cannot kill from full over its whole duration`, total < hp)
	check(`{techId} is worth stepping out of`, total > hp * 0.2)
end

-- Reach is ordered the way the kinds are described: Striker pokes from range,
-- Ruler blankets an area, Forger drops something at its feet, Enforcer is self.
local ranges = Config.Combat.ranges
check("striker outreaches ruler", ranges.striker > ranges.ruler)
check("ruler outreaches forger", ranges.ruler > ranges.forger)
eq("enforcer is self only", ranges.enforcer, 0)
check("respawn delay is set", Config.Combat.respawnSeconds > 0)

--[[ Windup is the counterplay budget: the harder a technique hits, the longer it
	telegraphs. Checked per kind, since kinds sit on different damage scales. ]]
for _, kind in { "striker", "ruler" } do
	local pool = {}
	for _, tech in Config.Techniques do
		if tech.kind == kind then
			table.insert(pool, tech)
		end
	end
	table.sort(pool, function(left, right)
		return left.damage < right.damage
	end)
	for i = 2, #pool do
		check(
			`{kind}: {pool[i].id} telegraphs longer than {pool[i - 1].id}`,
			pool[i].windup > pool[i - 1].windup
		)
	end
end

print(`\n  passed: {passed}   failed: {failed}`)
if failed > 0 then
	for _, f in failures do
		print(`  FAIL  {f}`)
	end
	process.exit(1)
end
print("  all combat tests passed\n")
