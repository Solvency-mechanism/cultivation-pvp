--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CombatService = require(script.CombatService)
local Config = require(ReplicatedStorage.Shared.Config)
local CultivationService = require(script.CultivationService)
local NodeService = require(script.NodeService)

NodeService.setDrainedHandler(CultivationService.onNodeDrained)
CombatService.start()

Players.PlayerAdded:Connect(function(player: Player)
	-- Cultivation state first: CombatService reads the stage index from it to
	-- size the actor.
	CultivationService.onPlayerAdded(player)
	CombatService.onPlayerAdded(player)
end)
Players.PlayerRemoving:Connect(function(player: Player)
	CombatService.onPlayerRemoving(player)
	CultivationService.onPlayerRemoving(player)
end)
for _, player in Players:GetPlayers() do
	CultivationService.onPlayerAdded(player)
	CombatService.onPlayerAdded(player)
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
	CombatService.tick(elapsed, now)
end)

print(
	`[cultivation] online -- {#Config.Stages} stages, cap at {Config.Stages[#Config.Stages].name}`
)
