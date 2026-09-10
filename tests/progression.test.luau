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

print(`\n  passed: {passed}   failed: {failed}`)
if failed > 0 then
	for _, f in failures do
		print(`  FAIL  {f}`)
	end
	process.exit(1)
end
print("  all progression tests passed\n")
