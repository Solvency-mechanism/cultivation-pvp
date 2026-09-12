--!strict
local process = require("@lune/process")
local Config = require("../src/shared/Config")
local Progression = require("../src/shared/Progression")
local Volcano = require("../src/shared/Volcano")
local passed, failed = 0, 0
local function check(name: string, condition: boolean)
	if condition then
		passed += 1
	else
		failed += 1
		print("FAIL: " .. name)
	end
end
local function act(state: any, action: string): (any, Volcano.Result)
	return Volcano.act(Config, Progression, state, action)
end

local fresh = Progression.newState()
check(
	"legacy save gets empty expedition",
	Progression.sanitizeState(Config, { stageIndex = 1 }).expedition.solidFire == 0
)
local denied, noMana = act(fresh, "forge")
check("cannot forge absent fire", not noMana.ok and denied.expedition.solidFire == 0)
denied.expedition.discoveries.refuge = true
check("failed action deep clones discovery map", not fresh.expedition.discoveries.refuge)
local fuel = Progression.accrueAura(Config, fresh, "ash", 10000)
local initialFire = fuel.core.raw.ash
local forged, forge = act(fuel, "forge")
check("forge yield", forge.ok and forged.expedition.solidFire == 30)
check(
	"forge spends raw fire atomically",
	forged.core.raw.ash == initialFire - 40 and fuel.core.raw.ash == initialFire
)
check("forge leaves other pool intact", forged.core.raw.verdant == fuel.core.raw.verdant)
local offered, offer = act(forged, "dragon")
check(
	"dragon spends offering",
	offer.ok and offered.expedition.solidFire == 0 and offered.expedition.discoveries.offerPaid
)
local offeredAgain = act(offered, "dragon")
check("offering cannot double spend", offeredAgain.expedition.solidFire == 0)
local locked, lockedResult = act(fresh, "complete_trial")
check("trial requires offering", not lockedResult.ok and not locked.expedition.cinderStep)
local learned, unlocked = act(offered, "complete_trial")
check("trial grants permanent technique", unlocked.ok and learned.expedition.cinderStep)
local _, repeatTrial = act(learned, "complete_trial")
check("trial is one time", not repeatTrial.ok)
learned = Progression.accrueAura(Config, learned, "ash", 10000)
local stepped, step = act(learned, "cinder")
check("cinder spends fire", step.ok and stepped.core.raw.ash == learned.core.raw.ash - 25)
local _, lockedStep = act(fuel, "cinder")
check("fire alone does not unlock cinder", not lockedStep.ok)
local brazier, lit = act(learned, "light_brazier")
check("brazier discovery spends fire", lit.ok and brazier.core.raw.ash == learned.core.raw.ash - 10)
local brazierAgain, litAgain = act(brazier, "light_brazier")
check(
	"brazier cannot repeat spend",
	not litAgain.ok and brazierAgain.core.raw.ash == brazier.core.raw.ash
)
for _, discovery in { "refuge", "fissure" } do
	local found, foundResult = act(brazier, discovery)
	local repeated, repeatResult = act(found, discovery)
	check(
		discovery .. " pays once",
		foundResult.ok
			and not repeatResult.ok
			and found.expedition.solidFire == repeated.expedition.solidFire
	)
	check(discovery .. " does not mutate input", not brazier.expedition.discoveries[discovery])
end
local purified, purification = act(learned, "purify")
check(
	"purify contributes progression",
	purification.ok and purified.progress == learned.progress + 10
)
check("purify spends only batch", purified.core.raw.ash == learned.core.raw.ash - 40)
check("purify preserves expedition", purified.expedition.cinderStep)
local fullOther = Progression.accrueAura(Config, fresh, "verdant", 100000)
local clearOther, cleared = act(fullOther, "purify")
check(
	"nonfire full vessel can purify",
	cleared.ok and clearOther.core.raw.verdant == fullOther.core.raw.verdant - 40
)
local gatheredFire = Progression.accrueAura(Config, clearOther, "ash", 40)
check("purifying unwanted mana allows fire journey", gatheredFire.core.raw.ash == 40)
local mixed = Progression.newState()
mixed.core.raw.neutral = 20
mixed.core.raw.ash = 30
local mixedPurified = act(mixed, "purify")
check(
	"purify follows neutral-first resource policy",
	mixedPurified.core.raw.neutral == 0 and mixedPurified.core.raw.ash == 10
)
local _, noPurification = act(fresh, "purify")
check("insufficient mixed mana cannot purify", not noPurification.ok)
local vented, vent = act(learned, "vent")
check("vent is a paid action", vent.ok and vented.core.raw.ash == learned.core.raw.ash - 20)
local ventLit, ventLitResult = act(vented, "vent_brazier")
check(
	"paid vent lights brazier without second charge",
	ventLitResult.ok
		and ventLit.expedition.discoveries.brazier
		and ventLit.core.raw.ash == vented.core.raw.ash
)
local ventRepeat, ventRepeatResult = act(ventLit, "vent_brazier")
check(
	"vent brazier discovery is idempotent",
	not ventRepeatResult.ok and ventRepeat.core.raw.ash == ventLit.core.raw.ash
)
local _, emptyVent = act(fresh, "vent")
check("empty vent rejected", not emptyVent.ok)
local _, unknown = act(learned, "arbitrary_reward")
check("unknown reward rejected", not unknown.ok)

for _, operation in
	{
		function(s)
			return Progression.applyLoss(Config, s, 10000)
		end,
		function(s)
			return Progression.process(Config, s).state
		end,
		function(s)
			return Progression.discard(s)
		end,
		function(s)
			return Progression.addProgress(Config, s, 1).state
		end,
		function(s)
			return Progression.grantCatalysts(s, 1)
		end,
		function(s)
			return Progression.accrueAura(Config, s, "ash", 1)
		end,
		function(s)
			return (Progression.spendAura(s, 1))
		end,
		function(s)
			return (Progression.spendAura(s, 1000000))
		end,
	}
do
	local output = operation(learned)
	check("operation retains unlock", output.expedition.cinderStep)
	output.expedition.discoveries.test = true
	check("operation isolates expedition", not learned.expedition.discoveries.test)
end
local ceiling = Progression.newState()
ceiling.expedition.cinderStep = true
ceiling.expedition.discoveries.offerPaid = true
ceiling.tier = Config.RefinementTiers
ceiling.progress = Config.Stages[1].perTierProgress
ceiling.core.raw.ash = 40
local noPurify, ceilingResult = act(ceiling, "purify")
check("ceiling does not waste fire", not ceilingResult.ok and noPurify.core.raw.ash == 40)
local advanced = Progression.advanceStage(Config, ceiling)
check(
	"advancement retains unlock",
	advanced.expedition.cinderStep and advanced.expedition.discoveries.offerPaid
)
advanced.expedition.discoveries.test = true
check("advancement deep copies discoveries", not ceiling.expedition.discoveries.test)
local stored = Progression.toStore(learned)
stored.expedition.discoveries.test = true
check("save snapshot does not alias", not learned.expedition.discoveries.test)
check("roundtrip retains unlock", Progression.sanitizeState(Config, stored).expedition.cinderStep)
for _, invalid in { math.huge, -math.huge, 0 / 0, -1 } do
	local clean = Progression.sanitizeState(Config, {
		core = { raw = { ash = invalid }, composition = { ash = invalid } },
		expedition = { solidFire = invalid, discoveries = { refuge = "true", arbitrary = true } },
		catalysts = invalid,
	})
	check(
		"reject invalid stored resource",
		clean.core.raw.ash == 0
			and clean.core.composition.ash == 0
			and clean.expedition.solidFire == 0
			and clean.catalysts == 0
	)
	check(
		"sanitize discoveries",
		not clean.expedition.discoveries.refuge and not clean.expedition.discoveries.arbitrary
	)
end
check("rest phase", not Volcano.phase(0).exhaling)
check("exhale begins", Volcano.phase(28).exhaling)
check("peak breath", math.abs(Volcano.phase(33).intensity - 1) < 1e-6)
check("exhale ends", not Volcano.phase(38).exhaling)
check("cycle repeats", Volcano.phase(81).intensity == Volcano.phase(33).intensity)
print(`Volcano: {passed} passed, {failed} failed`)
if failed > 0 then
	process.exit(1)
end
