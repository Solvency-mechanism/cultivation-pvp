--!strict
--[[
	Stage and refinement rules.

	Pure functions over an immutable state table. Config is injected rather than
	required so this module loads unchanged in Roblox and in Lune tests.

	The loop this encodes:
		cycling fills refinement -> refinement caps at the stage ceiling ->
		breaking the ceiling needs a catalyst -> catalysts drop from Prime nodes.

	Which is how "PvP is mandatory" becomes an economic fact rather than a rule.
]]

--[[ The vessel: raw, typed, unprocessed aura -- what abilities spend from,
	what a discard empties, what processing consumes whole. Shared capacity
	across all four keys, not four independent pools -- see vesselCapacity
	and the design note at core-and-map.md (b) for why shared is the whole
	point (an independent-per-type cap would never force a discard). ]]
export type AuraPool = {
	ash: number,
	verdant: number,
	lumen: number,
	neutral: number,
}

--[[ The core: what has been PROCESSED, ever. Permanent identity, no cap, no
	neutral key -- neutral is spendable and processable but flavourless, so
	it pushes baseline cultivation on processing without becoming part of
	what you have "become" (core-and-map.md (b), rulings). Never touched by
	applyLoss: identity is not combat performance. ]]
export type CoreComposition = {
	ash: number,
	verdant: number,
	lumen: number,
}

export type Core = {
	raw: AuraPool,
	composition: CoreComposition,
}

export type Expedition = {
	solidFire: number,
	discoveries: { [string]: boolean },
	cinderStep: boolean,
	dragonMet: boolean,
}

export type State = {
	stageIndex: number,
	tier: number,
	progress: number,
	catalysts: number,
	scales: number,
	core: Core,
	expedition: Expedition,
}

export type AddResult = {
	state: State,
	tiersGained: number,
	atCeiling: boolean,
}

export type ProcessResult = {
	state: State,
	tiersGained: number,
	atCeiling: boolean,
	processed: number,
}

local Progression = {}

--[[ Deep. This is the one place the whole Core initiative names as its own
	worst silent trap (core-and-map.md risk 2, design.md risk 2): a
	by-reference copy of core.raw/core.composition would pass every existing
	test that only checks the top-level state was not mutated, because
	CultivationService.tick reassigns the returned state anyway -- right up
	until applyLoss or a second accrual mutates what the FIRST state's core
	still points at. Test coverage for this lives in progression.test as an
	explicit identity assertion plus a mutate-after-clone check, not just a
	value comparison. ]]
local function cloneCore(core: Core): Core
	return {
		raw = {
			ash = core.raw.ash,
			verdant = core.raw.verdant,
			lumen = core.raw.lumen,
			neutral = core.raw.neutral,
		},
		composition = {
			ash = core.composition.ash,
			verdant = core.composition.verdant,
			lumen = core.composition.lumen,
		},
	}
end

local function cloneExpedition(expedition: Expedition): Expedition
	return {
		solidFire = expedition.solidFire,
		discoveries = table.clone(expedition.discoveries),
		cinderStep = expedition.cinderStep,
		dragonMet = expedition.dragonMet,
	}
end

local function clone(state: State): State
	return {
		stageIndex = state.stageIndex,
		tier = state.tier,
		progress = state.progress,
		catalysts = state.catalysts,
		scales = state.scales,
		core = cloneCore(state.core),
		expedition = cloneExpedition(state.expedition),
	}
end

local function emptyCore(): Core
	return {
		raw = { ash = 0, verdant = 0, lumen = 0, neutral = 0 },
		composition = { ash = 0, verdant = 0, lumen = 0 },
	}
end

local function emptyExpedition(): Expedition
	return { solidFire = 0, discoveries = {}, cinderStep = false, dragonMet = false }
end

function Progression.newState(): State
	return {
		stageIndex = 1,
		tier = 1,
		progress = 0,
		catalysts = 0,
		scales = 0,
		core = emptyCore(),
		expedition = emptyExpedition(),
	}
end

--[[ Rebuild a state table from untrusted stored data.

	Saved data outlives the config that wrote it. A stage removed from the
	ladder, a lowered refinement cap, a partial write, or a number that came back
	as NaN would otherwise put a player into a state the rest of this module
	asserts against. Anything unreadable falls back to a fresh value rather than
	failing the load, because refusing to load is worse than losing a tier. ]]
function Progression.sanitizeState(config: any, raw: any): State
	local state = Progression.newState()
	if type(raw) ~= "table" then
		return state
	end

	local stageIndex = tonumber(raw.stageIndex)
	if stageIndex and stageIndex == stageIndex and math.abs(stageIndex) < math.huge then
		state.stageIndex = math.clamp(math.floor(stageIndex), 1, #config.Stages)
	end

	local tier = tonumber(raw.tier)
	if tier and tier == tier and math.abs(tier) < math.huge then
		state.tier = math.clamp(math.floor(tier), 1, config.RefinementTiers)
	end

	local stage = config.Stages[state.stageIndex]
	local progress = tonumber(raw.progress)
	if progress and progress == progress and progress < math.huge and progress > 0 then
		state.progress = math.min(progress, stage.perTierProgress)
	end

	local catalysts = tonumber(raw.catalysts)
	if catalysts and catalysts == catalysts and catalysts < math.huge and catalysts > 0 then
		state.catalysts = math.floor(catalysts)
	end

	-- Scales are whole units of forged mana. A save written before the die
	-- existed has no key at all and lands on the zero newState() gave it.
	local scales = tonumber(raw.scales)
	if scales and scales == scales and scales < math.huge and scales > 0 then
		state.scales = math.floor(scales)
	end

	--[[ Absorbed key by key into the zeros newState() already gave state.core,
		never left nil -- a save with no core key at all (every save written
		before this landed) must round-trip to a state this module can act on
		without a special case anywhere else. ]]
	local rawCore = raw.core
	if type(rawCore) == "table" then
		if type(rawCore.raw) == "table" then
			for _, key in { "ash", "verdant", "lumen", "neutral" } do
				local value = tonumber(rawCore.raw[key])
				if value and value == value and value < math.huge and value >= 0 then
					state.core.raw[key] = value
				end
			end
		end
		if type(rawCore.composition) == "table" then
			for _, key in { "ash", "verdant", "lumen" } do
				local value = tonumber(rawCore.composition[key])
				if value and value == value and value < math.huge and value >= 0 then
					state.core.composition[key] = value
				end
			end
		end
	end

	local expedition = raw.expedition
	if type(expedition) == "table" then
		local solidFire = tonumber(expedition.solidFire)
		if solidFire and solidFire == solidFire and solidFire >= 0 and solidFire < math.huge then
			state.expedition.solidFire = solidFire
		end
		state.expedition.cinderStep = expedition.cinderStep == true
		state.expedition.dragonMet = expedition.dragonMet == true
		if type(expedition.discoveries) == "table" then
			for _, key in { "brazier", "refuge", "fissure", "offerPaid", "trial" } do
				if expedition.discoveries[key] == true then
					state.expedition.discoveries[key] = true
				end
			end
		end
	end

	-- A vessel above capacity (a hand-edited save, a capacity that shrank)
	-- is scaled back down proportionally rather than clamped per-key, so the
	-- MIX held is unchanged and only the total is corrected.
	local capacity = Progression.vesselCapacity(config, state)
	local total = state.core.raw.ash
		+ state.core.raw.verdant
		+ state.core.raw.lumen
		+ state.core.raw.neutral
	if total > capacity and total > 0 then
		local scale = capacity / total
		state.core.raw.ash *= scale
		state.core.raw.verdant *= scale
		state.core.raw.lumen *= scale
		state.core.raw.neutral *= scale
	end

	return state
end

--[[ The highest-severity item named against this whole initiative:
	PersistenceService.save used to build its own literal by hand, and it
	silently dropped any field this module grew that the literal did not
	already know about -- no error, no test, no symptom, a player
	cultivates a permanent identity for hours and it never saves. The fix
	is structural, not a reminder: this is now the ONLY place a state is
	serialised for storage, so PersistenceService has nothing left to
	drift, having nothing left to enumerate itself. Kept deliberately flat
	(no branches) so the closed-set source test in tests/wiring.test.luau
	can find every field by a plain substring search across this whole
	function body -- the same reason clone() above is flat too. ]]
function Progression.toStore(state: State): { [string]: any }
	return {
		stageIndex = state.stageIndex,
		tier = state.tier,
		progress = state.progress,
		catalysts = state.catalysts,
		scales = state.scales,
		expedition = cloneExpedition(state.expedition),
		core = {
			raw = {
				ash = state.core.raw.ash,
				verdant = state.core.raw.verdant,
				lumen = state.core.raw.lumen,
				neutral = state.core.raw.neutral,
			},
			composition = {
				ash = state.core.composition.ash,
				verdant = state.core.composition.verdant,
				lumen = state.core.composition.lumen,
			},
		},
	}
end

function Progression.getStage(config: any, state: State)
	local stage = config.Stages[state.stageIndex]
	assert(stage ~= nil, `invalid stageIndex {state.stageIndex}`)
	return stage
end

function Progression.isMaxStage(config: any, state: State): boolean
	return state.stageIndex >= #config.Stages
end

--[[ Effective combat power. Intra-stage spread is deliberately narrow. ]]
function Progression.effectivePower(config: any, state: State): number
	local stage = Progression.getStage(config, state)
	return stage.basePower * (1 + (state.tier - 1) * config.RefinementPowerStep)
end

--[[ Aura sensing radius. Foundation is blind by design -- gaining sight at
	Copper is the moment the world fills with content. ]]
function Progression.senseRange(config: any, state: State): number
	local stage = Progression.getStage(config, state)
	return stage.senseRange * (1 + (state.tier - 1) * config.RefinementSenseStep)
end

function Progression.isAtCeiling(config: any, state: State): boolean
	local stage = Progression.getStage(config, state)
	return state.tier >= config.RefinementTiers and state.progress >= stage.perTierProgress
end

--[[ Add refinement progress, rolling over as many tiers as the amount covers.
	At the ceiling the bar simply sits full, waiting on a catalyst. ]]
function Progression.addProgress(config: any, state: State, amount: number): AddResult
	assert(amount >= 0, "progress amount must be non-negative")
	local stage = Progression.getStage(config, state)
	local new = clone(state)
	local gained = 0

	new.progress += amount
	while new.tier < config.RefinementTiers and new.progress >= stage.perTierProgress do
		new.progress -= stage.perTierProgress
		new.tier += 1
		gained += 1
	end

	if new.tier >= config.RefinementTiers then
		new.progress = math.min(new.progress, stage.perTierProgress)
	end

	return { state = new, tiersGained = gained, atCeiling = Progression.isAtCeiling(config, new) }
end

--[[ Derived, never stored: capacityMultiplier x the same basePower x
	auraMultiplier product Combat.auraCapacity computes, read independently
	off the injected config rather than by requiring Combat -- src/shared
	takes no internal requires, and this is the same Config fields Combat.
	luau itself reads, not a second formula that could drift from the
	first. Sized by time-to-fill, not by the ability pool (core-and-map.md
	(b)): capacityMultiplier is deliberately larger than auraMultiplier
	alone so a full vessel is a fight-length decision, not a four-second
	one. ]]
function Progression.vesselCapacity(config: any, state: State): number
	local stage = Progression.getStage(config, state)
	return stage.basePower * config.Combat.auraMultiplier * config.Core.capacityMultiplier
end

--[[ The one place Config.RegionAura is ever read, per its own header
	comment in Config.luau ("Read by exactly one pure function once the Core
	lands"). A region absent from the table -- new ground the map team has
	not priced yet -- accrues nothing, not an error: the same silent-absorb
	behaviour the compile-test already allows for RegionNames without a
	matching RegionAura line. ]]
function Progression.auraTypeForRegion(
	config: any,
	region: string
): ("ash" | "verdant" | "lumen" | "neutral")?
	return config.RegionAura[region]
end

--[[ The vessel's current fill, summed across all four typed keys -- what
	Combat mirrors into actor.aura (A5) and what spendAura/accrueAura already
	compute inline themselves. Pulled out because A5 adds two more call sites
	that need the exact same sum. ]]
function Progression.vesselTotal(state: State): number
	local raw = state.core.raw
	return raw.ash + raw.verdant + raw.lumen + raw.neutral
end

--[[ Fill the vessel with one typed aura, clamped to whatever headroom is
	left under the SHARED cap -- not clamped per-type, because a shared cap
	is the entire design: an independent-per-type cap would never force a
	discard, since a player would simply stop cultivating the type they did
	not want rather than ever having to choose. Standing in the Barrens on
	the way to the Wellspring fills the vessel with ash whether or not that
	was wanted, which is the point. ]]
function Progression.accrueAura(
	config: any,
	state: State,
	auraType: "ash" | "verdant" | "lumen" | "neutral",
	amount: number
): State
	assert(amount >= 0, "accrual amount must be non-negative")
	local new = clone(state)
	local capacity = Progression.vesselCapacity(config, new)
	local total = new.core.raw.ash
		+ new.core.raw.verdant
		+ new.core.raw.lumen
		+ new.core.raw.neutral
	local headroom = math.max(0, capacity - total)
	new.core.raw[auraType] += math.min(amount, headroom)
	return new
end

--[[ Consume the ENTIRE vessel -- there is no partial processing, which is
	what makes "when do I process" the decision rather than "how much".
	Typed raw amounts add to the permanent composition; neutral adds
	nothing there, but its share of the total still counts toward the
	progress this grants -- neutral is spendable and processable, just
	flavourless. Routes through addProgress rather than writing state.
	progress directly, so the tier-rollover rule lives in exactly one
	place regardless of which verb is feeding it. ]]
function Progression.process(config: any, state: State): ProcessResult
	local emptied = clone(state)
	local raw = emptied.core.raw
	local total = raw.ash + raw.verdant + raw.lumen + raw.neutral

	emptied.core.composition.ash += raw.ash
	emptied.core.composition.verdant += raw.verdant
	emptied.core.composition.lumen += raw.lumen

	raw.ash = 0
	raw.verdant = 0
	raw.lumen = 0
	raw.neutral = 0

	local added = Progression.addProgress(config, emptied, total * config.Core.processYield)
	return {
		state = added.state,
		tiersGained = added.tiersGained,
		atCeiling = added.atCeiling,
		processed = total,
	}
end

--[[ Empty the vessel for nothing. The discard IS the decision this whole
	mechanic is built around (core-and-map.md (b)) -- what is lost is
	whatever the caller already knew it was walking away from; this
	function only has to make the loss real. ]]
function Progression.discard(state: State): State
	local new = clone(state)
	new.core.raw.ash = 0
	new.core.raw.verdant = 0
	new.core.raw.lumen = 0
	new.core.raw.neutral = 0
	return new
end

--[[ Spend from the vessel: neutral first, then proportionally across
	whatever typed aura remains -- combat does not eat the identity a
	player has gathered while there is flavourless aura still sitting in
	the pool to spend instead. Refuses outright (returns the state
	UNCHANGED, ok = false) rather than spending part of a cost the vessel
	cannot fully cover; the caller decides what an insufficient pool means,
	same discipline Combat.canUse already applies to its own gating. ]]
function Progression.spendAura(state: State, amount: number): (State, boolean)
	assert(amount >= 0, "spend amount must be non-negative")
	local raw = state.core.raw
	local total = raw.ash + raw.verdant + raw.lumen + raw.neutral
	if amount > total then
		return clone(state), false
	end

	local new = clone(state)
	local newRaw = new.core.raw
	local remaining = amount

	local fromNeutral = math.min(remaining, newRaw.neutral)
	newRaw.neutral -= fromNeutral
	remaining -= fromNeutral

	if remaining > 0 then
		local typedTotal = newRaw.ash + newRaw.verdant + newRaw.lumen
		if typedTotal > 0 then
			local ashSpend = remaining * (newRaw.ash / typedTotal)
			local verdantSpend = remaining * (newRaw.verdant / typedTotal)
			-- lumen absorbs whatever the other two's shares leave, rather
			-- than computing its own share, so the three sum to exactly
			-- `remaining` regardless of floating-point rounding.
			local lumenSpend = remaining - ashSpend - verdantSpend
			newRaw.ash = math.max(0, newRaw.ash - ashSpend)
			newRaw.verdant = math.max(0, newRaw.verdant - verdantSpend)
			newRaw.lumen = math.max(0, newRaw.lumen - lumenSpend)
		end
	end

	return new, true
end

--[[ Drain the refinement bar. The ratchet lives here: a loss can cost tiers
	within the current stage but can never demote the stage itself. ]]
function Progression.applyLoss(config: any, state: State, amount: number): State
	assert(amount >= 0, "loss amount must be non-negative")
	local stage = Progression.getStage(config, state)
	local new = clone(state)
	local remaining = amount

	new.progress -= remaining
	while new.progress < 0 and new.tier > 1 do
		new.tier -= 1
		new.progress += stage.perTierProgress
	end

	if new.progress < 0 then
		-- Floored at the bottom of the current stage.
		new.progress = 0
	end

	if not config.AllowStageDemotion then
		new.stageIndex = state.stageIndex
	end

	return new
end

function Progression.canAdvanceStage(config: any, state: State): boolean
	if Progression.isMaxStage(config, state) then
		return false
	end
	if not Progression.isAtCeiling(config, state) then
		return false
	end
	local stage = Progression.getStage(config, state)
	if stage.requiresCatalyst and state.catalysts < 1 then
		return false
	end
	return true
end

--[[ Break through to the next stage, consuming a catalyst where one is
	required. Proving-ground stages advance on the trial alone so onboarding
	never stalls behind a contested drop. ]]
function Progression.advanceStage(config: any, state: State): State
	assert(Progression.canAdvanceStage(config, state), "advancement requirements not met")
	local stage = Progression.getStage(config, state)
	local new = clone(state)

	if stage.requiresCatalyst then
		new.catalysts -= 1
	end
	new.stageIndex += 1
	new.tier = 1
	new.progress = 0
	return new
end

function Progression.grantCatalysts(state: State, count: number): State
	local new = clone(state)
	new.catalysts += count
	return new
end

--[[ Scales: forged mana, the currency a die roll pays out. Whole units only,
	and never touched by applyLoss -- a death costs refinement, not the purse. ]]
function Progression.grantScales(state: State, count: number): State
	assert(count >= 0 and count == math.floor(count), "scale grants are whole and non-negative")
	local new = clone(state)
	new.scales += count
	return new
end

--[[ Refuses outright (state unchanged, ok = false) rather than spending part
	of a price the purse cannot cover -- the same contract spendAura keeps. ]]
function Progression.spendScales(state: State, count: number): (State, boolean)
	assert(count >= 0 and count == math.floor(count), "scale spends are whole and non-negative")
	if count > state.scales then
		return clone(state), false
	end
	local new = clone(state)
	new.scales -= count
	return new, true
end

--[[ Players only fight inside their own stage. Three live brackets keeps a
	small population matchable. ]]
function Progression.sameBracket(a: State, b: State): boolean
	return a.stageIndex == b.stageIndex
end

return Progression
