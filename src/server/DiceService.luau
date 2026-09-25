--!strict
--[[
	The die: server-owned rolling and refining.

	A client sends one word -- "roll" or "refine" -- and nothing else. The
	face comes from a server Random, the cooldown is the server's clock, and
	the payout is Dice.roll's arithmetic; there is no argument a client could
	send that changes what it earns.

	Cultivation state has exactly one writer, so every change goes through
	CultivationService.updateState, which also publishes the `Scales`
	attribute the HUD reads.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AwarenessService = require(script.Parent.AwarenessService)
local Config = require(ReplicatedStorage.Shared.Config)
local CultivationService = require(script.Parent.CultivationService)
local Dice = require(ReplicatedStorage.Shared.Dice)
local Progression = require(ReplicatedStorage.Shared.Progression)

local DiceService = {}

local rng = Random.new()
local lastRollAt: { [Player]: number } = {}
local lastRequestAt: { [Player]: number } = {}
local rolledRemote: RemoteEvent? = nil

-- Flood guard for either action. The roll has its own, much longer cooldown;
-- this only keeps a held key or a scripted client from queuing work.
local REQUEST_FLOOR_SECONDS = 0.2

local REFINE_MESSAGES: { [string]: string } = {
	ceiling = "Your refinement is full. Scales cannot push past the ceiling -- break through first.",
	insufficient_scales = `Refining takes {Config.Dice.refineBatch} scales.`,
}

local function alive(player: Player): boolean
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	return humanoid ~= nil and humanoid.Health > 0
end

local function roll(player: Player, now: number)
	if not Dice.isReady(Config, lastRollAt[player], now) then
		-- The HUD already shows the countdown; a refusal line here would
		-- only be noise under a held key.
		return
	end
	if not alive(player) then
		return
	end

	local outcome: Dice.RollResult? = nil
	local updated = CultivationService.updateState(player, function(state)
		local nextState, result = Dice.roll(Config, Progression, state, function()
			return rng:NextNumber()
		end)
		outcome = result
		return nextState
	end)
	if not updated or not outcome then
		AwarenessService.notify(player, "refused", "Your cultivation has not settled yet.")
		return
	end

	lastRollAt[player] = now
	player:SetAttribute("DieReadyAt", now + Config.Dice.cooldownSeconds)
	if rolledRemote then
		rolledRemote:FireClient(player, outcome.face, outcome.scales)
	end
end

local function refine(player: Player)
	local outcome: Dice.RefineResult? = nil
	local updated = CultivationService.updateState(player, function(state)
		local nextState, result = Dice.refine(Config, Progression, state)
		outcome = result
		return nextState
	end)
	if not updated or not outcome then
		AwarenessService.notify(player, "refused", "Your cultivation has not settled yet.")
		return
	end
	if not outcome.ok then
		AwarenessService.notify(
			player,
			"refused",
			REFINE_MESSAGES[outcome.reason] or outcome.reason
		)
		return
	end
	local tierLine = if outcome.tiersGained > 0
		then ` Refinement rises {outcome.tiersGained} tier{if outcome.tiersGained == 1
			then ""
			else "s"}.`
		else ""
	AwarenessService.notify(
		player,
		"local",
		`Refined {outcome.spent} scales into {math.floor(outcome.progress)} cultivation.{tierLine}`
	)
end

function DiceService.start()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	-- Bounded waits: a project file that lacks these remotes should lose the
	-- die, not hang boot for every service after this one.
	local action = remotes:WaitForChild("DiceAction", 5)
	rolledRemote = remotes:WaitForChild("DieRolled", 5) :: RemoteEvent?
	if not action or not action:IsA("RemoteEvent") then
		warn("[dice] DiceAction remote missing -- the die is disabled in this build")
		return
	end

	action.OnServerEvent:Connect(function(player: Player, verb: any)
		local now = Workspace:GetServerTimeNow()
		if now - (lastRequestAt[player] or -math.huge) < REQUEST_FLOOR_SECONDS then
			return
		end
		lastRequestAt[player] = now

		if verb == "roll" then
			roll(player, now)
		elseif verb == "refine" then
			refine(player)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		lastRollAt[player] = nil
		lastRequestAt[player] = nil
	end)
end

return DiceService
