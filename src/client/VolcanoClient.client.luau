--!strict
-- Expedition journal and input only. All movement, purchases and rewards are server owned.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Volcano = require(ReplicatedStorage.Shared.Volcano)
local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local action = remotes:WaitForChild("VolcanoAction") :: RemoteEvent
local feedback = remotes:WaitForChild("VolcanoFeedback") :: RemoteEvent
local gui = Instance.new("ScreenGui")
gui.Name = "VolcanoJournal"
gui.ResetOnSpawn = false
gui.DisplayOrder = 8
gui.Parent = player:WaitForChild("PlayerGui")

local panel = Instance.new("Frame")
panel.Name = "Journal"
panel.AnchorPoint = Vector2.new(1, 0.5)
panel.Position = UDim2.new(1, -16, 0.48, 0)
panel.Size = UDim2.fromOffset(285, 158)
panel.BackgroundColor3 = Color3.fromRGB(28, 23, 23)
panel.BackgroundTransparency = 0.12
panel.BorderSizePixel = 0
panel.Visible = false
panel.Parent = gui
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = panel

local function label(name: string, y: number, height: number, size: number): TextLabel
	local text = Instance.new("TextLabel")
	text.Name = name
	text.Position = UDim2.fromOffset(12, y)
	text.Size = UDim2.new(1, -24, 0, height)
	text.BackgroundTransparency = 1
	text.TextColor3 = Color3.fromRGB(246, 225, 197)
	text.TextSize = size
	text.Font = Enum.Font.Gotham
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextYAlignment = Enum.TextYAlignment.Top
	text.TextWrapped = true
	text.Parent = panel
	return text
end
local title = label("Title", 10, 20, 16)
title.Text = "THE BREATHING MOUNTAIN"
title.TextSize = 13
title.Font = Enum.Font.GothamBold
local breath = label("Breath", 34, 20, 12)
local inventory = label("Inventory", 56, 20, 13)
local clue = label("Clue", 80, 65, 13)
local panelScale = Instance.new("UIScale")
panelScale.Parent = panel
local collapsed = UserInputService.TouchEnabled
local toggle = Instance.new("TextButton")
toggle.Name = "CollapseJournal"
toggle.Position = UDim2.new(1, -28, 0, 4)
toggle.Size = UDim2.fromOffset(24, 24)
toggle.BackgroundTransparency = 1
toggle.TextColor3 = Color3.fromRGB(255, 225, 185)
toggle.TextSize = 19
toggle.Parent = panel
toggle.Activated:Connect(function()
	collapsed = not collapsed
end)

local toast = Instance.new("TextLabel")
toast.Name = "Discovery"
toast.AnchorPoint = Vector2.new(0.5, 1)
toast.Position = UDim2.new(0.5, 0, 1, -155)
toast.Size = UDim2.new(0.8, 0, 0, 60)
toast.BackgroundColor3 = Color3.fromRGB(33, 26, 22)
toast.BackgroundTransparency = 0.1
toast.TextColor3 = Color3.fromRGB(255, 228, 192)
toast.Font = Enum.Font.GothamMedium
toast.TextSize = 16
toast.TextWrapped = true
toast.Visible = false
toast.Parent = gui
local toastExpires = 0
feedback.OnClientEvent:Connect(function(message)
	if typeof(message) ~= "string" then
		return
	end
	toast.Text = message
	toast.Visible = true
	toastExpires = time() + 7
end)

local function invoke(name: string)
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if not root or not root:IsA("BasePart") then
		return
	end
	local camera = Workspace.CurrentCamera
	action:FireServer(name, if camera then camera.CFrame.LookVector else root.CFrame.LookVector)
end
local function button(text: string, x: number, name: string): TextButton
	local item = Instance.new("TextButton")
	item.Size = UDim2.fromOffset(104, 42)
	item.AnchorPoint = Vector2.new(1, 1)
	item.Position = UDim2.new(1, x, 0.48, 140)
	item.BackgroundColor3 = Color3.fromRGB(91, 49, 31)
	item.TextColor3 = Color3.fromRGB(255, 234, 211)
	item.TextSize = 13
	item.Font = Enum.Font.GothamBold
	item.Text = text
	item.Visible = false
	item.Parent = gui
	item.Activated:Connect(function()
		invoke(name)
	end)
	return item
end
local vent = button("V · Vent (20)", -16, "vent")
local cinder = button("Q · Step (25)", -126, "cinder")

-- Local animation interpolates from the shared server epoch: no replicated
-- per-frame CFrames, and late arrivals see the same point in the breath.
local breathingParts: { BasePart } = {}
local jawParts: { [BasePart]: CFrame } = {}
local jawPivot: CFrame? = nil
local emitters: { [BasePart]: ParticleEmitter } = {}
local registered: { [Instance]: boolean } = {}
local function registerVisual(object: Instance)
	if not object:IsA("BasePart") or registered[object] then
		return
	end
	registered[object] = true
	if
		object:GetAttribute("VolcanoBreath")
		or object:GetAttribute("VolcanoClue")
		or object:GetAttribute("VolcanoEye")
		or object:GetAttribute("VolcanoLava")
	then
		table.insert(breathingParts, object)
	end
	if object:GetAttribute("VolcanoJaw") then
		jawParts[object] = object.CFrame
		if object.Name == "Jaw" then
			jawPivot = object.CFrame
		end
	end
	if object:GetAttribute("VolcanoHazard") then
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "ThermalWarning"
		emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		emitter.Color = ColorSequence.new(Color3.fromRGB(255, 159, 44), Color3.fromRGB(219, 66, 26))
		emitter.Lifetime = NumberRange.new(0.8, 1.4)
		emitter.Speed = NumberRange.new(4, 7)
		emitter.SpreadAngle = Vector2.new(12, 12)
		emitter.Size = NumberSequence.new(0.5)
		emitter.LightEmission = 1
		emitter.Rate = 0
		emitter.Parent = object
		emitters[object] = emitter
	end
end
task.spawn(function()
	local deadline = time() + 30
	while not Workspace:FindFirstChild("VolcanoExperience", true) and time() < deadline do
		task.wait(0.2)
	end
	Workspace.DescendantAdded:Connect(registerVisual)
	for _, object in Workspace:GetDescendants() do
		registerVisual(object)
	end
end)
RunService.RenderStepped:Connect(function()
	local epoch = Workspace:GetAttribute("VolcanoEpoch")
	if typeof(epoch) ~= "number" then
		return
	end
	local phase = Volcano.phase(Workspace:GetServerTimeNow() - epoch)
	for _, part in breathingParts do
		part.Transparency = if part:GetAttribute("VolcanoClue")
			then 0.96 - 0.9 * phase.intensity
			else 0.3 - phase.intensity * 0.25
	end
	if jawPivot then
		local delta = jawPivot
			* CFrame.Angles(math.rad(3) * phase.intensity, 0, 0)
			* jawPivot:Inverse()
		for part, base in jawParts do
			part.CFrame = delta * base
		end
	end
	local active = phase.exhaling and phase.elapsed >= Volcano.Config.exhaleStart + 3
	local warning = phase.elapsed >= Volcano.Config.exhaleStart - 3
		and not active
		and phase.elapsed < Volcano.Config.exhaleStart + 3
	for _, emitter in emitters do
		emitter.Rate = if active then 28 else if warning then 8 else 0
		emitter.Speed = if active then NumberRange.new(12, 17) else NumberRange.new(3, 5)
	end
end)
UserInputService.InputBegan:Connect(function(input, processed)
	if processed or UserInputService:GetFocusedTextBox() then
		return
	end
	if input.KeyCode == Enum.KeyCode.Q then
		invoke("cinder")
	end
	if input.KeyCode == Enum.KeyCode.V then
		invoke("vent")
	end
end)

local accumulated = 0
RunService.Heartbeat:Connect(function(dt)
	accumulated += dt
	if accumulated < 0.2 then
		return
	end
	accumulated = 0
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	local near = root ~= nil
		and root:IsA("BasePart")
		and (root.Position - Vector3.new(251, 0, -145)).Magnitude < 185
	panel.Visible = near
	local viewport = if Workspace.CurrentCamera
		then Workspace.CurrentCamera.ViewportSize
		else Vector2.new(1280, 720)
	panelScale.Scale = math.clamp(viewport.X / 1000, 0.78, 1)
	panel.Size = UDim2.fromOffset(285, if collapsed then 36 else 158)
	breath.Visible = not collapsed
	inventory.Visible = not collapsed
	clue.Visible = not collapsed
	toggle.Text = if collapsed then "+" else "−"
	vent.Position = UDim2.new(1, -16, 0.48, if collapsed then 70 else 140)
	cinder.Position = UDim2.new(1, -126, 0.48, if collapsed then 70 else 140)
	local unlocked = player:GetAttribute("CinderStep") == true
	vent.Visible = near or (player:GetAttribute("Vessel_ash") or 0) >= 20
	cinder.Visible = unlocked
	local serverNow = Workspace:GetServerTimeNow()
	local ventWait = math.max(0, (player:GetAttribute("VentReadyAt") or 0) - serverNow)
	local cinderWait = math.max(0, (player:GetAttribute("CinderReadyAt") or 0) - serverNow)
	vent.Text = if ventWait > 0 then `Vent · {math.ceil(ventWait)}s` else "V · Vent (20)"
	cinder.Text = if cinderWait > 0 then `Step · {math.ceil(cinderWait)}s` else "Q · Step (25)"
	vent.BackgroundTransparency = if ventWait > 0 then 0.55 else 0
	cinder.BackgroundTransparency = if cinderWait > 0 then 0.55 else 0
	local phase = Workspace:GetAttribute("VolcanoPhase") or "Rest"
	local remaining = math.max(
		0,
		math.ceil((Workspace:GetAttribute("VolcanoNextBreath") or 0) - Workspace:GetServerTimeNow())
	)
	breath.Text = if phase == "Exhale"
		then "EXHALING · Rich fire aura · Watch the markings"
		else `Mountain resting · Breath in {remaining}s`
	inventory.Text =
		`Fire {math.floor(player:GetAttribute("Vessel_ash") or 0)}  /  Solid {player:GetAttribute(
			"SolidFire"
		) or 0}`
	local trialEnds = player:GetAttribute("VolcanoTrialEnds")
	if trialEnds then
		clue.Text =
			`Trial: {math.max(0, math.ceil(trialEnds - Workspace:GetServerTimeNow()))}s · Follow the climb to the upper stone.`
	elseif unlocked then
		clue.Text =
			"Cinder Step is yours. Revisit the ledges, or watch the hidden alcoves during an exhale."
	elseif player:GetAttribute("VolcanoOfferPaid") then
		clue.Text =
			"The dragon remembers your offering. Find the lower trial stone above the chamber."
	elseif player:GetAttribute("VolcanoDragonMet") then
		clue.Text =
			"Forge 40 fire into 30 solid mana at the forge. Bring the offering to the dragon."
	else
		clue.Text =
			"Follow the glow into the mountain. Cultivate fire on ember ground; seek the keeper within."
	end
	if toast.Visible and time() >= toastExpires then
		toast.Visible = false
	end
end)
