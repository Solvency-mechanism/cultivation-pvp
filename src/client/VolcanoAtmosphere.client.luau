--!strict
-- Positional breathing uses Roblox's bundled audio; no uploaded asset IDs.
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Volcano = require(ReplicatedStorage.Shared.Volcano)
local decor = Workspace:WaitForChild("ArenaDecor")
local mountain = decor:WaitForChild("VolcanoExperience", 30)
if not mountain then
	return
end
local dragon: Model? = nil
for _, object in mountain:GetDescendants() do
	if object:IsA("Model") and object:GetAttribute("VolcanoDragon") then
		dragon = object
		break
	end
end
if not dragon or not dragon.PrimaryPart then
	return
end
local breath = Instance.new("Sound")
breath.Name = "MountainBreathing"
breath.SoundId = "rbxasset://sounds/action_falling.ogg"
breath.Looped = true
breath.PlaybackSpeed = 0.45
breath.Volume = 0
breath.RollOffMinDistance = 22
breath.RollOffMaxDistance = 180
breath.RollOffMode = Enum.RollOffMode.InverseTapered
breath.Parent = dragon.PrimaryPart
breath:Play()

local accumulator = 0
RunService.Heartbeat:Connect(function(dt)
	accumulator += dt
	if accumulator < 0.1 then
		return
	end
	accumulator = 0
	local epoch = Workspace:GetAttribute("VolcanoEpoch")
	if typeof(epoch) ~= "number" then
		return
	end
	local phase = Volcano.phase(Workspace:GetServerTimeNow() - epoch)
	breath.Volume = 0.025 + phase.intensity * 0.23
	breath.PlaybackSpeed = 0.4 + phase.intensity * 0.16
end)
