--!strict
--[[ Run with: lune run tests/dice.test

	The die and scales. What this pins:

	- a fair die: every face reachable, none outside 1..sides, and the
	  distribution matches uniform over many rolls
	- a roll pays face x scalesPerPip and nothing else, and never mutates
	  the state it was handed
	- the cooldown rule the server enforces
	- refine spends exactly one batch, turns it into exactly
	  batch x progressPerScale progress, and refuses (state unchanged) when
	  short or at the ceiling
	- scales survive a death and a save round-trip, and a pre-dice save
	  loads with zero
	- the pacing claim in Config: a roll-every-cooldown player refining
	  everything earns roughly bare-ground cultivation, never a node's worth
]]

local process = require("@lune/process")
local Config = require("../src/shared/Config")
local Dice = require("../src/shared/Dice")
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

local LOWGOLD = 5
local SIDES = Config.Dice.sides
local BATCH = Config.Dice.refineBatch

local function lowgold(): Progression.State
	local state = Progression.newState()
	state.stageIndex = LOWGOLD
	return state
end

-- Faces from fixed rng values
eq(
	"rng 0 is face 1",
	Dice.face(Config, function()
		return 0
	end),
	1
)
eq(
	"rng just below 1 is the top face",
	Dice.face(Config, function()
		return 0.999999
	end),
	SIDES
)
eq(
	"rng of exactly 1 is clamped, not sides+1",
	Dice.face(Config, function()
		return 1
	end),
	SIDES
)

-- Uniformity over many rolls
do
	-- Lune has no Roblox Random; Luau's own generator, seeded, is enough.
	math.randomseed(20260925)
	local counts: { number } = table.create(SIDES, 0)
	local outOfRange = 0
	local N = 60000
	for _ = 1, N do
		local face = Dice.face(Config, function()
			return math.random()
		end)
		if face < 1 or face > SIDES or face ~= math.floor(face) then
			outOfRange += 1
		else
			counts[face] += 1
		end
	end
	eq("no face outside 1..sides", outOfRange, 0)
	local expected = N / SIDES
	for face = 1, SIDES do
		check(
			`face {face} is reachable and fair`,
			math.abs(counts[face] - expected) / expected < 0.05,
			`{counts[face]} of an expected {expected}`
		)
	end
end

-- A roll pays out and does not mutate its input
do
	local before = lowgold()
	local after, result = Dice.roll(Config, Progression, before, function()
		return 0.5 -- face 4 on a d6
	end)
	eq("roll reports ok", result.ok, true)
	eq("d6 at 0.5 lands on 4", result.face, 4)
	eq("payout is face x scalesPerPip", result.scales, 4 * Config.Dice.scalesPerPip)
	eq("scales credited", after.scales, result.scales)
	eq("input state untouched", before.scales, 0)
	check("roll returns a new table", after ~= before)
	eq("roll never touches refinement", after.progress, before.progress)
end

-- Rolling works at the ceiling: scales are currency first
do
	local capped = lowgold()
	capped.tier = Config.RefinementTiers
	capped.progress = Config.Stages[LOWGOLD].perTierProgress
	local after, result = Dice.roll(Config, Progression, capped, function()
		return 0
	end)
	eq("roll allowed at ceiling", result.ok, true)
	eq("banked at ceiling", after.scales, Config.Dice.scalesPerPip)
end

-- Cooldown
check("first roll is always ready", Dice.isReady(Config, nil, 0))
check(
	"not ready just inside the cooldown",
	not Dice.isReady(Config, 100, 100 + Config.Dice.cooldownSeconds - 0.01)
)
check("ready at exactly the cooldown", Dice.isReady(Config, 100, 100 + Config.Dice.cooldownSeconds))

-- Refine
do
	local short = lowgold()
	short.scales = BATCH - 1
	local after, result = Dice.refine(Config, Progression, short)
	eq("short purse refuses", result.ok, false)
	eq("short purse reason", result.reason, "insufficient_scales")
	eq("short purse keeps its scales", after.scales, BATCH - 1)
	eq("short purse gains nothing", after.progress, 0)
end

do
	local rich = lowgold()
	rich.scales = BATCH * 2 + 3
	local after, result = Dice.refine(Config, Progression, rich)
	eq("refine ok", result.ok, true)
	eq("spends exactly one batch", after.scales, BATCH + 3)
	eq("reports the batch", result.spent, BATCH)
	near(
		"progress is batch x progressPerScale",
		after.progress,
		BATCH * Config.Dice.progressPerScale,
		1e-9
	)
	eq("input purse untouched", rich.scales, BATCH * 2 + 3)
end

do
	local capped = lowgold()
	capped.tier = Config.RefinementTiers
	capped.progress = Config.Stages[LOWGOLD].perTierProgress
	capped.scales = BATCH * 5
	local after, result = Dice.refine(Config, Progression, capped)
	eq("refine refuses at the ceiling", result.ok, false)
	eq("ceiling reason", result.reason, "ceiling")
	eq("ceiling keeps every scale", after.scales, BATCH * 5)
end

do
	-- A batch that crosses a tier boundary rolls over through addProgress.
	local edge = lowgold()
	local per = Config.Stages[LOWGOLD].perTierProgress
	edge.progress = per - 1
	edge.scales = BATCH
	local after, result = Dice.refine(Config, Progression, edge)
	eq("refine can roll a tier", result.tiersGained, 1)
	eq("tier advanced", after.tier, 2)
end

-- Scales are not refinement: a death does not touch them
do
	local s = lowgold()
	s.scales = 37
	s.progress = 50
	local hurt = Progression.applyLoss(Config, s, 1000)
	eq("death keeps scales", hurt.scales, 37)
end

-- Grant/spend contracts
do
	local s = lowgold()
	local _, ok = Progression.spendScales(s, 1)
	eq("cannot overspend an empty purse", ok, false)
	check("fractional grant is rejected", not pcall(Progression.grantScales, s, 1.5))
	check("negative grant is rejected", not pcall(Progression.grantScales, s, -1))
end

-- Persistence round-trip and old saves
do
	local s = lowgold()
	s.scales = 123
	local restored = Progression.sanitizeState(Config, Progression.toStore(s))
	eq("scales survive a save round-trip", restored.scales, 123)

	local old = Progression.toStore(lowgold())
	old.scales = nil
	eq("a pre-dice save loads with zero scales", Progression.sanitizeState(Config, old).scales, 0)

	for label, bad in { nan = 0 / 0, inf = math.huge, negative = -5, text = "lots" } do
		local raw = Progression.toStore(lowgold())
		raw.scales = bad
		eq(
			`corrupt scales ({label}) fall back to zero`,
			Progression.sanitizeState(Config, raw).scales,
			0
		)
	end
	local raw = Progression.toStore(lowgold())
	raw.scales = 12.7
	eq("fractional stored scales are floored", Progression.sanitizeState(Config, raw).scales, 12)
end

-- Pacing: the die is a trickle that works anywhere, never a node's worth.
-- A RELEASE claim only: development deliberately quarters the cooldown for
-- throughput (see the profile block in Config), and a pacing number taken
-- under it is exactly the kind of figure that profile warns against.
if Config.Profile == "release" then
	local meanFace = (SIDES + 1) / 2
	local scalesPerSecond = meanFace * Config.Dice.scalesPerPip / Config.Dice.cooldownSeconds
	local progressPerSecond = scalesPerSecond * Config.Dice.progressPerScale
	local commonNode = Config.BaseCycleRate * Config.NodeTiers.common.cycleMultiplier
	check(
		"dice cultivation stays below a common node",
		progressPerSecond < commonNode,
		`{progressPerSecond}/s against {commonNode}/s`
	)
	check(
		"release dice cultivation is roughly bare ground",
		progressPerSecond > 0.5 * Config.BaseCycleRate
			and progressPerSecond < 1.5 * Config.BaseCycleRate,
		`{progressPerSecond}/s`
	)
else
	print(`  (pacing checks skipped under the {Config.Profile} profile)`)
end

print(`\n  passed: {passed}   failed: {failed}`)
if failed > 0 then
	for _, line in failures do
		print(`  FAIL {line}`)
	end
	process.exit(1)
end
print("  all dice tests passed")
