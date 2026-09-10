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

export type State = {
	stageIndex: number,
	tier: number,
	progress: number,
	catalysts: number,
}

export type AddResult = {
	state: State,
	tiersGained: number,
	atCeiling: boolean,
}

local Progression = {}

local function clone(state: State): State
	return {
		stageIndex = state.stageIndex,
		tier = state.tier,
		progress = state.progress,
		catalysts = state.catalysts,
	}
end

function Progression.newState(): State
	return { stageIndex = 1, tier = 1, progress = 0, catalysts = 0 }
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
	if stageIndex and stageIndex == stageIndex then
		state.stageIndex = math.clamp(math.floor(stageIndex), 1, #config.Stages)
	end

	local tier = tonumber(raw.tier)
	if tier and tier == tier then
		state.tier = math.clamp(math.floor(tier), 1, config.RefinementTiers)
	end

	local stage = config.Stages[state.stageIndex]
	local progress = tonumber(raw.progress)
	if progress and progress == progress and progress > 0 then
		state.progress = math.min(progress, stage.perTierProgress)
	end

	local catalysts = tonumber(raw.catalysts)
	if catalysts and catalysts == catalysts and catalysts > 0 then
		state.catalysts = math.floor(catalysts)
	end

	return state
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

--[[ Players only fight inside their own stage. Three live brackets keeps a
	small population matchable. ]]
function Progression.sameBracket(a: State, b: State): boolean
	return a.stageIndex == b.stageIndex
end

return Progression
