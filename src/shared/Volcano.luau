--!strict
-- Pure expedition economy. Location, timing, life state and cooldown validation
-- belong to the server service; no client-supplied balance or reward is accepted.
local Volcano = {}

Volcano.Config = {
	cycleSeconds = 48,
	exhaleStart = 28,
	exhaleDuration = 10,
	batch = 40,
	purifyEfficiency = 0.25,
	forgeEfficiency = 0.75,
	ventCost = 20,
	brazierCost = 10,
	cinderCost = 25,
	cinderCooldown = 6,
	dragonOffer = 30,
	refugeReward = 15,
	fissureReward = 10,
}

export type Result = { ok: boolean, reason: string, message: string, amount: number? }

function Volcano.phase(
	time: number
): { name: string, exhaling: boolean, intensity: number, elapsed: number }
	local c = Volcano.Config
	local elapsed = time % c.cycleSeconds
	local exhaling = elapsed >= c.exhaleStart and elapsed < c.exhaleStart + c.exhaleDuration
	local intensity = if exhaling
		then math.sin((elapsed - c.exhaleStart) / c.exhaleDuration * math.pi)
		else 0
	return {
		name = if exhaling then "Exhale" else "Rest",
		exhaling = exhaling,
		intensity = intensity,
		elapsed = elapsed,
	}
end

function Volcano.act(config: any, progression: any, state: any, action: string): (any, Result)
	-- toStore is a deep snapshot. Returning one on failure also prevents callers
	-- from retaining an alias into the authoritative state.
	local new = progression.toStore(state)
	local c = Volcano.Config
	local expedition = new.expedition
	local function result(
		ok: boolean,
		reason: string,
		message: string,
		amount: number?
	): (any, Result)
		return new, { ok = ok, reason = reason, message = message, amount = amount }
	end
	local function spendFire(cost: number): boolean
		if new.core.raw.ash < cost then
			return false
		end
		new.core.raw.ash -= cost
		return true
	end
	if action == "purify" then
		if progression.isAtCeiling(config, new) then
			return result(
				false,
				"ceiling",
				"Your refinement is full. Break through before purifying."
			)
		end
		local spent, paid = progression.spendAura(new, c.batch)
		if not paid then
			return result(
				false,
				"insufficient_mana",
				"Gather 40 mana of any kind to purify a batch."
			)
		end
		new = progression.addProgress(config, spent, c.batch * c.purifyEfficiency).state
		return result(
			true,
			"purified",
			"Purified 40 mana into 10 advancement. Your vessel has room to gather more.",
			c.batch * c.purifyEfficiency
		)
	elseif action == "forge" then
		if not spendFire(c.batch) then
			return result(false, "insufficient_fire", "Gather 40 fire mana to forge a batch.")
		end
		expedition.solidFire += c.batch * c.forgeEfficiency
		return result(
			true,
			"forged",
			"Forged 30 solid fire mana. The dragon values this offering.",
			c.batch * c.forgeEfficiency
		)
	elseif action == "vent" or action == "cinder" then
		if action == "cinder" and not expedition.cinderStep then
			return result(false, "locked", "Discover Cinder Step through the dragon's trial.")
		end
		local cost = if action == "vent" then c.ventCost else c.cinderCost
		if not spendFire(cost) then
			return result(false, "insufficient_fire", `You need {cost} fire mana.`)
		end
		return result(
			true,
			action,
			if action == "vent" then "Released a rough burst of fire." else "Cinder Step!",
			cost
		)
	elseif action == "light_brazier" or action == "vent_brazier" then
		if expedition.discoveries.brazier then
			return result(false, "already_discovered", "You have already awakened this brazier.")
		end
		-- vent_brazier is dispatched only by the server after a paid vent with
		-- proximity and visibility validated. It must not charge a second time.
		if action == "light_brazier" and not spendFire(c.brazierCost) then
			return result(
				false,
				"insufficient_fire",
				"The brazier needs 10 fire mana. Cultivate near a fire source."
			)
		end
		expedition.discoveries.brazier = true
		return result(
			true,
			"brazier",
			"The ash parts. Seek the refuge where the mountain's breath writes in light."
		)
	elseif action == "refuge" or action == "fissure" then
		if expedition.discoveries[action] then
			return result(false, "already_discovered", "You have already claimed this discovery.")
		end
		expedition.discoveries[action] = true
		local amount = if action == "refuge" then c.refugeReward else c.fissureReward
		expedition.solidFire += amount
		return result(
			true,
			action,
			if action == "refuge"
				then "An old cultivator's cache: 15 solid fire mana."
				else "A hidden route, and 10 solid fire mana.",
			amount
		)
	elseif action == "dragon" then
		expedition.dragonMet = true
		if expedition.discoveries.offerPaid then
			return result(
				true,
				"offer_paid",
				"Your offering is remembered. Seek the trial above the chamber."
			)
		end
		if expedition.solidFire < c.dragonOffer then
			return result(
				true,
				"dragon_met",
				"Shape my mountain's fire. Bring me 30 solid fire mana, and I will teach you to cross it."
			)
		end
		expedition.solidFire -= c.dragonOffer
		expedition.discoveries.offerPaid = true
		return result(
			true,
			"offer_paid",
			"Accepted. At the trial stone, follow the breath to earn Cinder Step."
		)
	elseif action == "complete_trial" then
		-- Only the server may dispatch this after its temporary trial checks.
		if not expedition.discoveries.offerPaid then
			return result(false, "offering_required", "The dragon has not accepted your offering.")
		end
		if expedition.cinderStep then
			return result(false, "already_discovered", "Cinder Step is already yours.")
		end
		expedition.cinderStep = true
		expedition.discoveries.trial = true
		return result(
			true,
			"cinder_unlocked",
			"Cinder Step learned. Use it to cross the ledges and find your way out."
		)
	end
	return result(false, "unknown_action", "That action is not available.")
end

return Volcano
