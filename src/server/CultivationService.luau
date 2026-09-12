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
local occupying: { [number]: string } = {}
local lastRefusalNodeId: { [number]: string } = {}

local refusalHandler: ((Player, string) -> ())? = nil

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
end

function CultivationService.getState(player: Player): Progression.State?
	return states[player.UserId]
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
end

local function releaseFrom(player: Player, nodeId: string)
	for _, node in NodeService.getField() do
		if node.id == nodeId then
			AuraNodes.removeOccupant(node, tostring(player.UserId))
		end
	end
	occupying[player.UserId] = nil
end

--[[ Grant a catalyst to everyone who held a drained node, weighted by their
	own share of the drain -- occupants who held it to the end, not whoever
	happens to be standing there at the instant it completes. drainedBy is
	already the share-weighted structure (a bigger number IS a bigger
	share); nothing further needs computing from it here. Falls back to
	occupants when drainedBy is empty -- the compatibility guarantee: a
	node that simply aged out (nobody ever occupied it while AuraNodes.drain
	could run) still yields exactly as it did before the drain existed. ]]
function CultivationService.onNodeDrained(node: AuraNodes.Node)
	-- Normalised into one set before the reward loop rather than iterating
	-- drainedBy/occupants through a shared reference: they are tables of
	-- different value types ({number} vs {boolean}), and storing "whichever
	-- one" in one variable is a union luau-lsp correctly refuses to iterate
	-- (TypeError: cannot call a value in that union). Only the KEYS are
	-- ever read below, so each branch just copies its own keys in.
	local contributorIds: { [string]: boolean } = {}
	if next(node.drainedBy) then
		for userIdStr in node.drainedBy do
			contributorIds[userIdStr] = true
		end
	else
		for userIdStr in node.occupants do
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
		if not state or not root or not root:IsA("BasePart") then
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

		local rate = AuraNodes.cycleRate(Config, node, region, true)
		local result = Progression.addProgress(Config, state, rate * deltaSeconds)
		states[player.UserId] = result.state

		if result.tiersGained > 0 or result.atCeiling then
			publish(player)
		else
			player:SetAttribute("Progress", math.floor(result.state.progress))
		end
	end
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
