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

--[[ Weighted region roll -- placement *intent*, not placement truth.

	Expectations are derived from Config for the same reason rollTier's are: what
	is under test is that the roll reads its configured weights faithfully, not
	that any particular distribution is correct. The realised distribution is a
	different thing entirely and cannot be asserted here, because it depends on
	`ArenaService.regionAt` resolving a scattered point against the real blob
	table -- a scatter that lands past a lobe edge is honestly `open`. This suite
	is pure and has no map. ]]
local regionTotal = 0
for _, entry in Config.Field.regionWeights do
	regionTotal += entry.weight
end

local regionBands: { { region: string, lo: number, hi: number } } = {}
local regionCursor = 0
for _, entry in Config.Field.regionWeights do
	local lo = regionCursor / regionTotal
	regionCursor += entry.weight
	table.insert(regionBands, { region = entry.region, lo = lo, hi = regionCursor / regionTotal })
end

eq(
	"low roll picks the first weighted region",
	AuraNodes.rollRegion(Config, scripted({ 0.0 })),
	regionBands[1].region
)
eq(
	"top of region range stays valid",
	AuraNodes.rollRegion(Config, scripted({ 0.999999 })),
	regionBands[#regionBands].region
)

for _, band in regionBands do
	eq(
		`mid-band roll picks {band.region}`,
		AuraNodes.rollRegion(Config, scripted({ (band.lo + band.hi) / 2 })),
		band.region
	)
	eq(
		`just inside {band.region}'s lower edge`,
		AuraNodes.rollRegion(Config, scripted({ band.lo + 1e-6 })),
		band.region
	)
	eq(
		`just inside {band.region}'s upper edge`,
		AuraNodes.rollRegion(Config, scripted({ band.hi - 1e-6 })),
		band.region
	)
end

local regionCounts: { [string]: number } = {}
for _, entry in Config.Field.regionWeights do
	regionCounts[entry.region] = 0
end
local regionRng = lcg(20260911)
local regionN = 20000
for _ = 1, regionN do
	regionCounts[AuraNodes.rollRegion(Config, regionRng)] += 1
end
for _, entry in Config.Field.regionWeights do
	near(
		`{entry.region} tracks its configured weight`,
		regionCounts[entry.region] / regionN,
		entry.weight / regionTotal,
		0.02
	)
end

--[[ Every region the roll can emit must be priceable and speakable. A weight
	naming a region with no multiplier would silently cycle at 1.0x, and one with
	no display name would put a raw key in the most prominent text on screen. ]]
for _, entry in Config.Field.regionWeights do
	check(
		`{entry.region} has a cycle multiplier`,
		Config.StaticRegionMultipliers[entry.region] ~= nil
	)
	check(`{entry.region} has a display name`, Config.RegionNames[entry.region] ~= nil)
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

--[[ The prime drain fight. `drainReserve` is not priced in Config yet (roster
	prices it against this formula), so these build Node literals directly
	rather than going through AuraNodes.create -- unit-testing drain() itself,
	not the creation pipeline, and not blocked on a number that is not there
	yet. A separate small test below confirms create() wires reserve from
	tierData once a config actually carries drainReserve, using a minimal
	stand-in rather than the real Config.NodeTiers. ]]
do
	local function drainNode(reserve: number, region: string, tier: string): AuraNodes.Node
		return {
			id = "drain-test",
			tier = tier,
			position = ORIGIN,
			region = region,
			spawnedAt = 0,
			expiresAt = 99999,
			occupants = {},
			occupantCount = 0,
			drained = false,
			reserve = reserve,
			drainedBy = {},
		}
	end

	-- Solo common on open ground: rate is BaseCycleRate * commonMultiplier(3) *
	-- openMultiplier(1.0) = 3/s. 10s of dt at one occupant should remove 30.
	local solo = drainNode(100, "open", "common")
	AuraNodes.addOccupant(Config, solo, "u1", 0)
	AuraNodes.drain(Config, solo, 10)
	near("solo drain removes rate * dt", solo.reserve, 70, 1e-9)
	near("solo occupant credited their own contribution", solo.drainedBy.u1, 30, 1e-9)
	check("not drained until reserve reaches zero", not solo.drained)

	-- Two occupants drain twice as fast (at whatever the per-occupant rate
	-- is), and each is credited their OWN share, not half of the total --
	-- crediting contribution, not splitting a pot. Two DISTINCT occupants
	-- are also contested under today's no-faction fallback (see the
	-- contested block further down), so the expected numbers already carry
	-- that factor -- this block is about occupant-count scaling and
	-- per-occupant crediting, not about isolating an uncontested case that
	-- cannot exist without a real faction system.
	local duoRate = AuraNodes.cycleRate(Config, nil, "open", true)
		* 3 -- common's cycleMultiplier, matching `node` below
		* Config.Field.contestedDrainFactor
	local duo = drainNode(100, "open", "common")
	AuraNodes.addOccupant(Config, duo, "a", 0)
	AuraNodes.addOccupant(Config, duo, "b", 0)
	AuraNodes.drain(Config, duo, 5)
	near(
		"two occupants drain at double the per-occupant rate",
		100 - duo.reserve,
		duoRate * 2 * 5,
		1e-9
	)
	near(
		"first occupant credited their own rate, not half the total",
		duo.drainedBy.a,
		duoRate * 5,
		1e-9
	)
	near("second occupant credited identically", duo.drainedBy.b, duoRate * 5, 1e-9)

	-- Repeated calls accumulate in drainedBy rather than overwrite -- the
	-- ledger is contribution OVER TIME, not a snapshot at any one instant.
	AuraNodes.drain(Config, duo, 5)
	near(
		"a second drain call adds to the ledger rather than replacing it",
		duo.drainedBy.a,
		duoRate * 10,
		1e-9
	)

	-- Reaching zero sets drained -- the first and only place this flag is
	-- ever set -- and never goes negative.
	local nearlyDone = drainNode(9, "open", "common")
	AuraNodes.addOccupant(Config, nearlyDone, "u1", 0)
	AuraNodes.drain(Config, nearlyDone, 10)
	eq("reserve floors at zero, never negative", nearlyDone.reserve, 0)
	check("drained flips true when reserve is exhausted", nearlyDone.drained)

	-- An unoccupied node never drains -- the compatibility guarantee. It
	-- still only ages out via expiresAt, exactly as before this existed.
	local unoccupied = drainNode(100, "open", "common")
	AuraNodes.drain(Config, unoccupied, 999)
	eq("no occupants, no drain", unoccupied.reserve, 100)
	eq("no occupants, no ledger entries", next(unoccupied.drainedBy), nil)

	-- A drained node is inert -- draining it further is a no-op, not a
	-- negative reserve or a re-credited ledger.
	local finished = drainNode(0, "open", "common")
	finished.drained = true
	AuraNodes.addOccupant(Config, finished, "u1", 0)
	AuraNodes.drain(Config, finished, 10)
	eq("a drained node does not drain further", finished.reserve, 0)
	eq("a drained node does not keep crediting", next(finished.drainedBy), nil)

	-- Priced in the same unit accrual already uses: draining a wellspring
	-- prime is exactly AuraNodes.cycleRate for that node, not a second rate.
	local prime = drainNode(1000, "wellspring", "prime")
	AuraNodes.addOccupant(Config, prime, "u1", 0)
	AuraNodes.drain(Config, prime, 1)
	near(
		"drain rate equals cycleRate for the node's own tier and region",
		1000 - prime.reserve,
		AuraNodes.cycleRate(Config, prime, "wellspring", true),
		1e-9
	)

	--[[ Contested nodes drain slower -- the human's own stretch ruling.
		AuraNodes.isContested has no real faction system to read yet, so it
		falls back to one faction per userId (contestedBy's own factionOf(id)
		or id), which makes any two DISTINCT occupants contested today. Solo
		drain above already established the uncontested rate at Config.
		BaseCycleRate * common's cycleMultiplier(3) * open's multiplier(1.0)
		= 3/s; contestedDrainFactor halves that to 1.5/s -- per occupant, not
		as a flat penalty on the total, so each occupant's own credited share
		is reduced identically to the reserve's own depletion. ]]
	local contested = drainNode(1000, "open", "common")
	AuraNodes.addOccupant(Config, contested, "a", 0)
	AuraNodes.addOccupant(Config, contested, "b", 0)
	AuraNodes.drain(Config, contested, 10)
	local expectedContestedRate = AuraNodes.cycleRate(Config, contested, "open", true)
		* Config.Field.contestedDrainFactor
	near(
		"contested reserve loss is the halved rate times both occupants",
		1000 - contested.reserve,
		expectedContestedRate * 2 * 10,
		1e-9
	)
	near(
		"each contested occupant is credited the reduced rate, not the solo one",
		contested.drainedBy.a,
		expectedContestedRate * 10,
		1e-9
	)
	check(
		"contested per-occupant credit is strictly less than the earlier solo rate",
		contested.drainedBy.a < solo.drainedBy.u1
	)
end

-- create() seeds reserve from the tier's drainReserve, once a config has one
-- -- a minimal stand-in, not the real Config.NodeTiers, so this is not
-- blocked on roster's pricing.
do
	local stub = {
		NodeTiers = {
			test = {
				id = "test",
				cycleMultiplier = 1,
				capacity = 3,
				lifetime = 100,
				catalystChance = 0,
				telegraph = "local",
				drainReserve = 42,
			},
		},
	}
	local seeded = AuraNodes.create(stub, "n-seed", "test", ORIGIN, "open", 0)
	eq("create seeds reserve from the tier's drainReserve", seeded.reserve, 42)
	eq("create seeds an empty ledger", next(seeded.drainedBy), nil)
	check("create leaves drained false", not seeded.drained)
end

do
	local rewardNode = AuraNodes.create(Config, "reward", "prime", ORIGIN, "barren", 0)
	AuraNodes.addOccupant(Config, rewardNode, "holder", 0)
	rewardNode.drainedBy.holder = Config.NodeTiers.prime.drainReserve * 0.5
	check(
		"expiry alone cannot grant a catalyst",
		not AuraNodes.canClaimDrain(Config, rewardNode, "holder")
	)
	rewardNode.drained = true
	check(
		"present contributor can claim drain",
		AuraNodes.canClaimDrain(Config, rewardNode, "holder")
	)
	AuraNodes.removeOccupant(rewardNode, "holder")
	check(
		"past contributor cannot tap and leave",
		not AuraNodes.canClaimDrain(Config, rewardNode, "holder")
	)
	rewardNode.occupants.late = true
	rewardNode.drainedBy.late = 1
	check(
		"last-second arrival cannot claim",
		not AuraNodes.canClaimDrain(Config, rewardNode, "late")
	)
end

print(`\n  passed: {passed}   failed: {failed}`)
if failed > 0 then
	for _, f in failures do
		print(`  FAIL  {f}`)
	end
	process.exit(1)
end
print("  all aura node tests passed\n")
