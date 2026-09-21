--!strict
-- Isolated QA relay exercises the normal client-to-server action path.
if not game:GetService("RunService"):IsStudio() then
	return
end
local replicated = game:GetService("ReplicatedStorage")
local relay = replicated:WaitForChild("TreasureQAClient") :: RemoteEvent
relay.OnClientEvent:Connect(function(action, direction)
	local remote = replicated.Remotes.VolcanoAction :: RemoteEvent
	remote:FireServer(action, direction)
end)
