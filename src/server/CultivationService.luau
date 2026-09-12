--!strict
--[[
	Per-player cultivation state and the cycling tick.

	Server-authoritative. Every rule it applies comes from the pure Progression
	and AuraNodes modules, so this file stays a thin binding layer.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AuraNodes = require(ReplicatedStorage.Shared.AuraNodes)
local Config = require(ReplicatedStorage.Shared.Config)
local Progression = require(ReplicatedStorage.Shared.Progression)
--[[ Cycling scales with the ground the player stands on, so this needs to ask
	the map. One-way: ArenaService requires only Config, so neither this nor
	NodeService requiring it is a cycle. ]]
local ArenaService = require(script.Parent.ArenaService)
local NodeService = require(script.Parent.NodeService)

local CultivationService = {}

local states: { [number]: Progression.State } = {}
local volcanoSources: { BasePart }? = nil

local function cultivationSources(): { BasePart }
	if volcanoSources then
		return volcanoSources
	end
	local root = workspace:FindFirstChild("VolcanoExperience", true)
	local sources: { BasePart } = {}
	if root then
		for _, part in root:GetDescendants() do
			if
				part:IsA("BasePart")
				and typeof(part:GetAttribute("VolcanoCultivationRate")) == "number"
			then
				table.insert(sources, part)
			end
		end
		volcanoSources = sources
	end
	return sources
end
local occupying: { [number]: string } = {}
local lastRefusalNodeId: { [number]: string } = {}

local refusalHandler: ((Player, string) -> ())? = nil

--[[ Single owner, from here on, of every Vessel_/Core_ attribute -- per the
	vessel/core naming ruling (Vessel_ash/verdant/lumen/neutral,
	VesselCapacity, Core_ash/verdant/lumen). CombatService still writes the
	old single-pool Aura/MaxAura pair; that stops at A5, when actor.aura
	itself is refactored to draw from this pool, not here.

	Vessel_* changes on nearly every occupied tick, so tracked separately
	from the coarse `publish` below and gated on the floored integer
	actually changing -- risk #18 in the commissioned design named four
	more per-tick attributes as exactly the kind of replication churn
	Roblox attributes were never meant to absorb. `force` is for `publish`
	itself: a fresh join or a tier gain cannot trust the cache yet, and must
	write regardless, refreshing the cache so the very next tick's
	comparison is against what actually went out. ]]
local lastVesselFloor: { [number]: { ash: number, verdant: number, lumen: number, neutral: number } } =
	{}

local function publishVessel(player: Player, state: Progression.State, force: boolean)
	local ash = math.floor(state.core.raw.ash)
	local verdant = math.floor(state.core.raw.verdant)
	local lumen = math.floor(state.core.raw.lumen)
	local neutral = math.floor(state.core.raw.neutral)

	local last = lastVesselFloor[player.UserId]
	if force or not last or last.ash ~= ash then
		player:SetAttribute("Vessel_ash", ash)
	end
	if force or not last or last.verdant ~= verdant then
		player:SetAttribute("Vessel_verdant", verdant)
	end
	if force or not last or last.lumen ~= lumen then
		player:SetAttribute("Vessel_lumen", lumen)
	end
	if force or not last or last.neutral ~= neutral then
		player:SetAttribute("Vessel_neutral", neutral)
	end

	lastVesselFloor[player.UserId] =
		{ ash = ash, verdant = verdant, lumen = lumen, neutral = neutral }
end

local function publish(player: Player)
	local state = states[player.UserId]
	if not state then
		return
	end
	local stage = Progression.getStage(Config, state)
	player:SetAttribute("Stage", stage.name)
	player:SetAttribute("StageIndex", state.stageIndex)
	player:SetAttribute("Tier", state.tier)
	player:SetAttribute("Progress", math.floor(state.progress))
	player:SetAttribute("TierGoal", stage.perTierProgress)
	player:SetAttribute("Catalysts", state.catalysts)
	player:SetAttribute("Power", math.floor(Progression.effectivePower(Config, state)))
	player:SetAttribute("SenseRange", math.floor(Progression.senseRange(Config, state)))
	player:SetAttribute("AtCeiling", Progression.isAtCeiling(Config, state))

	publishVessel(player, state, true)
	player:SetAttribute("VesselCapacity", math.floor(Progression.vesselCapacity(Config, state)))
	player:SetAttribute("Core_ash", math.floor(state.core.composition.ash))
	player:SetAttribute("Core_verdant", math.floor(state.core.composition.verdant))
	player:SetAttribute("Core_lumen", math.floor(state.core.composition.lumen))
	player:SetAttribute("SolidFire", math.floor(state.expedition.solidFire))
	player:SetAttribute("CinderStep", state.expedition.cinderStep)
	player:SetAttribute("VolcanoDragonMet", state.expedition.dragonMet)
	player:SetAttribute("VolcanoOfferPaid", state.expedition.discoveries.offerPaid == true)
	player:SetAttribute("VolcanoBrazier", state.expedition.discoveries.brazier == true)
	player:SetAttribute("VolcanoRefuge", state.expedition.discoveries.refuge == true)
	player:SetAttribute("VolcanoFissure", state.expedition.discoveries.fissure == true)
end

function CultivationService.getState(player: Player): Progression.State?
	return states[player.UserId]
end

-- All expedition/resource writes use the same state owner and save path.
-- Callbacks are synchronous pure transformations; never yield inside one.
function CultivationService.updateState(
	player: Player,
	transform: (Progression.State) -> Progression.State
): boolean
	local state = states[player.UserId]
	if not state then
		return false
	end
	states[player.UserId] = transform(state)
	publish(player)
	return true
end

--[[ Fired once per refused occupancy attempt -- never once per tick, see
	`tick` below -- with the raw reason string `AuraNodes.addOccupant` already
	returns ("at_capacity", "expired"). The caller decides how to phrase it,
	same as `CultivationService.tryAdvance`'s reason does for breakthrough.

	Injected from boot rather than required directly: `AwarenessService`
	already requires `CultivationService` (to read sense range for spawn
	announcements), so this file requiring `AwarenessService` back would be a
	cycle. This is the same shape `NodeService.setDrainedHandler` already
	uses to solve the identical problem. ]]
function CultivationService.setRefusalHandler(handler: (Player, string) -> ())
	refusalHandler = handler
end

--[[ A brand new cultivator. Testers start in the Gold game rather than the
	proving ground, because the bracket that needs validating is Lowgold. ]]
function CultivationService.newPlayerState(): Progression.State
	local state = Progression.newState()
	state.stageIndex = 5
	return state
end

--[[ `restored` comes from PersistenceService when a save was found. It has
	already been through Progression.sanitizeState, so this trusts it. ]]
function CultivationService.onPlayerAdded(player: Player, restored: Progression.State?)
	states[player.UserId] = restored or CultivationService.newPlayerState()
	publish(player)
end

function CultivationService.onPlayerRemoving(player: Player)
	local nodeId = occupying[player.UserId]
	if nodeId then
		for _, node in NodeService.getField() do
			if node.id == nodeId then
				AuraNodes.removeOccupant(node, tostring(player.UserId))
			end
		end
	end
	states[player.UserId] = nil
	occupying[player.UserId] = nil
	lastRefusalNodeId[player.UserId] = nil
	lastVesselFloor[player.UserId] = nil
end

local function releaseFrom(player: Player, nodeId: string)
	for _, node in NodeService.getField() do
		if node.id == nodeId then
			AuraNodes.removeOccupant(node, tostring(player.UserId))
		end
	end
	occupying[player.UserId] = nil
end

-- A drained node rewards present players who contributed at least 10% of its reserve.
-- Timer expiry, past contributions and last-second arrivals earn no catalyst.
function CultivationService.onNodeDrained(node: AuraNodes.Node)
	if not node.drained then
		return
	end
	-- Normalised into one set before the reward loop rather than iterating
	-- drainedBy/occupants through a shared reference: they are tables of
	-- different value types ({number} vs {boolean}), and storing "whichever
	-- one" in one variable is a union luau-lsp correctly refuses to iterate
	-- (TypeError: cannot call a value in that union). Only the KEYS are
	-- ever read below, so each branch just copies its own keys in.
	local contributorIds: { [string]: boolean } = {}
	for userIdStr in node.drainedBy do
		if AuraNodes.canClaimDrain(Config, node, userIdStr) then
			contributorIds[userIdStr] = true
		end
	end

	for userIdStr in contributorIds do
		local userId = tonumber(userIdStr)
		if userId and states[userId] and AuraNodes.rollCatalyst(Config, node.tier, math.random) then
			states[userId] = Progression.grantCatalysts(states[userId], 1)
			local player = Players:GetPlayerByUserId(userId)
			if player then
				publish(player)
			end
		end
	end
end

function CultivationService.tick(deltaSeconds: number, now: number)
	for _, player in Players:GetPlayers() do
		local state = states[player.UserId]
		local character = player.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		if
			not state
			or not root
			or not root:IsA("BasePart")
			or not humanoid
			or humanoid.Health <= 0
		then
			if occupying[player.UserId] then
				releaseFrom(player, occupying[player.UserId])
			end
			continue
		end

		local userIdStr = tostring(player.UserId)
		local node = NodeService.nodeAt(root.Position)
		local previous = occupying[player.UserId]

		if previous and (not node or node.id ~= previous) then
			releaseFrom(player, previous)
		end

		-- A refusal is told once per node, not once per tick -- tick runs
		-- every cycleTickSeconds and would otherwise spam for as long as the
		-- player stands there. Clearing the memory the moment they are no
		-- longer standing on the node that refused them (walked off, or onto
		-- a different one) is what lets a later refusal speak again.
		local rememberedRefusal = lastRefusalNodeId[player.UserId]
		if rememberedRefusal and (not node or node.id ~= rememberedRefusal) then
			lastRefusalNodeId[player.UserId] = nil
		end

		--[[ Region is a property of the GROUND, everywhere -- not something that
			only exists underneath a node.

			This used to read `open` off-node, which meant the 1.8x Verdant Reach
			and the 0.5x Ember Barrens had no effect on cycling at all unless a
			node happened to be standing on them. The richest ground on the map
			was worth exactly as much as the dirt outside the plaza, and the only
			thing `Config.StaticRegionMultipliers` priced was a label on a node.

			Same order of precedence as `CombatService.regionOf`: the node when
			you are drawing from one, the ground you stand on otherwise. The two
			now agree by construction anyway, because a node's region is derived
			from its own position -- they can only differ for a player standing
			at the lip of a node that straddles a lobe edge. ]]
		local groundRegion = ArenaService.regionAt(root.Position)
		local region = groundRegion
		if node then
			region = node.region
			if occupying[player.UserId] ~= node.id then
				local ok, reason = AuraNodes.addOccupant(Config, node, userIdStr, now)
				if ok then
					occupying[player.UserId] = node.id
					lastRefusalNodeId[player.UserId] = nil
				else
					-- Refused (full or expired): cycle at the rate of whatever
					-- ground they are standing on, which is no longer always 1.0x.
					if refusalHandler and lastRefusalNodeId[player.UserId] ~= node.id then
						lastRefusalNodeId[player.UserId] = node.id
						refusalHandler(player, reason or "refused")
					end
					node = nil
					region = groundRegion
				end
			end
		end

		--[[ Config.Core.passiveFraction of today's cycling still flows straight
			to progress; the rest becomes typed aura in the vessel instead, per
			the region's RegionAura mapping. This slice preserves 25% passive
			progress so travel outside the volcano remains productive. The two
			draw from the exact same rate so a later change to passiveFraction
			cannot change how much a player's ground was ever worth, only how
			much of it arrives as a decision versus arriving for free. ]]
		local rate = AuraNodes.cycleRate(Config, node, region, true)
		-- Small authored cultivation patches teach the resource loop even when
		-- no random node spawned here. Three-dimensional distance keeps the
		-- crater's richer source from leaking through its floor into the chamber.
		for _, source in cultivationSources() do
			local sourceRate = source:GetAttribute("VolcanoCultivationRate")
			local radius = source:GetAttribute("VolcanoCultivationRadius")
			if
				typeof(sourceRate) == "number"
				and typeof(radius) == "number"
				and (root.Position - source.Position).Magnitude <= radius
			then
				rate = math.max(
					rate,
					sourceRate * (if workspace:GetAttribute("VolcanoExhaling") then 2 else 1)
				)
				region = "barren"
			end
		end
		local totalAmount = rate * deltaSeconds
		local passiveAmount = totalAmount * Config.Core.passiveFraction
		local auraAmount = totalAmount - passiveAmount

		-- luau-lsp does not narrow a nilable literal-union local through a
		-- plain truthy check back down to the non-nil union (reproduced in
		-- isolation: the same gap already worked around elsewhere this
		-- session for union iteration and closure return types) -- the
		-- `if auraType then` above already guarantees this is never nil.
		local auraType = Progression.auraTypeForRegion(Config, region)
		if auraType then
			if auraAmount > 0 then
				state = Progression.accrueAura(
					Config,
					state,
					auraType :: "ash" | "verdant" | "lumen" | "neutral",
					auraAmount
				)
			end
		end

		--[[ Config.Core.floorTrickleFraction: a small, unconditional NEUTRAL
			refill, region-independent by design -- unlike the accrual above it
			does not care whether `region`/`node` resolved to anything, so
			standing somewhere off every charted region (or simply between
			fights) still fills the vessel a little. Additive on top of
			whatever regional accrual already ran this tick; priced small
			enough (0.002/s of capacity) that real ground -- which delivers far
			more -- is never displaced as the better way to fill the vessel. ]]
		local floorTrickle = Config.Core.floorTrickleFraction
			* Progression.vesselCapacity(Config, state)
			* deltaSeconds
		if floorTrickle > 0 then
			state = Progression.accrueAura(Config, state, "neutral", floorTrickle)
		end

		local result = Progression.addProgress(Config, state, passiveAmount)
		states[player.UserId] = result.state

		if result.tiersGained > 0 or result.atCeiling then
			publish(player)
		else
			player:SetAttribute("Progress", math.floor(result.state.progress))
			publishVessel(player, result.state, false)
		end
	end
end

--[[ Spend from the vessel -- the persisted resource CombatService mirrors
	into Combat.Actor.aura and debits locally on every successful technique
	use (A5). Routed through here for the same reason applyDeathLoss is:
	cultivation state has exactly one writer, so the publish is never
	forgotten and no caller can drift the persisted vessel out of sync with
	what combat already showed the player. Refuses outright, per
	Progression.spendAura's own contract, rather than spend part of a cost
	the vessel cannot fully cover -- CombatService is expected to only ever
	call this with an amount its own already-mirrored actor.aura believes is
	covered, so a refusal here would mean the mirror had already drifted from
	the truth, not that this function invented a new failure mode. ]]
function CultivationService.spendAura(player: Player, amount: number): boolean
	local state = states[player.UserId]
	if not state then
		return false
	end
	local new, ok = Progression.spendAura(state, amount)
	if ok then
		states[player.UserId] = new
		publishVessel(player, new, false)
	end
	return ok
end

--[[ Apply the refinement loss from a combat death.

	CombatService computes the amount and Progression owns the ratchet; the
	write is routed through here so cultivation state has exactly one owner and
	the publish cannot be forgotten. ]]
function CultivationService.applyDeathLoss(player: Player, amount: number)
	local state = states[player.UserId]
	if not state then
		return
	end
	states[player.UserId] = Progression.applyLoss(Config, state, amount)
	publish(player)
end

--[[ Attempt a breakthrough. Returns ok, reason so a UI can explain refusals. ]]
function CultivationService.tryAdvance(player: Player): (boolean, string)
	local state = states[player.UserId]
	if not state then
		return false, "no_state"
	end
	if Progression.isMaxStage(Config, state) then
		return false, "at_cap"
	end
	if not Progression.isAtCeiling(Config, state) then
		return false, "not_at_ceiling"
	end
	if not Progression.canAdvanceStage(Config, state) then
		return false, "needs_catalyst"
	end
	states[player.UserId] = Progression.advanceStage(Config, state)
	publish(player)
	return true, "advanced"
end

return CultivationService
