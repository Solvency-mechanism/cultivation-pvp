--!strict
--[[
	The die, and scales (forged mana).

	Pure rules over an immutable Progression.State, in the shape Volcano.luau
	established: config and the Progression module are injected, never
	required, so this loads unchanged in Roblox and under Lune.

	The server owns everything that is not arithmetic here -- the cooldown
	clock, whether the roller is alive, and the random source. A client sends
	only "roll" or "refine"; it never names a face, an amount, or a time.

	The loop:
		press R -> roll a d6 -> earn face x scalesPerPip scales ->
		press C -> spend refineBatch scales -> refinement progress.
]]

local Dice = {}

export type Rng = () -> number

export type RollResult = {
	ok: boolean,
	reason: string,
	face: number,
	scales: number,
}

export type RefineResult = {
	ok: boolean,
	reason: string,
	spent: number,
	progress: number,
	tiersGained: number,
}

--[[ One face, uniform over 1..sides. `rng` returns a number in [0, 1), the
	same contract AuraNodes.Rng keeps; the clamp guards a source that ever
	returns exactly 1. ]]
function Dice.face(config: any, rng: Rng): number
	local sides = config.Dice.sides
	return math.clamp(math.floor(rng() * sides) + 1, 1, sides)
end

function Dice.scalesFor(config: any, face: number): number
	return face * config.Dice.scalesPerPip
end

--[[ Whether a roll may happen at `now`, given the last accepted roll. Kept
	pure so the rule the server enforces is the rule the tests pin. ]]
function Dice.isReady(config: any, lastRollAt: number?, now: number): boolean
	return lastRollAt == nil or now - lastRollAt >= config.Dice.cooldownSeconds
end

--[[ Roll and pay out. Rolling is allowed at the refinement ceiling on
	purpose: scales are currency first, so a player waiting on a catalyst is
	still banking something. ]]
function Dice.roll(config: any, progression: any, state: any, rng: Rng): (any, RollResult)
	local face = Dice.face(config, rng)
	local scales = Dice.scalesFor(config, face)
	return progression.grantScales(state, scales),
		{ ok = true, reason = "rolled", face = face, scales = scales }
end

--[[ Spend one batch of scales as cultivation progress. Refuses -- state
	unchanged -- at the ceiling (the progress would be thrown away) and when
	the purse cannot cover a whole batch. Progress routes through
	addProgress, so tier rollover and the ceiling clamp live in one place. ]]
function Dice.refine(config: any, progression: any, state: any): (any, RefineResult)
	local batch = config.Dice.refineBatch
	local function refused(reason: string): (any, RefineResult)
		local unchanged, _ = progression.spendScales(state, 0)
		return unchanged, { ok = false, reason = reason, spent = 0, progress = 0, tiersGained = 0 }
	end

	if progression.isAtCeiling(config, state) then
		return refused("ceiling")
	end
	local spent, paid = progression.spendScales(state, batch)
	if not paid then
		return refused("insufficient_scales")
	end
	local amount = batch * config.Dice.progressPerScale
	local added = progression.addProgress(config, spent, amount)
	return added.state,
		{
			ok = true,
			reason = "refined",
			spent = batch,
			progress = amount,
			tiersGained = added.tiersGained,
		}
end

return Dice
