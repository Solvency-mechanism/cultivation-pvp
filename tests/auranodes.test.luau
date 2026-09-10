--!strict
--[[ Run with: lune run tests/auranodes.test ]]

local process = require("@lune/process")
local Config = require("../src/shared/Config")
local AuraNodes = require("../src/shared/AuraNodes")

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

-- Deterministic sequence rng, and a seeded LCG for distribution work.
local function scripted(values: { number }): () -> number
	local i = 0
	return function()
		i += 1
		return values[((i - 1) % #values) + 1]
	end
end

local function lcg(seed: number): () -> number
	local state = seed
	return function()
		state = (1103515245 * state + 12345) % 2147483648
		return state / 2147483648
	end
end

local ORIGIN = { x = 0, y = 0, z = 0 }

--[[ Weighted tier roll. Expectations are DERIVED from Config rather than
	written as literals: what is being tested is that rollTier reads the
	configured weights faithfully, not that the weights hold any particular
	value. Baking today's numbers in here made a legitimate retune look like a
	regression, which is a test bug rather than a tuning one. ]]
local totalWeight = 0
for _, entry in Config.Field.spawnWeights do
	totalWeight += entry.weight
end

-- Cumulative band edges, in the same order rollTier walks them.
local bands: { { tier: string, lo: number, hi: number } } = {}
local cursor = 0
for _, entry in Config.Field.spawnWeights do
	local lo = cursor / totalWeight
	cursor += entry.weight
	table.insert(bands, { tier = entry.tier, lo = lo, hi = cursor / totalWeight })
end

eq(
	"low roll picks the first weighted tier",
	AuraNodes.rollTier(Config, scripted({ 0.0 })),
	bands[1].tier
)
eq(
	"top of range stays valid",
	AuraNodes.rollTier(Config, scripted({ 0.999999 })),
	bands[#bands].tier
)

-- Each band's interior resolves to its own tier, on both sides of every edge.
for _, band in bands do
	local inside = (band.lo + band.hi) / 2
	eq(
		`mid-band roll picks {band.tier}`,
		AuraNodes.rollTier(Config, scripted({ inside })),
		band.tier
	)
	eq(
		`just inside {band.tier}'s lower edge`,
		AuraNodes.rollTier(Config, scripted({ band.lo + 1e-6 })),
		band.tier
	)
	eq(
		`just inside {band.tier}'s upper edge`,
		AuraNodes.rollTier(Config, scripted({ band.hi - 1e-6 })),
		band.tier
	)
end

-- Distribution should track the configured weights, whatever they are.
local counts: { [string]: number } = {}
for _, entry in Config.Field.spawnWeights do
	counts[entry.tier] = 0
end
local rng = lcg(20260909)
local N = 20000
for _ = 1, N do
	local t = AuraNodes.rollTier(Config, rng)
	counts[t] += 1
end
for _, entry in Config.Field.spawnWeights do
	near(
		`{entry.tier} tracks its configured weight`,
		counts[entry.tier] / N,
		entry.weight / totalWeight,
		0.02
	)
end

-- Lifetime and expiry
local node = AuraNodes.create(Config, "n1", "common", ORIGIN, "open", 100)
eq("expiry from tier lifetime", node.expiresAt, 100 + Config.NodeTiers.common.lifetime)
check("alive before expiry", not AuraNodes.isExpired(node, 200))
check("expired after lifetime", AuraNodes.isExpired(node, 100 + Config.NodeTiers.common.lifetime))

-- Capacity is the anti-zerg valve
local cap = Config.NodeTiers.common.capacity
eq("capacity is 3", cap, 3)
for i = 1, cap do
	local ok = AuraNodes.addOccupant(Config, node, `u{i}`, 150)
	check(`occupant {i} admitted`, ok)
end
local ok4, reason4 = AuraNodes.addOccupant(Config, node, "u4", 150)
check("fourth occupant refused", not ok4)
eq("refusal reason is capacity", reason4, "at_capacity")
eq("occupant count tracked", node.occupantCount, cap)

local okDup, reasonDup = AuraNodes.addOccupant(Config, node, "u1", 150)
check("duplicate refused", not okDup)
eq("duplicate reason", reasonDup, "already_occupying")

check("remove works", AuraNodes.removeOccupant(node, "u1"))
eq("count decremented", node.occupantCount, cap - 1)
check("removing absentee is a no-op", not AuraNodes.removeOccupant(node, "ghost"))
check("slot freed after removal", (AuraNodes.addOccupant(Config, node, "u4", 150)))

local expiredNode = AuraNodes.create(Config, "n2", "common", ORIGIN, "open", 0)
local okExp, reasonExp = AuraNodes.addOccupant(Config, expiredNode, "u1", 99999)
check("cannot occupy expired node", not okExp)
eq("expired reason", reasonExp, "expired")

-- Cycle rates
local base = Config.BaseCycleRate
near("bare rate in open ground", AuraNodes.cycleRate(Config, nil, "open", true), base, 1e-9)
near("common node triples", AuraNodes.cycleRate(Config, node, "open", true), base * 3, 1e-9)

local primeNode = AuraNodes.create(Config, "n3", "prime", ORIGIN, "wellspring", 0)
near(
	"prime in a wellspring stacks",
	AuraNodes.cycleRate(Config, primeNode, "wellspring", true),
	base * 20 * 2.6,
	1e-9
)
near("offline is quartered", AuraNodes.cycleRate(Config, nil, "open", false), base * 0.25, 1e-9)
near("barren ground halves", AuraNodes.cycleRate(Config, nil, "barren", true), base * 0.5, 1e-9)

-- Catalysts gate advancement, and only Prime guarantees one
check(
	"common never drops a catalyst",
	not AuraNodes.rollCatalyst(Config, "common", scripted({ 0.0 }))
)
check("prime always drops", AuraNodes.rollCatalyst(Config, "prime", scripted({ 0.999 })))
check("rare drops under threshold", AuraNodes.rollCatalyst(Config, "rare", scripted({ 0.10 })))
check("rare misses above threshold", not AuraNodes.rollCatalyst(Config, "rare", scripted({ 0.20 })))

-- Telegraph tiers drive the pacing heartbeat
eq("common is local", AuraNodes.telegraphOf(Config, node), "local")
eq("prime is server-wide", AuraNodes.telegraphOf(Config, primeNode), "server")

-- Contest detection
local contest = AuraNodes.create(Config, "n4", "rare", ORIGIN, "open", 0)
local factions = { a1 = "clanA", a2 = "clanA", b1 = "clanB" }
local function factionOf(userId: string): string?
	return factions[userId]
end
AuraNodes.addOccupant(Config, contest, "a1", 0)
AuraNodes.addOccupant(Config, contest, "a2", 0)
check("single faction is uncontested", not AuraNodes.isContested(contest, factionOf))
AuraNodes.addOccupant(Config, contest, "b1", 0)
check("two factions is contested", AuraNodes.isContested(contest, factionOf))
local tally = AuraNodes.contestedBy(contest, factionOf)
eq("clanA counted", tally.clanA, 2)
eq("clanB counted", tally.clanB, 1)

-- Field stepping
local field: { AuraNodes.Node } = {}
local counter = 0
local function nextId(): string
	counter += 1
	return `node{counter}`
end
local function placer(_tier: string): (AuraNodes.Vec3, string)
	return ORIGIN, "open"
end

local stepRng = lcg(7)
for i = 1, 50 do
	AuraNodes.step(Config, field, i, stepRng, nextId, placer)
end
eq("field fills to the cap", #field, Config.Field.maxActiveNodes)

-- Push time past every lifetime; expired nodes are culled, then refilled once.
local farFuture = 100000
AuraNodes.step(Config, field, farFuture, stepRng, nextId, placer)
eq("expired nodes culled, one respawned", #field, 1)

--[[ Sensing. This is what turns sense range from a number on a HUD into a
	mechanic: refinement raises it faster than it raises power, so a veteran's
	real edge is finding nodes first rather than winning fights harder. ]]
local function nodeAt(id: string, tier: string, x: number, z: number): AuraNodes.Node
	return AuraNodes.create(Config, id, tier, { x = x, y = 0, z = z }, "open", 0)
end

do
	local scattered = {
		nodeAt("near", "common", 10, 0),
		nodeAt("far", "common", 300, 0),
		nodeAt("mid", "rare", 100, 0),
	}
	local origin = { x = 0, y = 0, z = 0 }

	local found = AuraNodes.sensed(scattered, origin, 150, 0)
	eq("sense range excludes what is out of range", #found, 2)
	eq("sensed is nearest first", found[1].node.id, "near")
	eq("second is the next nearest", found[2].node.id, "mid")
	near("distance is measured, not bucketed", found[2].distance, 100, 1e-6)

	eq("a blind cultivator senses nothing", #AuraNodes.sensed(scattered, origin, 0, 0), 0)
	eq("everything is in range eventually", #AuraNodes.sensed(scattered, origin, 1000, 0), 3)
	eq(
		"range is a radius, not a box",
		#AuraNodes.sensed({ nodeAt("diag", "common", 100, 100) }, origin, 140, 0),
		0
	)

	-- A drained node is gone whether or not the field has been culled yet.
	local drained = nodeAt("drained", "common", 5, 0)
	drained.drained = true
	eq("expired nodes are never sensed", #AuraNodes.sensed({ drained }, origin, 500, 0), 0)
end

--[[ Telegraph scope. Prime reaching everyone regardless of range is the reason
	there is no safe grind, so it is worth pinning against a config edit. ]]
do
	local common = nodeAt("c", "common", 0, 0)
	local rare = nodeAt("r", "rare", 0, 0)
	local prime = nodeAt("p", "prime", 0, 0)

	eq("common is never announced", AuraNodes.shouldAnnounce(Config, common, 1, 10000), false)
	eq("rare reaches those in range", AuraNodes.shouldAnnounce(Config, rare, 50, 100), true)
	eq("rare stops at the edge of range", AuraNodes.shouldAnnounce(Config, rare, 150, 100), false)
	eq("prime reaches everyone", AuraNodes.shouldAnnounce(Config, prime, 99999, 0), true)
	eq("prime reaches the blind", AuraNodes.shouldAnnounce(Config, prime, 0, 0), true)
end

print(`\n  passed: {passed}   failed: {failed}`)
if failed > 0 then
	for _, f in failures do
		print(`  FAIL  {f}`)
	end
	process.exit(1)
end
print("  all aura node tests passed\n")
