--!strict
--[[ Cultivation, combat and awareness readouts, plus input.

	The server publishes per-player state to attributes and pushes sensed nodes
	and notices over remotes. This mirrors all of it so the loop is observable
	while playtesting. Input sends slot names and a breakthrough request -- never
	damage, never a target, never a claim about cooldowns. ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Vfx = require(script.Vfx)

local player = Players.LocalPlayer
local screen = Instance.new("ScreenGui")
screen.Name = "CultivationHud"
screen.ResetOnSpawn = false
screen.Parent = player:WaitForChild("PlayerGui")

local TIER_COLOR: { [string]: Color3 } = {
	common = Color3.fromRGB(120, 190, 255),
	rare = Color3.fromRGB(170, 120, 255),
	prime = Color3.fromRGB(255, 195, 90),
}

local NOTICE_COLOR: { [string]: Color3 } = {
	server = Color3.fromRGB(255, 195, 90),
	regional = Color3.fromRGB(170, 120, 255),
	["local"] = Color3.fromRGB(200, 205, 220),
	refused = Color3.fromRGB(235, 130, 130),
}

local function panel(size: UDim2, position: UDim2): Frame
	local frame = Instance.new("Frame")
	frame.Size = size
	frame.Position = position
	frame.BackgroundColor3 = Color3.fromRGB(14, 14, 20)
	frame.BackgroundTransparency = 0.25
	frame.BorderSizePixel = 0
	frame.Parent = screen

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame
	return frame
end

local function label(
	parent: Instance,
	y: number,
	height: number,
	size: number,
	color: Color3,
	bold: boolean
): TextLabel
	local text = Instance.new("TextLabel")
	text.Size = UDim2.new(1, -20, 0, height)
	text.Position = UDim2.fromOffset(10, y)
	text.BackgroundTransparency = 1
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextYAlignment = Enum.TextYAlignment.Top
	text.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
	text.TextSize = size
	text.TextColor3 = color
	text.Text = ""
	text.Parent = parent
	return text
end

local function bar(parent: Instance, y: number, fillColor: Color3): Frame
	local back = Instance.new("Frame")
	back.Size = UDim2.new(1, -20, 0, 10)
	back.Position = UDim2.fromOffset(10, y)
	back.BackgroundColor3 = Color3.fromRGB(40, 42, 55)
	back.BorderSizePixel = 0
	back.Parent = parent

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = fillColor
	fill.BorderSizePixel = 0
	fill.Parent = back
	return fill
end

-- Status panel, bottom left.
local status = panel(UDim2.fromOffset(260, 176), UDim2.new(0, 16, 1, -192))
local stageLabel = label(status, 8, 26, 20, Color3.fromRGB(255, 205, 110), true)
stageLabel.Text = "--"
local detailLabel = label(status, 34, 18, 13, Color3.fromRGB(200, 205, 220), false)
local refinementFill = bar(status, 56, Color3.fromRGB(120, 190, 255))
local footLabel = label(status, 68, 16, 12, Color3.fromRGB(150, 155, 175), false)
local healthFill = bar(status, 90, Color3.fromRGB(225, 90, 90))
local madraFill = bar(status, 104, Color3.fromRGB(130, 150, 255))
local vitalsLabel = label(status, 116, 16, 12, Color3.fromRGB(150, 155, 175), false)
local promptLabel = label(status, 138, 30, 12, Color3.fromRGB(255, 205, 110), false)
promptLabel.TextWrapped = true

-- Sense panel, right side. Empty until the server says something is in range.
local sense = panel(UDim2.fromOffset(230, 168), UDim2.new(1, -246, 0.5, -84))
local senseHeader = label(sense, 8, 18, 12, Color3.fromRGB(255, 205, 110), true)
senseHeader.Text = "AURA SENSE"
local senseRows: { TextLabel } = {}
for index = 1, 6 do
	senseRows[index] = label(sense, 8 + index * 20, 18, 12, Color3.fromRGB(200, 205, 220), false)
end
local senseFoot = label(sense, 148, 16, 11, Color3.fromRGB(150, 155, 175), false)

-- Notice line, top centre.
local noticeFrame = panel(UDim2.fromOffset(420, 34), UDim2.new(0.5, -210, 0, 18))
noticeFrame.Visible = false
local noticeLabel = label(noticeFrame, 8, 20, 14, Color3.fromRGB(255, 205, 110), true)
noticeLabel.TextXAlignment = Enum.TextXAlignment.Center
noticeLabel.Size = UDim2.new(1, -20, 0, 20)

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
	local senseRange = player:GetAttribute("SenseRange") or 0
	local atCeiling = player:GetAttribute("AtCeiling") == true

	stageLabel.Text = `{stage}  ·  tier {tier}`
	detailLabel.Text = `power {power}    sense {senseRange}    catalysts {catalysts}`

	refinementFill.Size = UDim2.fromScale(ratio(progress, goal), 1)
	refinementFill.BackgroundColor3 = if atCeiling
		then Color3.fromRGB(255, 195, 90)
		else Color3.fromRGB(120, 190, 255)

	footLabel.Text = if atCeiling then "refinement ceiling" else `{progress} / {goal}`

	promptLabel.Text = if atCeiling and catalysts > 0
		then "[B] break through"
		elseif atCeiling then "ceiling reached — a catalyst comes only from a Prime node"
		else ""
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

--[[ The slot bar.

	Four keys, always on screen, each showing whether it is actually usable. The
	server owns cost, cooldown and the global cooldown and refuses anything it
	does not like; this only predicts locally from the same Config so the player
	can see *why* a press did nothing. A desynced prediction costs a wasted
	keypress, never a wrong outcome. ]]
local SLOT_W, SLOT_H, SLOT_GAP = 108, 76, 10
local slotBarWidth = (SLOT_W * 4) + (SLOT_GAP * 3)

local slotBar = Instance.new("Frame")
slotBar.Size = UDim2.fromOffset(slotBarWidth, SLOT_H)
slotBar.Position = UDim2.new(0.5, -slotBarWidth / 2, 1, -SLOT_H - 26)
slotBar.BackgroundTransparency = 1
slotBar.Parent = screen

type SlotWidget = {
	root: Frame,
	key: TextLabel,
	name: TextLabel,
	cost: TextLabel,
	sweep: Frame,
	stroke: UIStroke,
}

local slotWidgets: { SlotWidget } = {}

for index = 1, 4 do
	local root = Instance.new("Frame")
	root.Size = UDim2.fromOffset(SLOT_W, SLOT_H)
	root.Position = UDim2.fromOffset((index - 1) * (SLOT_W + SLOT_GAP), 0)
	root.BackgroundColor3 = Color3.fromRGB(16, 17, 24)
	root.BackgroundTransparency = 0.15
	root.BorderSizePixel = 0
	root.Parent = slotBar

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = root

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(70, 74, 92)
	stroke.Thickness = 1
	stroke.Parent = root

	-- The sweep drains downward over the cooldown, so readiness is a shape you
	-- catch peripherally rather than a number you have to read.
	local sweep = Instance.new("Frame")
	sweep.AnchorPoint = Vector2.new(0, 1)
	sweep.Position = UDim2.fromScale(0, 1)
	sweep.Size = UDim2.fromScale(1, 0)
	sweep.BackgroundColor3 = Color3.fromRGB(58, 62, 84)
	sweep.BackgroundTransparency = 0.35
	sweep.BorderSizePixel = 0
	sweep.ZIndex = 2
	sweep.Parent = root

	local sweepCorner = Instance.new("UICorner")
	sweepCorner.CornerRadius = UDim.new(0, 6)
	sweepCorner.Parent = sweep

	local key = Instance.new("TextLabel")
	key.Size = UDim2.fromOffset(20, 18)
	key.Position = UDim2.fromOffset(8, 6)
	key.BackgroundTransparency = 1
	key.Font = Enum.Font.GothamBold
	key.TextSize = 13
	key.TextColor3 = Color3.fromRGB(255, 205, 110)
	key.TextXAlignment = Enum.TextXAlignment.Left
	key.Text = tostring(index)
	key.ZIndex = 3
	key.Parent = root

	local name = Instance.new("TextLabel")
	name.Size = UDim2.new(1, -16, 0, 20)
	name.Position = UDim2.fromOffset(8, 28)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.GothamBold
	name.TextSize = 15
	name.TextColor3 = Color3.fromRGB(235, 238, 248)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Text = "--"
	name.ZIndex = 3
	name.Parent = root

	local cost = Instance.new("TextLabel")
	cost.Size = UDim2.new(1, -16, 0, 16)
	cost.Position = UDim2.fromOffset(8, 50)
	cost.BackgroundTransparency = 1
	cost.Font = Enum.Font.Gotham
	cost.TextSize = 12
	cost.TextColor3 = Color3.fromRGB(130, 150, 255)
	cost.TextXAlignment = Enum.TextXAlignment.Left
	cost.Text = ""
	cost.ZIndex = 3
	cost.Parent = root

	slotWidgets[index] = {
		root = root,
		key = key,
		name = name,
		cost = cost,
		sweep = sweep,
		stroke = stroke,
	}
end

-- Locally predicted only. The server is still the authority on every refusal.
local cooldownUntil: { [string]: number } = {}
local gcdUntil = 0

local READY_STROKE = Color3.fromRGB(120, 190, 255)
local COOLING_STROKE = Color3.fromRGB(70, 74, 92)
local BROKE_STROKE = Color3.fromRGB(120, 70, 78)

local function slotTechnique(slot: string): Config.Technique?
	local techId = player:GetAttribute("Slot_" .. slot)
	if typeof(techId) ~= "string" then
		return nil
	end
	return Config.Techniques[techId]
end

local function refreshSlots()
	local now = os.clock()
	local madra = player:GetAttribute("Madra") or 0

	for index, slot in Config.LoadoutSlots do
		local widget = slotWidgets[index]
		if not widget then
			continue
		end
		local tech = slotTechnique(slot)
		if not tech then
			widget.name.Text = "--"
			widget.cost.Text = ""
			widget.sweep.Size = UDim2.fromScale(1, 0)
			continue
		end

		widget.name.Text = tech.name
		widget.cost.Text = `{tech.madraCost} madra`

		local readyAt = math.max(cooldownUntil[tech.id] or 0, gcdUntil)
		local remaining = readyAt - now
		local affordable = madra >= tech.madraCost

		if remaining > 0 and tech.cooldown > 0 then
			widget.sweep.Size = UDim2.fromScale(1, math.clamp(remaining / tech.cooldown, 0, 1))
			widget.stroke.Color = COOLING_STROKE
			widget.name.TextColor3 = Color3.fromRGB(150, 155, 175)
			widget.cost.TextColor3 = Color3.fromRGB(110, 118, 145)
		else
			widget.sweep.Size = UDim2.fromScale(1, 0)
			widget.stroke.Color = if affordable then READY_STROKE else BROKE_STROKE
			widget.name.TextColor3 = if affordable
				then Color3.fromRGB(235, 238, 248)
				else Color3.fromRGB(160, 130, 138)
			widget.cost.TextColor3 = if affordable
				then Color3.fromRGB(130, 150, 255)
				else Color3.fromRGB(190, 100, 108)
		end
	end
end

--[[ Start the local prediction when the server confirms our own cast. Driving
	it from the server's broadcast rather than from the keypress means a refused
	press does not put the slot on a cooldown it never actually paid for. ]]
local function noteOwnCast(techId: string)
	local tech = Config.Techniques[techId]
	if not tech then
		return
	end
	local now = os.clock()
	cooldownUntil[techId] = now + tech.cooldown
	gcdUntil = now + Config.Combat.globalCooldown
end

--[[ Bearing to a node as an arrow, relative to where the camera is looking.

	Eight buckets, which is enough to walk toward something; a real compass would
	need a proper UI element rather than a glyph. The angle is taken against the
	camera's own forward and right vectors rather than a cross product, so the
	handedness is whatever Roblox says it is instead of whatever this file
	assumed. ]]
local ARROWS = {
	"\u{2191}",
	"\u{2197}",
	"\u{2192}",
	"\u{2198}",
	"\u{2193}",
	"\u{2199}",
	"\u{2190}",
	"\u{2196}",
}

local function arrowTo(x: number, z: number): string
	local camera = Workspace.CurrentCamera
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if not camera or not root or not root:IsA("BasePart") then
		return "*"
	end

	local forward = camera.CFrame.LookVector
	local right = camera.CFrame.RightVector
	local flatForward = Vector3.new(forward.X, 0, forward.Z)
	local flatRight = Vector3.new(right.X, 0, right.Z)
	local flatTo = Vector3.new(x - root.Position.X, 0, z - root.Position.Z)
	if flatForward.Magnitude < 1e-4 or flatTo.Magnitude < 1e-4 then
		return "*"
	end
	flatForward = flatForward.Unit
	flatTo = flatTo.Unit
	-- Positive angle means the node is to the camera's right.
	local angle = math.atan2(flatRight:Dot(flatTo), flatForward:Dot(flatTo))
	local index = math.round(angle / (math.pi / 4)) % 8
	return ARROWS[index + 1]
end

local function refreshSense(nodes: { any })
	for index, row in senseRows do
		local entry = nodes[index]
		if not entry then
			row.Text = ""
			continue
		end
		row.TextColor3 = TIER_COLOR[entry.tier] or Color3.fromRGB(200, 205, 220)
		row.Text = string.format(
			"%-6s %4d studs  %d/%d  %s",
			entry.tier,
			math.floor(entry.distance),
			entry.occupants,
			entry.capacity,
			arrowTo(entry.x, entry.z)
		)
	end

	local senseRange = player:GetAttribute("SenseRange") or 0
	senseFoot.Text = if senseRange <= 0
		then "no aura sense at this stage"
		elseif #nodes == 0 then "nothing within range"
		elseif #nodes > #senseRows then `{#nodes} in range`
		else ""
end

local noticeToken = 0

local function showNotice(kind: string, text: string)
	noticeToken += 1
	local token = noticeToken
	noticeLabel.TextColor3 = NOTICE_COLOR[kind] or Color3.fromRGB(255, 205, 110)
	noticeLabel.Text = text
	noticeFrame.Visible = true
	task.delay(6, function()
		if noticeToken == token then
			noticeFrame.Visible = false
		end
	end)
end

local CULTIVATION_ATTRIBUTES =
	{ "Stage", "Tier", "Progress", "TierGoal", "Catalysts", "Power", "SenseRange", "AtCeiling" }
local VITAL_ATTRIBUTES = { "Health", "MaxHealth", "Madra", "MaxMadra" }

for _, attribute in CULTIVATION_ATTRIBUTES do
	player:GetAttributeChangedSignal(attribute):Connect(refreshCultivation)
end
for _, attribute in VITAL_ATTRIBUTES do
	player:GetAttributeChangedSignal(attribute):Connect(refreshVitals)
	player:GetAttributeChangedSignal(attribute):Connect(refreshSlots)
end
for _, slot in Config.LoadoutSlots do
	player:GetAttributeChangedSignal("Slot_" .. slot):Connect(refreshSlots)
end

refreshCultivation()
refreshVitals()
refreshSlots()
refreshSense({})

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local useTechnique = remotes:WaitForChild("UseTechnique") :: RemoteEvent
local breakthrough = remotes:WaitForChild("Breakthrough") :: RemoteEvent
local sensed = remotes:WaitForChild("Sensed") :: RemoteEvent
local notice = remotes:WaitForChild("Notice") :: RemoteEvent

local latest: { any } = {}
sensed.OnClientEvent:Connect(function(nodes: { any })
	latest = nodes
	refreshSense(latest)
end)
notice.OnClientEvent:Connect(showNotice)

local techniqueFired = remotes:WaitForChild("TechniqueFired") :: RemoteEvent
techniqueFired.OnClientEvent:Connect(function(shot: Vfx.Shot)
	if shot.casterId == player.UserId then
		noteOwnCast(shot.techId)
	end
	Vfx.play(shot)
end)

-- The cooldown sweep has to animate, so the slot bar is the one thing here that
-- redraws every frame rather than only on a signal.
RunService.RenderStepped:Connect(refreshSlots)

-- Arrows are relative to the camera, so they have to be redrawn as it turns
-- even when the node list has not changed.
task.spawn(function()
	while true do
		task.wait(0.25)
		if #latest > 0 then
			refreshSense(latest)
		end
	end
end)

--[[ Keys 1-4 are the four loadout slots in Config order; B requests a
	breakthrough. Both carry intent only -- the server owns every decision. ]]
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
		-- The camera is the aim. The server validates the vector and still owns
		-- range, cost, cooldown and the raycast.
		local camera = Workspace.CurrentCamera
		useTechnique:FireServer(slot, if camera then camera.CFrame.LookVector else nil)
	elseif input.KeyCode == Enum.KeyCode.B then
		breakthrough:FireServer()
	end
end)
