--!strict
--[[ Run with: lune run tests/progression.test ]]

local process = require("@lune/process")
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

local function near(name: string, actual: number, expected: number, tol: number?)
	local t = tol or 1e-6
	check(name, math.abs(actual - expected) <= t, `expected ~{expected}, got {actual}`)
end

local LOWGOLD = 5
local TRUEGOLD = #Config.Stages

local function stateAt(
	stageIndex: number,
	tier: number,
	progress: number,
	catalysts: number
): Progression.State
	return { stageIndex = stageIndex, tier = tier, progress = progress, catalysts = catalysts }
end

-- Baseline
local s0 = Progression.newState()
eq("newState starts at Foundation", s0.stageIndex, 1)
eq("newState starts at tier 1", s0.tier, 1)
eq("Foundation is blind", Progression.senseRange(Config, s0), 0)

-- Tier rollover
local foundationPer = Config.Stages[1].perTierProgress
local r1 = Progression.addProgress(Config, s0, foundationPer)
eq("one tier gained", r1.tiersGained, 1)
eq("tier is 2", r1.state.tier, 2)
eq("progress reset", r1.state.progress, 0)

local r2 = Progression.addProgress(Config, s0, foundationPer * 3.5)
eq("three tiers in one call", r2.tiersGained, 3)
near("remainder carried", r2.state.progress, foundationPer * 0.5)

-- Ceiling behaviour
local huge = Progression.addProgress(Config, s0, foundationPer * 10000)
eq("clamped to max tier", huge.state.tier, Config.RefinementTiers)
eq("bar sits full at ceiling", huge.state.progress, foundationPer)
check("reports ceiling", huge.atCeiling)

-- Catalyst gate: proving ground vs gold
check("proving ground advances without catalyst", Progression.canAdvanceStage(Config, huge.state))

local lowgoldPer = Config.Stages[LOWGOLD].perTierProgress
local goldCeiling = stateAt(LOWGOLD, Config.RefinementTiers, lowgoldPer, 0)
check("gold stage blocked without catalyst", not Progression.canAdvanceStage(Config, goldCeiling))

local withCatalyst = Progression.grantCatalysts(goldCeiling, 1)
check("gold stage unblocked by catalyst", Progression.canAdvanceStage(Config, withCatalyst))

local advanced = Progression.advanceStage(Config, withCatalyst)
eq("stage incremented", advanced.stageIndex, LOWGOLD + 1)
eq("tier reset on advance", advanced.tier, 1)
eq("progress reset on advance", advanced.progress, 0)
eq("catalyst consumed", advanced.catalysts, 0)

-- Not at ceiling means no advancement even holding a catalyst
local midStage = stateAt(LOWGOLD, 4, 100, 5)
check("mid-stage cannot advance", not Progression.canAdvanceStage(Config, midStage))

-- The ratchet
local loseBig = Progression.applyLoss(Config, stateAt(LOWGOLD, 1, 0, 0), lowgoldPer * 99)
eq("loss never demotes stage", loseBig.stageIndex, LOWGOLD)
eq("loss floors at tier 1", loseBig.tier, 1)
eq("loss floors at zero progress", loseBig.progress, 0)

local loseSome = Progression.applyLoss(Config, stateAt(LOWGOLD, 5, 0, 0), lowgoldPer * 2)
eq("loss drops two tiers", loseSome.tier, 3)

-- Power spread stays inside the bracket budget
local fresh = stateAt(LOWGOLD, 1, 0, 0)
local maxed = stateAt(LOWGOLD, Config.RefinementTiers, lowgoldPer, 0)
local spread = Progression.effectivePower(Config, maxed) / Progression.effectivePower(Config, fresh)
near("intra-stage spread is 18%", spread, 1.18, 1e-9)
check("spread within 20% budget", spread <= 1.20, `spread was {spread}`)

-- Sense range scales faster than power
local senseSpread = Progression.senseRange(Config, maxed) / Progression.senseRange(Config, fresh)
check("sense outpaces power", senseSpread > spread, `sense {senseSpread} vs power {spread}`)

-- Brackets
check("same stage shares a bracket", Progression.sameBracket(fresh, maxed))
check("different stages do not", not Progression.sameBracket(fresh, stateAt(LOWGOLD + 1, 1, 0, 0)))

-- Cap
local capped = stateAt(TRUEGOLD, Config.RefinementTiers, Config.Stages[TRUEGOLD].perTierProgress, 9)
check("Truegold is max stage", Progression.isMaxStage(Config, capped))
check("cannot advance past cap", not Progression.canAdvanceStage(Config, capped))

-- Immutability
local before = Progression.newState()
Progression.addProgress(Config, before, 99999)
Progression.applyLoss(Config, before, 99999)
eq("input state untouched by addProgress/applyLoss", before.tier, 1)

--[[ Sense range is the one axis where refinement is allowed to compound, so
	the veteran advantage in *finding* must outrun the 18% advantage in
	fighting. If these ever cross, the pressure valve has closed. ]]
do
	local freshPower = Progression.effectivePower(Config, stateAt(LOWGOLD, 1, 0, 0))
	local maxedPower =
		Progression.effectivePower(Config, stateAt(LOWGOLD, Config.RefinementTiers, 0, 0))
	local freshSense = Progression.senseRange(Config, stateAt(LOWGOLD, 1, 0, 0))
	local maxedSense =
		Progression.senseRange(Config, stateAt(LOWGOLD, Config.RefinementTiers, 0, 0))

	check("sense range grows with refinement", maxedSense > freshSense)
	check("finding outpaces fighting", (maxedSense / freshSense) > (maxedPower / freshPower))
end

--[[ Sanitizing stored state.

	Saves outlive the config that wrote them, and refusing to load is worse than
	losing a tier, so every branch has to land on a state the rest of this module
	will accept without asserting. ]]
do
	local blank = Progression.newState()

	for _, junk in { 5, "state", true } do
		local state = Progression.sanitizeState(Config, junk)
		eq("junk becomes a fresh stage", state.stageIndex, blank.stageIndex)
		eq("junk becomes a fresh tier", state.tier, blank.tier)
	end
	eq(
		"nil becomes a fresh state",
		Progression.sanitizeState(Config, nil).stageIndex,
		blank.stageIndex
	)

	local overflow = Progression.sanitizeState(
		Config,
		{ stageIndex = 999, tier = 999, progress = 1e12, catalysts = 5 }
	)
	eq("stage index is clamped to the ladder", overflow.stageIndex, TRUEGOLD)
	eq("tier is clamped to the cap", overflow.tier, Config.RefinementTiers)
	check(
		"progress cannot exceed a tier",
		overflow.progress <= Config.Stages[TRUEGOLD].perTierProgress
	)
	eq("valid catalysts survive", overflow.catalysts, 5)

	local negative = Progression.sanitizeState(
		Config,
		{ stageIndex = -3, tier = 0, progress = -50, catalysts = -9 }
	)
	eq("stage index floors at one", negative.stageIndex, 1)
	eq("tier floors at one", negative.tier, 1)
	eq("negative progress becomes zero", negative.progress, 0)
	eq("negative catalysts become zero", negative.catalysts, 0)

	local nan = Progression.sanitizeState(Config, { stageIndex = 0 / 0, progress = 0 / 0 })
	eq("NaN stage index falls back", nan.stageIndex, blank.stageIndex)
	eq("NaN progress falls back", nan.progress, 0)

	-- Stores hand back floats. A fractional stage index would index nothing.
	local fractional = Progression.sanitizeState(Config, { stageIndex = 4.7, tier = 3.2 })
	eq("fractional stage index floors", fractional.stageIndex, 4)
	eq("fractional tier floors", fractional.tier, 3)

	-- The real point: a sanitized state survives the functions that assert.
	local restored = Progression.sanitizeState(
		Config,
		{ stageIndex = LOWGOLD, tier = 4, progress = 120, catalysts = 1 }
	)
	eq("a real save round-trips its stage", restored.stageIndex, LOWGOLD)
	eq("a real save round-trips its tier", restored.tier, 4)
	eq("a real save round-trips its progress", restored.progress, 120)
	check("power is computable from it", Progression.effectivePower(Config, restored) > 0)
	check(
		"progress is addable to it",
		Progression.addProgress(Config, restored, 10).state.progress > 120
	)
	check("loss is applicable to it", Progression.applyLoss(Config, restored, 50).progress >= 0)
end

print(`\n  passed: {passed}   failed: {failed}`)
if failed > 0 then
	for _, f in failures do
		print(`  FAIL  {f}`)
	end
	process.exit(1)
end
print("  all progression tests passed\n")
