--!strict
-- Event-driven collection. Server attributes and feedback are authoritative.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Input = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")
local Treasures = require(ReplicatedStorage.Shared.Treasures)
local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local action = remotes:WaitForChild("TreasureAction") :: RemoteEvent
local feedback = remotes:WaitForChild("TreasureFeedback") :: RemoteEvent
local connections: { RBXScriptConnection } = {}
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local effectParts: { [BasePart]: boolean } = {}
local effectCount = 0
local function transientEffect(message: any)
	if typeof(message.origin) ~= "Vector3" then
		return
	end
	local camera = Workspace.CurrentCamera
	if
		not camera
		or (camera.CFrame.Position - message.origin).Magnitude > 130
		or effectCount >= 32
	then
		return
	end
	local function piece(): Part
		local p = Instance.new("Part")
		p.Name = "TreasureLocalEffect"
		p.Anchored = true
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Parent = Workspace
		effectParts[p] = true
		effectCount += 1
		p.Destroying:Once(function()
			effectParts[p] = nil
			effectCount -= 1
		end)
		Debris:AddItem(p, 0.8)
		return p
	end
	if
		message.effect == "emberlung"
		and typeof(message.direction) == "Vector3"
		and message.direction.Magnitude > 0.01
	then
		local direction = message.direction.Unit
		for i = 1, math.min(8, 32 - effectCount) do
			local p = piece()
			p.Shape = Enum.PartType.Ball
			p.Color = if i % 2 == 0
				then Color3.fromRGB(255, 164, 59)
				else Color3.fromRGB(236, 79, 32)
			p.Size = Vector3.one * (1 + i * 0.55)
			p.Transparency = 0.35
			p.CFrame = CFrame.new(message.origin + direction * (2 + i * 2.4))
			TweenService:Create(
				p,
				TweenInfo.new(0.45),
				{ Position = p.Position + direction * 4, Size = p.Size * 1.35, Transparency = 1 }
			):Play()
		end
	elseif message.effect == "cascade_wave" then
		local p = piece()
		p.Shape = Enum.PartType.Cylinder
		p.Color = Color3.fromRGB(154, 239, 216)
		p.Size = Vector3.new(0.12, 2, 2)
		p.Transparency = 0.3
		p.CFrame = CFrame.new(message.origin - Vector3.new(0, 2.4, 0))
			* CFrame.Angles(0, 0, math.pi / 2)
		TweenService
			:Create(p, TweenInfo.new(0.6), { Size = Vector3.new(0.12, 24, 24), Transparency = 1 })
			:Play()
	end
end
local gui = Instance.new("ScreenGui")
gui.Name = "TreasureCollection"
gui.ResetOnSpawn = false
gui.DisplayOrder = 20
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = player:WaitForChild("PlayerGui")
local ink = Color3.fromRGB(23, 31, 35)
local paper = Color3.fromRGB(237, 231, 211)
local muted = Color3.fromRGB(177, 186, 181)
local gold = Color3.fromRGB(221, 188, 111)
local function round(parent: Instance)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 8)
	c.Parent = parent
end
local function label(parent: Instance, text: string, size: number): TextLabel
	local p = Instance.new("TextLabel")
	p.BackgroundTransparency = 1
	p.Text = text
	p.TextSize = size
	p.Font = Enum.Font.Gotham
	p.TextColor3 = paper
	p.TextWrapped = true
	p.TextXAlignment = Enum.TextXAlignment.Left
	p.Parent = parent
	return p
end
local function button(parent: Instance, text: string): TextButton
	local p = Instance.new("TextButton")
	p.Text = text
	p.TextSize = 14
	p.Font = Enum.Font.GothamMedium
	p.TextColor3 = paper
	p.BackgroundColor3 = Color3.fromRGB(48, 64, 68)
	p.BorderSizePixel = 0
	p.AutoButtonColor = true
	p.TextWrapped = true
	p.Parent = parent
	round(p)
	return p
end
local toggle = button(gui, "Treasures  [I]")
toggle.Name = "OpenTreasures"
toggle.AnchorPoint = Vector2.new(0.5, 0)
toggle.Position = UDim2.new(0.5, 0, 0, 8)
toggle.Size = UDim2.fromOffset(152, 44)
local panel = Instance.new("Frame")
panel.Name = "Collection"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.BackgroundColor3 = ink
panel.BorderSizePixel = 0
panel.Visible = false
panel.Parent = gui
round(panel)
local title = label(panel, "TREASURES", 20)
title.Font = Enum.Font.GothamBold
title.Position = UDim2.fromOffset(16, 12)
title.Size = UDim2.new(1, -80, 0, 28)
local summary = label(panel, "Discover powers hidden in the world.", 12)
summary.TextColor3 = muted
summary.Position = UDim2.fromOffset(16, 42)
summary.Size = UDim2.new(1, -32, 0, 22)
local close = button(panel, "Close")
close.Size = UDim2.fromOffset(64, 44)
close.Position = UDim2.new(1, -76, 0, 10)
local selected = 1
local owned: { [string]: boolean } = {}
local equipped: { string } = { "", "", "" }
local slots: { TextButton } = {}
for i = 1, 3 do
	local b = button(panel, `SLOT {i}\nEmpty`)
	b.Name = `Slot{i}`
	b.Position = UDim2.new((i - 1) / 3, 12, 0, 72)
	b.Size = UDim2.new(1 / 3, -16, 0, 54)
	b.TextSize = 12
	table.insert(slots, b)
end
local clear = button(panel, "Unequip selected slot")
clear.Position = UDim2.fromOffset(12, 134)
clear.Size = UDim2.new(0.55, -18, 0, 44)
local charge = label(panel, "", 12)
charge.Position = UDim2.new(0.55, 2, 0, 134)
charge.Size = UDim2.new(0.45, -14, 0, 44)
charge.TextColor3 = gold
local status =
	label(panel, "Choose a slot, then equip a discovered treasure. Swaps require safety.", 12)
status.Position = UDim2.fromOffset(14, 184)
status.Size = UDim2.new(1, -28, 0, 38)
status.TextColor3 = muted
local list = Instance.new("ScrollingFrame")
list.Name = "OwnedCollection"
list.Position = UDim2.fromOffset(12, 230)
list.Size = UDim2.new(1, -24, 1, -242)
list.BackgroundTransparency = 1
list.BorderSizePixel = 0
list.ScrollBarThickness = 5
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.CanvasSize = UDim2.new()
list.Parent = panel
local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 8)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = list
local rows: { [string]: { frame: Frame, name: TextLabel, description: TextLabel, equip: TextButton } } =
	{}
for index, id in Treasures.Order do
	local item = Treasures.Catalog[id]
	local row = Instance.new("Frame")
	row.Name = id
	row.LayoutOrder = index
	row.Size = UDim2.new(1, -7, 0, 116)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.BackgroundColor3 = Color3.fromRGB(34, 44, 48)
	row.BorderSizePixel = 0
	row.Parent = list
	round(row)
	local name = label(row, "Undiscovered treasure", 15)
	name.Font = Enum.Font.GothamMedium
	name.Position = UDim2.fromOffset(12, 8)
	name.Size = UDim2.new(1, -124, 0, 38)
	local desc = label(row, "Explore the world to uncover this treasure.", 13)
	desc.TextColor3 = muted
	desc.Position = UDim2.fromOffset(12, 50)
	desc.Size = UDim2.new(1, -24, 0, 64)
	desc.AutomaticSize = Enum.AutomaticSize.Y
	desc.TextYAlignment = Enum.TextYAlignment.Top
	local equip = button(row, "Undiscovered")
	equip.Name = "Equip"
	equip.Position = UDim2.new(1, -108, 0, 8)
	equip.Size = UDim2.fromOffset(96, 44)
	equip.TextSize = 12
	rows[id] = { frame = row, name = name, description = desc, equip = equip }
	table.insert(
		connections,
		equip.Activated:Connect(function()
			if owned[id] then
				action:FireServer({ action = "equip", id = id, slot = selected })
			end
		end)
	)
	-- Keep names/descriptions hidden until the server records discovery.
	if item.rarity == "Legendary" then
		name.TextColor3 = gold
	end
end
local reveal = Instance.new("Frame")
local toast = label(gui, "", 14)
toast.Name = "TreasureNotice"
toast.AnchorPoint = Vector2.new(0.5, 0)
toast.Position = UDim2.new(0.5, 0, 0, 60)
toast.Size = UDim2.new(0.8, 0, 0, 58)
toast.BackgroundColor3 = ink
toast.BackgroundTransparency = 0.08
toast.TextXAlignment = Enum.TextXAlignment.Center
toast.Visible = false
round(toast)
local noticeSerial = 0
local function notify(message: string, ok: boolean)
	status.Text = message
	status.TextColor3 = if ok then muted else Color3.fromRGB(255, 178, 150)
	noticeSerial += 1
	local serial = noticeSerial
	toast.Text = message
	toast.Visible = not reveal.Visible and (not panel.Visible or not status.Visible)
	task.delay(5, function()
		if gui.Parent and serial == noticeSerial then
			toast.Visible = false
		end
	end)
end

reveal.Name = "DiscoveryReveal"
reveal.AnchorPoint = Vector2.new(0.5, 0.5)
reveal.Position = UDim2.fromScale(0.5, 0.5)
reveal.BackgroundColor3 = ink
reveal.BorderSizePixel = 0
reveal.Visible = false
reveal.Parent = gui
round(reveal)
local revealTitle = label(reveal, "TREASURE DISCOVERED", 12)
revealTitle.TextColor3 = gold
revealTitle.Position = UDim2.fromOffset(20, 15)
revealTitle.Size = UDim2.new(1, -40, 0, 24)
local revealName = label(reveal, "", 23)
revealName.Font = Enum.Font.GothamBold
revealName.Position = UDim2.fromOffset(20, 44)
revealName.Size = UDim2.new(1, -40, 0, 58)
local revealDescription = label(reveal, "", 14)
revealDescription.Position = UDim2.fromOffset(20, 105)
revealDescription.Size = UDim2.new(1, -40, 0, 92)
revealDescription.TextYAlignment = Enum.TextYAlignment.Top
local inspect = button(reveal, "Open collection")
inspect.Position = UDim2.fromOffset(20, 210)
inspect.Size = UDim2.new(0.65, -24, 0, 44)
local dismiss = button(reveal, "Later")
dismiss.Position = UDim2.new(0.65, 4, 0, 210)
dismiss.Size = UDim2.new(0.35, -24, 0, 44)
local StarterGui = game:GetService("StarterGui")
local playerListPrior: boolean? = nil
local function restorePlayerList()
	if playerListPrior ~= nil then
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, playerListPrior :: boolean)
		end)
		playerListPrior = nil
	end
end
local function updatePlayerList()
	if panel.Visible or reveal.Visible then
		if playerListPrior == nil then
			local ok, enabled = pcall(function()
				return StarterGui:GetCoreGuiEnabled(Enum.CoreGuiType.PlayerList)
			end)
			if ok then
				playerListPrior = enabled
				pcall(function()
					StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
				end)
			end
		end
	else
		restorePlayerList()
	end
end
table.insert(connections, panel:GetPropertyChangedSignal("Visible"):Connect(updatePlayerList))
table.insert(connections, reveal:GetPropertyChangedSignal("Visible"):Connect(updatePlayerList))
local revealed: { [string]: boolean } = {}
local function showDiscovery(id: string)
	local item = Treasures.Catalog[id]
	if not item or revealed[id] then
		return
	end
	revealed[id] = true
	revealName.Text = item.name
	revealTitle.Text = string.upper(item.rarity) .. " TREASURE DISCOVERED"
	revealDescription.Text = item.description
	panel.Visible = false
	reveal.Visible = true
	toast.Visible = false
end
local function decode(attribute: string): any
	local raw = player:GetAttribute(attribute)
	if typeof(raw) ~= "string" then
		return {}
	end
	local ok, value = pcall(HttpService.JSONDecode, HttpService, raw)
	return if ok and type(value) == "table" then value else {}
end
local function render()
	local total = 0
	for _ in owned do
		total += 1
	end
	summary.Text = `{total} / {#Treasures.Order} discovered · 3 universal slots`
	for i, b in slots do
		local item = Treasures.Catalog[equipped[i]]
		b.Text = `SLOT {i}\n{if item then item.name else "Empty"}`
		b.BackgroundColor3 = if i == selected
			then Color3.fromRGB(110, 84, 42)
			else Color3.fromRGB(48, 64, 68)
	end
	for id, row in rows do
		local item = Treasures.Catalog[id]
		local slot = table.find(equipped, id)
		row.name.Text = if owned[id] then item.name else "Undiscovered treasure"
		row.description.Text = if owned[id]
			then item.description
			else "Seek hidden objects in the world. Discover to reveal its power."
		row.equip.Text = if not owned[id]
			then "Undiscovered"
			elseif slot == selected then "Equipped"
			elseif slot then `Move from {slot}`
			else `Equip · {selected}`
		row.equip.AutoButtonColor = owned[id] == true
		row.equip.BackgroundTransparency = if owned[id] then 0 else 0.7
	end
	local heart = table.find(equipped, "cascade_heart") ~= nil
	local amount = player:GetAttribute("TreasureCharge")
	local ready = heart and typeof(amount) == "number" and amount >= 1
	toggle.Text = if ready then "Heart ready  [I]" else "Treasures  [I]"
	toggle.TextColor3 = if ready then gold else paper
	charge.Text = if heart
		then `Heart: {math.floor(
			(if typeof(amount) == "number" then math.clamp(amount, 0, 1) else 0) * 100
		)}% charged`
		else "All treasure types fit any slot"
end
local function refresh()
	local nextOwned = {}
	for _, id in decode("TreasuresOwned") do
		if Treasures.Catalog[id] then
			nextOwned[id] = true
		end
	end
	owned = nextOwned
	local raw = decode("TreasuresEquipped")
	equipped = { "", "", "" }
	for i = 1, 3 do
		if typeof(raw[i]) == "string" and owned[raw[i]] then
			equipped[i] = raw[i]
		end
	end
	render()
end
for i, b in slots do
	table.insert(
		connections,
		b.Activated:Connect(function()
			selected = i
			render()
		end)
	)
end
table.insert(
	connections,
	clear.Activated:Connect(function()
		action:FireServer({ action = "unequip", slot = selected })
	end)
)
local function togglePanel()
	panel.Visible = not panel.Visible
	reveal.Visible = false
	toast.Visible = false
end
table.insert(connections, toggle.Activated:Connect(togglePanel))
table.insert(
	connections,
	close.Activated:Connect(function()
		panel.Visible = false
	end)
)
table.insert(
	connections,
	inspect.Activated:Connect(function()
		reveal.Visible = false
		panel.Visible = true
		refresh()
	end)
)
table.insert(
	connections,
	dismiss.Activated:Connect(function()
		reveal.Visible = false
	end)
)
table.insert(
	connections,
	Input.InputBegan:Connect(function(input, processed)
		if processed or Input:GetFocusedTextBox() then
			return
		end
		if input.KeyCode == Enum.KeyCode.I then
			togglePanel()
		elseif input.KeyCode == Enum.KeyCode.Escape then
			panel.Visible = false
			reveal.Visible = false
		end
	end)
)
for _, attribute in { "TreasuresOwned", "TreasuresEquipped", "TreasureCharge" } do
	table.insert(connections, player:GetAttributeChangedSignal(attribute):Connect(refresh))
end
table.insert(
	connections,
	feedback.OnClientEvent:Connect(function(message)
		if typeof(message) ~= "table" then
			return
		end
		if typeof(message.effect) == "string" then
			transientEffect(message)
		end
		if typeof(message.message) == "string" then
			notify(message.message, message.ok == true)
		end
		if typeof(message.discovered) == "string" then
			showDiscovery(message.discovered)
		end
	end)
)
local viewportConnection: RBXScriptConnection? = nil
local function resize()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local topInset, bottomInset = GuiService:GetGuiInset()
	local size = camera.ViewportSize - topInset - bottomInset
	panel.Size = UDim2.fromOffset(
		math.max(280, math.min(620, size.X - 24)),
		math.max(240, math.min(680, size.Y - 40))
	)
	local compact = size.Y < 480
	summary.Visible = not compact
	status.Visible = not compact
	for i, b in slots do
		b.Position = UDim2.new((i - 1) / 3, 12, 0, if compact then 58 else 72)
		b.Size = UDim2.new(1 / 3, -16, 0, if compact then 44 else 54)
	end
	clear.Position = UDim2.fromOffset(12, if compact then 110 else 134)
	charge.Position = UDim2.new(0.55, 2, 0, if compact then 110 else 134)
	list.Position = UDim2.fromOffset(12, if compact then 164 else 230)
	list.Size = UDim2.new(1, -24, 1, if compact then -176 else -242)
	reveal.Size = UDim2.fromOffset(math.max(280, math.min(460, size.X - 24)), 272)
end
local function bindCamera()
	if viewportConnection then
		viewportConnection:Disconnect()
	end
	local camera = Workspace.CurrentCamera
	if camera then
		viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(resize)
	end
	resize()
end
table.insert(connections, Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindCamera))
script.Destroying:Connect(function()
	restorePlayerList()
	for _, connection in connections do
		connection:Disconnect()
	end
	if viewportConnection then
		viewportConnection:Disconnect()
	end
	for part in effectParts do
		part:Destroy()
	end
	gui:Destroy()
end)
refresh()
bindCamera()
