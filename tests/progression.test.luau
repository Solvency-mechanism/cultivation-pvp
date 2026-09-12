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

-- Built off newState() rather than a hand-written literal, so a future field
-- added to State (core was exactly this trap: a bare literal here would have
-- failed compile.test the moment State grew a fifth field) needs no second
-- fix here.
local function stateAt(
	stageIndex: number,
	tier: number,
	progress: number,
	catalysts: number
): Progression.State
	local state = Progression.newState()
	state.stageIndex = stageIndex
	state.tier = tier
	state.progress = progress
	state.catalysts = catalysts
	return state
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

	--[[ The highest-severity trap named against this whole initiative: a save
		written before core existed has no core key at all, and it must land
		on zeros, never nil -- the closed-set-drift class that has bitten this
		codebase before in other forms. junk/negative/overflow above all had
		no core key either and already proved this implicitly (nothing there
		crashed reading state.core.raw.ash downstream); these make it explicit
		and check every key by name. ]]
	local noCore = Progression.sanitizeState(Config, { stageIndex = LOWGOLD, tier = 1 })
	for _, key in { "ash", "verdant", "lumen", "neutral" } do
		eq(`no core key: vessel {key} lands on zero, not nil`, noCore.core.raw[key], 0)
	end
	for _, key in { "ash", "verdant", "lumen" } do
		eq(`no core key: composition {key} lands on zero, not nil`, noCore.core.composition[key], 0)
	end

	-- Malformed core (wrong shape entirely) sanitizes the same way absent
	-- core does -- type(rawCore.raw) ~= "table" skips it rather than erroring.
	local junkCore =
		Progression.sanitizeState(Config, { stageIndex = LOWGOLD, core = "not a table" })
	eq("junk core falls back to zero", junkCore.core.raw.ash, 0)

	-- A real save's core round-trips exactly, key by key.
	local savedCore = Progression.sanitizeState(Config, {
		stageIndex = LOWGOLD,
		core = {
			raw = { ash = 10, verdant = 20, lumen = 0, neutral = 5 },
			composition = { ash = 100, verdant = 0, lumen = 50 },
		},
	})
	eq("vessel ash round-trips", savedCore.core.raw.ash, 10)
	eq("vessel verdant round-trips", savedCore.core.raw.verdant, 20)
	eq("vessel neutral round-trips", savedCore.core.raw.neutral, 5)
	eq("composition ash round-trips", savedCore.core.composition.ash, 100)
	eq("composition lumen round-trips", savedCore.core.composition.lumen, 50)

	-- A vessel saved above the current capacity (the cap shrank, or the save
	-- was hand-edited) is scaled back down proportionally, so the MIX held
	-- is unchanged and only the total is corrected to fit.
	local capacity = Progression.vesselCapacity(Config, Progression.newState())
	local overfull = Progression.sanitizeState(Config, {
		stageIndex = 1,
		core = {
			raw = { ash = capacity * 2, verdant = capacity * 2, lumen = 0, neutral = 0 },
			composition = { ash = 0, verdant = 0, lumen = 0 },
		},
	})
	local overfullTotal = overfull.core.raw.ash + overfull.core.raw.verdant
	near("an overfull vessel is scaled down to capacity", overfullTotal, capacity, 1e-6)
	near(
		"the scaled-down mix keeps its original proportions",
		overfull.core.raw.ash / overfullTotal,
		0.5,
		1e-9
	)
end

--[[ The deep-clone trap, named as the single most likely silent break in
	this initiative: a shallow copy of core.raw/core.composition would pass
	every test that only checks the returned state was not mutated, since
	CultivationService.tick always reassigns anyway -- right up until a
	SECOND operation on the original state finds its core already changed.
	Identity assertion first (different tables, not the same reference by
	~=), then an explicit mutate-after-the-fact check that would fail
	outright on a by-reference copy, not just a value comparison. ]]
do
	local base = Progression.newState()
	local accrued = Progression.accrueAura(Config, base, "ash", 10)

	check("accrueAura returns a distinct core.raw table", accrued.core.raw ~= base.core.raw)
	check(
		"accrueAura returns a distinct core.composition table",
		accrued.core.composition ~= base.core.composition
	)

	accrued.core.raw.ash = 99999
	eq("mutating the new state's core leaves the original untouched", base.core.raw.ash, 0)

	local processed = Progression.process(Config, accrued)
	check(
		"process also returns a distinct core.raw table",
		processed.state.core.raw ~= accrued.core.raw
	)
end

-- Accrual fills the shared vessel, clamped to capacity -- not per type. The
-- second type only gets whatever headroom the first left behind.
do
	local state = Progression.newState()
	local capacity = Progression.vesselCapacity(Config, state)

	local filled = Progression.accrueAura(Config, state, "ash", capacity - 10)
	filled = Progression.accrueAura(Config, filled, "verdant", 30)
	local total = filled.core.raw.ash
		+ filled.core.raw.verdant
		+ filled.core.raw.lumen
		+ filled.core.raw.neutral
	near("accrual stops at the shared cap, not per type", total, capacity, 1e-9)
	near(
		"the type that arrived first keeps its full share",
		filled.core.raw.ash,
		capacity - 10,
		1e-9
	)
	near("the second type only gets the remaining headroom", filled.core.raw.verdant, 10, 1e-9)
end

-- Processing consumes the WHOLE vessel: typed amounts become permanent
-- composition (neutral does not), and the total -- including neutral --
-- pushes progress.
do
	local state = Progression.newState()
	state = Progression.accrueAura(Config, state, "ash", 40)
	state = Progression.accrueAura(Config, state, "neutral", 10)

	local result = Progression.process(Config, state)
	eq("processing reports the full vessel processed", result.processed, 50)
	eq("processing empties the vessel entirely", result.state.core.raw.ash, 0)
	eq("processing empties neutral too", result.state.core.raw.neutral, 0)
	eq("typed aura becomes permanent composition", result.state.core.composition.ash, 40)
	eq("neutral adds nothing to composition", result.state.core.composition.neutral, nil)
	near(
		"the total, including neutral, pushed progress",
		result.state.progress,
		50 * Config.Core.processYield,
		1e-6
	)
end

-- Discard empties the vessel for nothing -- no composition change, no progress.
do
	local state = Progression.newState()
	state = Progression.accrueAura(Config, state, "lumen", 25)
	local discarded = Progression.discard(state)
	eq("discard empties the vessel", discarded.core.raw.lumen, 0)
	eq("discard grants no composition", discarded.core.composition.lumen, 0)
	eq("discard grants no progress", discarded.progress, 0)
end

-- Spending draws neutral first, then proportionally across what remains --
-- combat does not eat the identity a player has gathered while there is
-- flavourless aura still sitting in the pool to spend instead.
do
	local state = Progression.newState()
	state = Progression.accrueAura(Config, state, "neutral", 5)
	state = Progression.accrueAura(Config, state, "ash", 10)
	state = Progression.accrueAura(Config, state, "verdant", 10)

	local afterSmallSpend, okSmall = Progression.spendAura(state, 3)
	check("a spend within neutral succeeds", okSmall)
	eq("neutral is drawn down first", afterSmallSpend.core.raw.neutral, 2)
	eq("typed aura is untouched while neutral covers the cost", afterSmallSpend.core.raw.ash, 10)

	local afterBigSpend, okBig = Progression.spendAura(state, 15)
	check("a spend past neutral succeeds if the total covers it", okBig)
	eq("neutral is exhausted first", afterBigSpend.core.raw.neutral, 0)
	near("the remainder is drawn proportionally from ash", afterBigSpend.core.raw.ash, 5, 1e-9)
	near(
		"the remainder is drawn proportionally from verdant",
		afterBigSpend.core.raw.verdant,
		5,
		1e-9
	)

	local unchanged, okRefused = Progression.spendAura(state, 9999)
	check("a spend beyond the whole vessel is refused", not okRefused)
	eq("a refused spend changes nothing", unchanged.core.raw.neutral, state.core.raw.neutral)
end

print(`\n  passed: {passed}   failed: {failed}`)
if failed > 0 then
	for _, f in failures do
		print(`  FAIL  {f}`)
	end
	process.exit(1)
end
print("  all progression tests passed\n")
