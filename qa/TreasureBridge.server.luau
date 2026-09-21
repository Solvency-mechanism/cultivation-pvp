--!strict
-- Isolated QA mapping only; never runs tests automatically.
local RunService = game:GetService("RunService")
if not RunService:IsStudio() then
	return
end
local command = Instance.new("BindableFunction")
command.Name = "TreasureQACommand"
command.OnInvoke = function(player: Player, mode: string?, id: string?)
	if mode == "spatial" then
		return require(script.Parent.TreasureRoutesQA).spatial()
	end
	if mode == "walk" then
		return require(script.Parent.TreasureRoutesQA).walk(player, id)
	end
	return require(script.Parent.TreasureQA).run(player)
end
command.Parent = script.Parent
