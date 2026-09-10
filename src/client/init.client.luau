--!strict
--[[ Minimal cultivation and combat readout, plus technique input.

	The server publishes state to player attributes; this mirrors them so the
	loop is observable while playtesting. Input sends a *slot name* and nothing
	else -- no damage, no target, no cooldown claim. ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local player = Players.LocalPlayer
local screen = Instance.new("ScreenGui")
screen.Name = "CultivationHud"
screen.ResetOnSpawn = false
screen.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(260, 176)
frame.Position = UDim2.new(0, 16, 1, -192)
frame.BackgroundColor3 = Color3.fromRGB(14, 14, 20)
frame.BackgroundTransparency = 0.25
frame.BorderSizePixel = 0
frame.Parent = screen

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = frame

local function makeLabel(y: number, height: number, size: number, color: Color3, bold: boolean)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -20, 0, height)
	label.Position = UDim2.fromOffset(10, y)
	label.BackgroundTransparency = 1
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
	label.TextSize = size
	label.TextColor3 = color
	label.Text = ""
	label.Parent = frame
	return label
end

local function makeBar(y: number, fillColor: Color3)
	local back = Instance.new("Frame")
	back.Size = UDim2.new(1, -20, 0, 10)
	back.Position = UDim2.fromOffset(10, y)
	back.BackgroundColor3 = Color3.fromRGB(40, 42, 55)
	back.BorderSizePixel = 0
	back.Parent = frame

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = fillColor
	fill.BorderSizePixel = 0
	fill.Parent = back
	return fill
end

local stageLabel = makeLabel(8, 26, 20, Color3.fromRGB(255, 205, 110), true)
stageLabel.Text = "--"
local detailLabel = makeLabel(34, 18, 13, Color3.fromRGB(200, 205, 220), false)

local refinementFill = makeBar(56, Color3.fromRGB(120, 190, 255))
local footLabel = makeLabel(68, 16, 12, Color3.fromRGB(150, 155, 175), false)

local healthFill = makeBar(90, Color3.fromRGB(225, 90, 90))
local madraFill = makeBar(104, Color3.fromRGB(130, 150, 255))
local vitalsLabel = makeLabel(116, 16, 12, Color3.fromRGB(150, 155, 175), false)

local slotsLabel = makeLabel(134, 34, 12, Color3.fromRGB(170, 175, 195), false)
slotsLabel.TextWrapped = true

local function ratio(value: number, goal: number): number
	return if goal > 0 then math.clamp(value / goal, 0, 1) else 0
end

local function refreshCultivation()
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

	refinementFill.Size = UDim2.fromScale(ratio(progress, goal), 1)
	refinementFill.BackgroundColor3 = if atCeiling
		then Color3.fromRGB(255, 195, 90)
		else Color3.fromRGB(120, 190, 255)

	footLabel.Text = if atCeiling
		then (if catalysts > 0
			then "ceiling reached — breakthrough ready"
			else "ceiling reached — need a catalyst")
		else `{progress} / {goal}`
end

local function refreshVitals()
	local health = player:GetAttribute("Health") or 0
	local maxHealth = player:GetAttribute("MaxHealth") or 0
	local madra = player:GetAttribute("Madra") or 0
	local maxMadra = player:GetAttribute("MaxMadra") or 0

	healthFill.Size = UDim2.fromScale(ratio(health, maxHealth), 1)
	madraFill.Size = UDim2.fromScale(ratio(madra, maxMadra), 1)
	vitalsLabel.Text = `hp {health}/{maxHealth}     madra {madra}/{maxMadra}`
end

local function refreshSlots()
	local parts: { string } = {}
	for index, slot in Config.LoadoutSlots do
		local techId = player:GetAttribute("Slot_" .. slot)
		local tech = if typeof(techId) == "string" then Config.Techniques[techId] else nil
		table.insert(parts, `[{index}] {if tech then tech.name else "--"}`)
	end
	slotsLabel.Text = table.concat(parts, "   ")
end

local CULTIVATION_ATTRIBUTES =
	{ "Stage", "Tier", "Progress", "TierGoal", "Catalysts", "Power", "SenseRange", "AtCeiling" }
local VITAL_ATTRIBUTES = { "Health", "MaxHealth", "Madra", "MaxMadra" }

for _, attribute in CULTIVATION_ATTRIBUTES do
	player:GetAttributeChangedSignal(attribute):Connect(refreshCultivation)
end
for _, attribute in VITAL_ATTRIBUTES do
	player:GetAttributeChangedSignal(attribute):Connect(refreshVitals)
end
for _, slot in Config.LoadoutSlots do
	player:GetAttributeChangedSignal("Slot_" .. slot):Connect(refreshSlots)
end

refreshCultivation()
refreshVitals()
refreshSlots()

--[[ Keys 1-4 map to the four loadout slots, in Config order. The remote carries
	the slot name only; the server resolves it against the loadout it holds. ]]
local useTechnique =
	ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("UseTechnique") :: RemoteEvent

local SLOT_KEYS: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.One] = Config.LoadoutSlots[1],
	[Enum.KeyCode.Two] = Config.LoadoutSlots[2],
	[Enum.KeyCode.Three] = Config.LoadoutSlots[3],
	[Enum.KeyCode.Four] = Config.LoadoutSlots[4],
}

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed then
		return
	end
	local slot = SLOT_KEYS[input.KeyCode]
	if slot then
		useTechnique:FireServer(slot)
	end
end)
