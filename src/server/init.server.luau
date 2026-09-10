--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local CultivationService = require(script.CultivationService)
local NodeService = require(script.NodeService)

NodeService.setDrainedHandler(CultivationService.onNodeDrained)

Players.PlayerAdded:Connect(CultivationService.onPlayerAdded)
Players.PlayerRemoving:Connect(CultivationService.onPlayerRemoving)
for _, player in Players:GetPlayers() do
	CultivationService.onPlayerAdded(player)
end

local accumulator = 0
RunService.Heartbeat:Connect(function(delta: number)
	accumulator += delta
	local tickLength = Config.Field.cycleTickSeconds
	if accumulator < tickLength then
		return
	end
	local elapsed = accumulator
	accumulator = 0

	local now = os.clock()
	NodeService.step(now)
	CultivationService.tick(elapsed, now)
end)

print(
	`[cultivation] online -- {#Config.Stages} stages, cap at {Config.Stages[#Config.Stages].name}`
)
