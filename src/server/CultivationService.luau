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
local NodeService = require(script.Parent.NodeService)

local CultivationService = {}

local states: { [number]: Progression.State } = {}
local occupying: { [number]: string } = {}

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
end

local function releaseFrom(player: Player, nodeId: string)
	for _, node in NodeService.getField() do
		if node.id == nodeId then
			AuraNodes.removeOccupant(node, tostring(player.UserId))
		end
	end
	occupying[player.UserId] = nil
end

--[[ Grant a catalyst to everyone still holding a drained node. ]]
function CultivationService.onNodeDrained(node: AuraNodes.Node)
	for userIdStr in node.occupants do
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

		local region = "open"
		if node then
			region = node.region
			if occupying[player.UserId] ~= node.id then
				local ok = AuraNodes.addOccupant(Config, node, userIdStr, now)
				if ok then
					occupying[player.UserId] = node.id
				else
					-- Refused (full or expired): cycle at bare ground rate.
					node = nil
					region = "open"
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
