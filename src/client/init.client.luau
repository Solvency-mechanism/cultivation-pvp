--!strict
--[[ Minimal cultivation readout. Server publishes state to player attributes;
	this just mirrors them so the loop is observable while playtesting. ]]

local Players = game:GetService("Players")

local player = Players.LocalPlayer
local screen = Instance.new("ScreenGui")
screen.Name = "CultivationHud"
screen.ResetOnSpawn = false
screen.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(260, 108)
frame.Position = UDim2.new(0, 16, 1, -124)
frame.BackgroundColor3 = Color3.fromRGB(14, 14, 20)
frame.BackgroundTransparency = 0.25
frame.BorderSizePixel = 0
frame.Parent = screen

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = frame

local stageLabel = Instance.new("TextLabel")
stageLabel.Size = UDim2.new(1, -20, 0, 28)
stageLabel.Position = UDim2.fromOffset(10, 8)
stageLabel.BackgroundTransparency = 1
stageLabel.TextXAlignment = Enum.TextXAlignment.Left
stageLabel.Font = Enum.Font.GothamBold
stageLabel.TextSize = 20
stageLabel.TextColor3 = Color3.fromRGB(255, 205, 110)
stageLabel.Text = "--"
stageLabel.Parent = frame

local detailLabel = Instance.new("TextLabel")
detailLabel.Size = UDim2.new(1, -20, 0, 20)
detailLabel.Position = UDim2.fromOffset(10, 36)
detailLabel.BackgroundTransparency = 1
detailLabel.TextXAlignment = Enum.TextXAlignment.Left
detailLabel.Font = Enum.Font.Gotham
detailLabel.TextSize = 13
detailLabel.TextColor3 = Color3.fromRGB(200, 205, 220)
detailLabel.Text = ""
detailLabel.Parent = frame

local barBack = Instance.new("Frame")
barBack.Size = UDim2.new(1, -20, 0, 10)
barBack.Position = UDim2.fromOffset(10, 62)
barBack.BackgroundColor3 = Color3.fromRGB(40, 42, 55)
barBack.BorderSizePixel = 0
barBack.Parent = frame

local barFill = Instance.new("Frame")
barFill.Size = UDim2.fromScale(0, 1)
barFill.BackgroundColor3 = Color3.fromRGB(120, 190, 255)
barFill.BorderSizePixel = 0
barFill.Parent = barBack

local footLabel = Instance.new("TextLabel")
footLabel.Size = UDim2.new(1, -20, 0, 18)
footLabel.Position = UDim2.fromOffset(10, 80)
footLabel.BackgroundTransparency = 1
footLabel.TextXAlignment = Enum.TextXAlignment.Left
footLabel.Font = Enum.Font.Gotham
footLabel.TextSize = 12
footLabel.TextColor3 = Color3.fromRGB(150, 155, 175)
footLabel.Text = ""
footLabel.Parent = frame

local function refresh()
	local stage = player:GetAttribute("Stage") or "--"
	local tier = player:GetAttribute("Tier") or 0
	local progress = player:GetAttribute("Progress") or 0
	local goal = player:GetAttribute("TierGoal") or 1
	local catalysts = player:GetAttribute("Catalysts") or 0
	local power = player:GetAttribute("Power") or 0
	local sense = player:GetAttribute("SenseRange") or 0
	local atCeiling = player:GetAttribute("AtCeiling") == true

	stageLabel.Text = `{stage}  ·  tier {tier}`
	detailLabel.Text = `power {power}    sense {sense}    catalysts {catalysts}`

	local ratio = if goal > 0 then math.clamp(progress / goal, 0, 1) else 0
	barFill.Size = UDim2.fromScale(ratio, 1)
	barFill.BackgroundColor3 = if atCeiling
		then Color3.fromRGB(255, 195, 90)
		else Color3.fromRGB(120, 190, 255)

	footLabel.Text = if atCeiling
		then (if catalysts > 0
			then "ceiling reached — breakthrough ready"
			else "ceiling reached — need a catalyst")
		else `{progress} / {goal}`
end

for _, attr in
	{ "Stage", "Tier", "Progress", "TierGoal", "Catalysts", "Power", "SenseRange", "AtCeiling" }
do
	player:GetAttributeChangedSignal(attr):Connect(refresh)
end
refresh()
