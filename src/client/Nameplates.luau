--!strict
--[[
	Nameplates: what another cultivator looks like from across a fight.

	Name, stage and tier, a health bar, and a cast bar, floating over every other
	player's head. Client-side, presentation-only, and reading nothing but
	replicated attributes -- `Health`, `MaxHealth`, `Stage`, `Tier` -- which the
	server already publishes for every player and which therefore already reach
	every client at no cost. No new protocol, no server round trip, nothing this
	module can get wrong that reaches anyone else's machine.

	**Why these are built here rather than in PresenceService.** That service
	already floats a stage plate, and it is right to: stage is slow-changing
	state and rebuilding a billboard on change is cheap. Health and a cast bar
	are not slow-changing -- they want a per-frame redraw -- and a server pushing
	that at every player for every other player is exactly the kind of traffic a
	nameplate must never cost. So the plate moves client-side and PresenceService
	keeps the aura, which is genuinely server state.

	The server plate is *disabled* rather than removed when this module takes
	over. If anything in here throws, the original plate is one property away
	from coming back, and a player still knows who they are looking at.

	**Why nameplates matter more here than in the game this register comes from.**
	There is no tab-target. Nameplates are the only way to read the other three
	people in a node fight rather than just whoever is under your reticle.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local InterfaceSpec =
	require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("InterfaceSpec"))

local Nameplates = {}

local player = Players.LocalPlayer

local PLATE_NAME = "HudNameplate"
-- PresenceService's own plate, which this one supersedes.
local SERVER_PLATE_NAME = "CultivatorPlate"

local function color(rgb: InterfaceSpec.Rgb): Color3
	return Color3.fromRGB(rgb.r, rgb.g, rgb.b)
end

local PALETTE = InterfaceSpec.Palette
local PLATE = InterfaceSpec.Plate

local TROUGH = color(PALETTE.trough)
local HEALTH = color(PALETTE.health)
local HEALTH_LOW = color(PALETTE.healthLow)
local TEXT = color(PALETTE.text)
local TEXT_DIM = color(PALETTE.textDim)
local BLACK = Color3.new(0, 0, 0)

--[[ The cast registry.

	Owned here rather than in the HUD because the nameplate is the *primary*
	consumer -- a cast you need to react to usually belongs to someone who is not
	under your reticle. The HUD's own cast bar and the target frame both read
	back out of this same table via `Nameplates.castOf`, so there is exactly one
	record of who is casting what and no chance of the plate and the frame
	disagreeing about it.

	Keyed by UserId. Cleared when the windup elapses, and overwritten rather than
	queued if a second cast arrives -- a caster has at most one cast in flight,
	since the global cooldown outlasts every windup in the pool. ]]
export type Cast = {
	techId: string,
	kind: string,
	windup: number,
	startedAt: number,
	endsAt: number,
}

local casts: { [number]: Cast } = {}

--[[ Started on receipt against the *client's* clock rather than from a server
	timestamp, because `os.clock` is not shared across machines. The cost is the
	one-way latency, which shortens the bar slightly -- the defender sees the
	telegraph start a few frames late and it finishes exactly when the technique
	resolves. Wrong in the direction that costs the attacker, which is the right
	direction to be wrong in. ]]
function Nameplates.noteCast(casterId: number, techId: string, kind: string, windup: number)
	local now = os.clock()
	casts[casterId] = {
		techId = techId,
		kind = kind,
		windup = windup,
		startedAt = now,
		-- Sub-floor windups still get a record, so the plate can flash even
		-- though it will not draw a bar. `flashSeconds` gives the flash
		-- somewhere to live without pretending to be a duration.
		endsAt = now + math.max(windup, InterfaceSpec.Cast.flashSeconds),
	}
end

function Nameplates.castOf(userId: number): Cast?
	local cast = casts[userId]
	if not cast then
		return nil
	end
	if os.clock() >= cast.endsAt + InterfaceSpec.Cast.holdSeconds then
		casts[userId] = nil
		return nil
	end
	return cast
end

type Plate = {
	gui: BillboardGui,
	name: TextLabel,
	stage: TextLabel,
	healthFill: Frame,
	castRow: Frame,
	castFill: Frame,
	castLabel: TextLabel,
	character: Model,
	head: BasePart,
}

local plates: { [number]: Plate } = {}

local function stroked(text: TextLabel): TextLabel
	--[[ Plates sit over the world, not over a panel, so text here keeps the
		stroke the HUD sheds. `ImpactSpec`'s rule -- value contrast is what
		carries legibility at distance, on any ground -- applies to a nameplate
		more than to anything else in the interface. ]]
	local stroke = Instance.new("UIStroke")
	stroke.Color = BLACK
	stroke.Thickness = 2
	stroke.Transparency = 0.15
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Parent = text
	return text
end

local function buildPlate(target: Player, character: Model, head: BasePart): Plate?
	local scale = InterfaceSpec.scale(
		Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize.Y or 1080
	)
	local width = math.round(PLATE.width * scale)
	local nameHeight = math.round(PLATE.nameTextSize * scale) + 4
	local healthHeight = math.round(PLATE.healthHeight * scale)
	local castHeight = math.round(PLATE.castHeight * scale)
	local gap = math.round(PLATE.rowGap * scale)
	--[[ The stage text and the cast bar share the third row and swap between
		them, so the row has to be tall enough for the *taller* of the two. Sized
		to the cast bar alone, the stage caption would spill out of the billboard
		-- which a BillboardGui will happily render, since it does not clip, so
		the bug would show up as text drifting under the plate rather than as
		anything that announces itself. ]]
	local thirdRow = math.max(castHeight, math.round(PLATE.stageTextSize * scale) + 4)
	local castTop = nameHeight + gap + healthHeight + gap
	local total = castTop + thirdRow

	local gui = Instance.new("BillboardGui")
	gui.Name = PLATE_NAME
	gui.Size = UDim2.fromOffset(width, total)
	gui.StudsOffsetWorldSpace = Vector3.new(0, PLATE.studsOffset, 0)
	-- Occluded rather than always-on-top: seeing health bars through a wall
	-- would be a wallhack the interface handed out for free.
	gui.AlwaysOnTop = false
	gui.MaxDistance = PLATE.maxDistance
	gui.ResetOnSpawn = false
	gui.Parent = head

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(1, 0, 0, nameHeight)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = math.round(PLATE.nameTextSize * scale)
	nameLabel.TextColor3 = TEXT
	nameLabel.TextXAlignment = Enum.TextXAlignment.Center
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Text = target.DisplayName
	nameLabel.Parent = gui
	stroked(nameLabel)

	--[[ Stage sits under the health bar and *shares* its row with the cast bar,
		the two swapping rather than stacking. While a technique is winding up,
		what this person is about to do outranks what stage they are -- and
		reusing the row keeps the plate from growing at exactly the moment a
		fight gets busy and screen space is scarcest. ]]
	local stageLabel = Instance.new("TextLabel")
	stageLabel.Size = UDim2.new(1, 0, 0, thirdRow)
	stageLabel.Position = UDim2.fromOffset(0, castTop)
	stageLabel.BackgroundTransparency = 1
	stageLabel.Font = Enum.Font.GothamMedium
	stageLabel.TextSize = math.round(PLATE.stageTextSize * scale)
	stageLabel.TextColor3 = TEXT_DIM
	stageLabel.TextXAlignment = Enum.TextXAlignment.Center
	stageLabel.Text = ""
	stageLabel.Parent = gui
	stroked(stageLabel)

	local healthBack = Instance.new("Frame")
	healthBack.Size = UDim2.new(1, 0, 0, healthHeight)
	healthBack.Position = UDim2.fromOffset(0, nameHeight + gap)
	healthBack.BackgroundColor3 = TROUGH
	healthBack.BackgroundTransparency = 0.15
	healthBack.BorderSizePixel = 0
	healthBack.Parent = gui

	local healthStroke = Instance.new("UIStroke")
	healthStroke.Color = BLACK
	healthStroke.Thickness = 1
	healthStroke.Transparency = 0.3
	healthStroke.Parent = healthBack

	local healthFill = Instance.new("Frame")
	healthFill.Size = UDim2.fromScale(1, 1)
	healthFill.BackgroundColor3 = HEALTH
	healthFill.BorderSizePixel = 0
	healthFill.Parent = healthBack

	--[[ The cast row occupies the same band the stage label does, and the two
		swap: while a technique is winding up, what this person is *about to do*
		outranks what stage they are. Reusing the row rather than adding one
		keeps the plate from growing at the exact moment a fight gets busy. ]]
	local castRow = Instance.new("Frame")
	castRow.Size = UDim2.new(1, 0, 0, castHeight)
	-- Vertically centred in the shared row, so swapping to it does not make the
	-- plate appear to jump.
	castRow.Position = UDim2.fromOffset(0, castTop + math.floor((thirdRow - castHeight) / 2))
	castRow.BackgroundColor3 = TROUGH
	castRow.BackgroundTransparency = 0.1
	castRow.BorderSizePixel = 0
	castRow.Visible = false
	castRow.Parent = gui

	local castStroke = Instance.new("UIStroke")
	castStroke.Color = BLACK
	castStroke.Thickness = 1
	castStroke.Transparency = 0.3
	castStroke.Parent = castRow

	local castFill = Instance.new("Frame")
	castFill.Size = UDim2.fromScale(0, 1)
	castFill.BackgroundColor3 = TEXT
	castFill.BorderSizePixel = 0
	castFill.Parent = castRow

	local castLabel = Instance.new("TextLabel")
	castLabel.Size = UDim2.fromScale(1, 1)
	castLabel.BackgroundTransparency = 1
	castLabel.Font = Enum.Font.GothamBold
	castLabel.TextSize = math.max(math.round(PLATE.stageTextSize * scale) - 1, 8)
	castLabel.TextColor3 = TEXT
	castLabel.TextXAlignment = Enum.TextXAlignment.Center
	castLabel.ZIndex = 3
	castLabel.Text = ""
	castLabel.Parent = castRow
	stroked(castLabel)

	return {
		gui = gui,
		name = nameLabel,
		stage = stageLabel,
		healthFill = healthFill,
		castRow = castRow,
		castFill = castFill,
		castLabel = castLabel,
		character = character,
		head = head,
	}
end

--[[ Stand PresenceService's plate down, every frame rather than once at build.

	Doing it once did not work, and the reason is a race this could not have been
	reasoned out of without two clients on screen: PresenceService *polls*, so its
	plate is frequently created after ours, and a one-shot disable at build time
	finds nothing to disable. Worse, `PresenceService.apply` destroys and rebuilds
	the plate whenever stage or tier changes, so even a correctly-timed disable
	would come undone at the next breakthrough.

	Disabled rather than destroyed, still: its own tick rebuilds a plate it cannot
	find, so destroying it would start a fight that runs every tick for the rest
	of the session. Setting a property that is already set costs nothing, and if
	anything in this module throws, one property brings the original plate back.

	Looked up non-recursively on the head, which is where PresenceService parents
	it -- a recursive search over a whole character every frame for every player
	is not a thing to do sixty times a second. ]]
local function standDownServerPlate(plate: Plate)
	local serverPlate = plate.head:FindFirstChild(SERVER_PLATE_NAME)
	if serverPlate and serverPlate:IsA("BillboardGui") and serverPlate.Enabled then
		serverPlate.Enabled = false
	end
end

local function dropPlate(userId: number)
	local plate = plates[userId]
	if not plate then
		return
	end
	plates[userId] = nil
	if plate.gui then
		plate.gui:Destroy()
	end
end

local function ensurePlate(target: Player)
	if target == player then
		return
	end
	local character = target.Character
	if not character then
		dropPlate(target.UserId)
		return
	end
	local existing = plates[target.UserId]
	if existing and existing.character == character and existing.gui.Parent then
		return
	end
	dropPlate(target.UserId)

	local head = character:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	local built = buildPlate(target, character, head)
	if built then
		plates[target.UserId] = built
	end
end

local function refresh(target: Player, plate: Plate)
	standDownServerPlate(plate)

	local health = target:GetAttribute("Health")
	local maxHealth = target:GetAttribute("MaxHealth")
	local fraction = InterfaceSpec.fraction(
		if typeof(health) == "number" then health else 0,
		if typeof(maxHealth) == "number" then maxHealth else 0
	)

	plate.healthFill.Size = UDim2.fromScale(fraction, 1)
	plate.healthFill.BackgroundColor3 = if fraction <= InterfaceSpec.Vitals.lowHealthFraction
		then HEALTH_LOW
		else HEALTH

	local stage = target:GetAttribute("Stage")
	local tier = target:GetAttribute("Tier")
	if typeof(stage) == "string" then
		plate.stage.Text = if typeof(tier) == "number" then `{stage}  ·  {tier}` else stage
	else
		plate.stage.Text = ""
	end

	--[[ Stage colour is carried by the *name*, not by a separate chip. One
		coloured element per plate; anything more and a busy fight becomes a
		field of competing hues with no hierarchy. ]]
	local stageIndex = target:GetAttribute("StageIndex")
	if typeof(stageIndex) == "number" then
		plate.name.TextColor3 = color(InterfaceSpec.stageColor(stageIndex))
	end

	local cast = Nameplates.castOf(target.UserId)
	if cast and InterfaceSpec.telegraphs(cast.windup) then
		local elapsed = os.clock() - cast.startedAt
		local progress = math.clamp(elapsed / math.max(cast.windup, 1e-3), 0, 1)
		plate.castRow.Visible = true
		plate.stage.Visible = false
		plate.castFill.Size = UDim2.fromScale(progress, 1)
		plate.castFill.BackgroundColor3 = color(InterfaceSpec.kindColor(cast.kind))
		plate.castLabel.Text = string.upper(cast.techId)
	else
		plate.castRow.Visible = false
		plate.stage.Visible = true
		--[[ A sub-floor windup gets a flash on the name instead of a bar. It
			says "something just happened here" without promising a duration
			that was never readable. ]]
		if cast then
			local remaining = cast.endsAt - os.clock()
			if remaining > 0 then
				plate.name.TextColor3 = color(InterfaceSpec.kindColor(cast.kind))
			end
		end
	end
end

function Nameplates.start()
	local function watch(target: Player)
		target.CharacterAdded:Connect(function()
			-- The head arrives with the character but the attributes may not,
			-- so the plate is built on the next step rather than right here.
			dropPlate(target.UserId)
		end)
		target.CharacterRemoving:Connect(function()
			dropPlate(target.UserId)
		end)
	end

	for _, other in Players:GetPlayers() do
		watch(other)
	end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(function(other: Player)
		dropPlate(other.UserId)
		casts[other.UserId] = nil
	end)

	RunService.RenderStepped:Connect(function()
		for _, other in Players:GetPlayers() do
			if other == player then
				continue
			end
			ensurePlate(other)
			local plate = plates[other.UserId]
			if plate then
				refresh(other, plate)
			end
		end
	end)
end

return Nameplates
