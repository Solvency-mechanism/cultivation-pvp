--!strict
--[[
	The die: a small HUD chip and two hotkeys. Input and display only.

	R rolls, C refines scales into cultivation. The face shown is the one the
	server rolled -- the tumble is decoration that always lands on it -- and
	the scale count is read off the `Scales` attribute CultivationService
	publishes, never computed here.

	Its own script rather than a block in init.client for the reason
	tests/compile.test gives: that chunk has already hit Luau's 200-local cap
	once.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local InterfaceSpec = require(ReplicatedStorage.Shared.InterfaceSpec)

local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local action = remotes:WaitForChild("DiceAction") :: RemoteEvent
local rolled = remotes:WaitForChild("DieRolled") :: RemoteEvent

local ROLL_KEY = Enum.KeyCode.R
local REFINE_KEY = Enum.KeyCode.C

-- Forged mana reads cool and metallic. Gold is reserved on this HUD for
-- threshold moments (InterfaceSpec.Palette), so scales never use it.
local SCALE_COLOR = Color3.fromRGB(142, 214, 204)
local PANEL = Color3.fromRGB(10, 11, 16)
local EDGE = Color3.fromRGB(62, 66, 84)
local TEXT = Color3.fromRGB(232, 236, 246)
local DIM = Color3.fromRGB(146, 153, 176)
local IVORY = Color3.fromRGB(236, 230, 214)
local PIP = Color3.fromRGB(28, 26, 34)

local gui = Instance.new("ScreenGui")
gui.Name = "DieChip"
gui.ResetOnSpawn = false
gui.DisplayOrder = 7
gui.IgnoreGuiInset = false
gui.Parent = player:WaitForChild("PlayerGui")

local chip = Instance.new("Frame")
chip.Name = "Chip"
chip.Size = UDim2.fromOffset(196, 64)
chip.BackgroundColor3 = PANEL
chip.BackgroundTransparency = 0.15
chip.BorderSizePixel = 0
chip.Parent = gui
local chipCorner = Instance.new("UICorner")
chipCorner.CornerRadius = UDim.new(0, 8)
chipCorner.Parent = chip
local chipStroke = Instance.new("UIStroke")
chipStroke.Color = EDGE
chipStroke.Thickness = 1
chipStroke.Parent = chip
local chipScale = Instance.new("UIScale")
chipScale.Parent = chip

-- The die itself doubles as the touch control for rolling.
local die = Instance.new("TextButton")
die.Name = "Die"
die.Text = ""
die.AutoButtonColor = false
die.Position = UDim2.fromOffset(8, 8)
die.Size = UDim2.fromOffset(48, 48)
die.BackgroundColor3 = IVORY
die.BorderSizePixel = 0
die.Parent = chip
local dieCorner = Instance.new("UICorner")
dieCorner.CornerRadius = UDim.new(0, 8)
dieCorner.Parent = die

-- Nine pip positions on a 3x3 grid; each face lights a subset.
local PIP_LAYOUT: { [number]: { number } } = {
	[1] = { 5 },
	[2] = { 3, 7 },
	[3] = { 3, 5, 7 },
	[4] = { 1, 3, 7, 9 },
	[5] = { 1, 3, 5, 7, 9 },
	[6] = { 1, 3, 4, 6, 7, 9 },
}
local pips: { Frame } = {}
for index = 1, 9 do
	local column = (index - 1) % 3
	local row = math.floor((index - 1) / 3)
	local pip = Instance.new("Frame")
	pip.Name = `Pip{index}`
	pip.AnchorPoint = Vector2.new(0.5, 0.5)
	pip.Position = UDim2.fromScale(0.22 + column * 0.28, 0.22 + row * 0.28)
	pip.Size = UDim2.fromOffset(9, 9)
	pip.BackgroundColor3 = PIP
	pip.BorderSizePixel = 0
	pip.Visible = false
	pip.Parent = die
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = pip
	pips[index] = pip
end

-- A die with more than six sides (Config.Dice.sides) has no pip layout, so
-- it shows its number instead.
local faceNumber = Instance.new("TextLabel")
faceNumber.Name = "FaceNumber"
faceNumber.BackgroundTransparency = 1
faceNumber.Size = UDim2.fromScale(1, 1)
faceNumber.Font = Enum.Font.GothamBold
faceNumber.TextSize = 22
faceNumber.TextColor3 = PIP
faceNumber.Visible = false
faceNumber.Parent = die

local function showFace(face: number)
	local layout = PIP_LAYOUT[face]
	for index, pip in pips do
		pip.Visible = layout ~= nil and table.find(layout, index) ~= nil
	end
	faceNumber.Visible = layout == nil
	faceNumber.Text = tostring(face)
end
showFace(Config.Dice.sides >= 6 and 6 or Config.Dice.sides)

local function text(name: string, y: number, size: number, color: Color3, bold: boolean): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(66, y)
	label.Size = UDim2.new(1, -74, 0, size + 4)
	label.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
	label.TextSize = size
	label.TextColor3 = color
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Parent = chip
	return label
end
local scalesLabel = text("Scales", 7, 17, SCALE_COLOR, true)
local rollHint = text("RollHint", 28, 12, TEXT, false)
local refineHint = text("RefineHint", 44, 12, DIM, false)

-- Touch has no keyboard, so refine gets a tap target; the die covers rolling.
local refineButton = Instance.new("TextButton")
refineButton.Name = "Refine"
refineButton.BackgroundTransparency = 1
refineButton.Text = ""
refineButton.Position = UDim2.fromOffset(62, 40)
refineButton.Size = UDim2.new(1, -66, 0, 22)
refineButton.Parent = chip

local popup = text("Earned", -22, 16, SCALE_COLOR, true)
popup.Position = UDim2.fromOffset(8, -24)
popup.Size = UDim2.new(1, -16, 0, 20)
popup.TextStrokeTransparency = 0.4
popup.Visible = false

local function send(verb: string)
	action:FireServer(verb)
end

die.Activated:Connect(function()
	send("roll")
end)
refineButton.Activated:Connect(function()
	send("refine")
end)

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed or UserInputService:GetFocusedTextBox() then
		return
	end
	if input.KeyCode == ROLL_KEY then
		send("roll")
	elseif input.KeyCode == REFINE_KEY then
		send("refine")
	end
end)

-- The tumble: a quarter-second of random faces that always lands on the
-- server's roll, then a "+N" that fades.
local tumbleUntil = 0
local landedFace = 6
local popupUntil = 0
rolled.OnClientEvent:Connect(function(face: any, scales: any)
	if typeof(face) ~= "number" or typeof(scales) ~= "number" then
		return
	end
	landedFace = face
	tumbleUntil = time() + 0.3
	popup.Text = `+{scales} scales`
	popupUntil = tumbleUntil + 1.4
end)

local lastTumbleFace = 0
local tumbleStep = 0
RunService.RenderStepped:Connect(function(dt: number)
	local now = time()
	if now < tumbleUntil then
		tumbleStep += dt
		if tumbleStep >= 0.05 then
			tumbleStep = 0
			local face = math.random(1, math.max(1, Config.Dice.sides))
			if face == lastTumbleFace then
				face = face % Config.Dice.sides + 1
			end
			lastTumbleFace = face
			showFace(face)
			die.Rotation = math.random(-18, 18)
		end
	elseif die.Rotation ~= 0 or lastTumbleFace ~= 0 then
		die.Rotation = 0
		lastTumbleFace = 0
		showFace(landedFace)
	end

	if now < popupUntil then
		popup.Visible = true
		local fade = math.clamp((popupUntil - now) / 0.5, 0, 1)
		popup.TextTransparency = 1 - fade
		popup.TextStrokeTransparency = 1 - fade * 0.6
	else
		popup.Visible = false
	end
end)

local accumulated = 0
RunService.Heartbeat:Connect(function(dt: number)
	accumulated += dt
	if accumulated < 0.1 then
		return
	end
	accumulated = 0

	local camera = Workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.new(1920, 1080)
	chipScale.Scale = InterfaceSpec.scale(viewport.Y, viewport.X)

	-- Desktop: bottom-left, clear of the centred action bar. Touch: the
	-- thumbstick owns bottom-left and jump owns bottom-right, so the chip
	-- moves to the upper right.
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		chip.AnchorPoint = Vector2.new(1, 0)
		chip.Position = UDim2.new(1, -16, 0, 64)
		rollHint.Text = "Tap die to roll"
		refineHint.Text = `Tap here · refine {Config.Dice.refineBatch}`
	else
		chip.AnchorPoint = Vector2.new(0, 1)
		chip.Position = UDim2.new(0, 16, 1, -16)
		refineHint.Text = `C · refine {Config.Dice.refineBatch}`
	end

	local scales = player:GetAttribute("Scales")
	local count = if typeof(scales) == "number" then scales else 0
	scalesLabel.Text = `{count} scales`

	local readyAt = player:GetAttribute("DieReadyAt")
	local wait = if typeof(readyAt) == "number"
		then math.max(0, readyAt - Workspace:GetServerTimeNow())
		else 0
	if wait > 0 then
		rollHint.Text = `Rolling again in {string.format("%.1f", wait)}s`
		die.BackgroundTransparency = 0.45
	else
		if not (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled) then
			rollHint.Text = "R · roll the die"
		end
		die.BackgroundTransparency = 0
	end

	local canRefine = count >= Config.Dice.refineBatch and player:GetAttribute("AtCeiling") ~= true
	refineHint.TextColor3 = if canRefine then SCALE_COLOR else DIM
end)
