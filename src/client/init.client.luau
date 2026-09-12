--!strict
--[[ The heads-up display, and the input layer that drives it.

	Rebuilt out of the Roblox-traditional register -- big panels pinned to the
	four corners -- and into the dense, anchored one this game's combat now
	needs. The argument is not aesthetic. The old HUD carried four facts and
	carried them well; the fight it has to describe now involves health, aura,
	a per-technique cooldown, a global cooldown, a windup you must react to, an
	opponent whose state you have never once been able to see, and a bracket rule
	that silently refuses fights. Corner panels cannot carry that, and the
	information architecture that can is well known.

	**The organising rule: combat-critical state is anchored to the action bar,
	everything else is exiled to the edges.** The action bar's position is the
	one thing that was already right -- bottom centre, under the character -- so
	health, aura and the cast bar stack directly on top of it. Reading your own
	health used to cost a diagonal saccade to the far corner and back, mid
	exchange. It now costs a few degrees.

	Everything here is presentation and intent. The client sends a slot name and
	an aim vector and nothing else; it predicts cooldowns locally so a press can
	explain itself, and the server remains the only authority on every refusal.

	Tuning lives in `src/shared/InterfaceSpec.luau`, in the shape `ImpactSpec`
	established, so the numbers behind the layout are testable outside Studio and
	sit next to the impact numbers they have to agree with.

	**Sections are scoped, and the reason is a compiler limit that no lint sees.**
	Luau allows a function at most 200 local registers, and the top-level chunk
	of a script is a function. This file crossed 200 top-level locals in
	74f3c2b, the compiler refused it, and NOTHING in it ran -- no vitals, no
	action bar, no reticle -- while four test suites and three linters stayed
	green, because none of them compile a client script. So each UI section
	builds its elements inside a `do ... end` block and exports the handles other
	code needs through ONE record (`targetUi`, `vitalsUi`, ...), and everything
	else stays inside the block and off the top-level count.

	`tests/compile.test` is the hard gate; `tests/interface.test` holds a soft
	ceiling well under 200 so the count is caught a commit early rather than at
	the moment it breaks. When you add a top-level local here, ask whether it
	belongs inside a section's block first. ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local InterfaceSpec = require(Shared:WaitForChild("InterfaceSpec"))
local Nameplates = require(script.Nameplates)
local Vfx = require(script.Vfx)

local player = Players.LocalPlayer

local screen = Instance.new("ScreenGui")
screen.Name = "CultivationHud"
screen.ResetOnSpawn = false
--[[ The inset is respected rather than ignored. Roblox owns the top strip --
	its menu button and the player list live there -- and a notice or a target
	frame drawn underneath that chrome is unreadable in exactly the way that is
	hardest to notice from a developer's own machine. ]]
screen.IgnoreGuiInset = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.Parent = player:WaitForChild("PlayerGui")

local PALETTE = InterfaceSpec.Palette

local function color(rgb: InterfaceSpec.Rgb): Color3
	return Color3.fromRGB(rgb.r, rgb.g, rgb.b)
end

local PANEL = color(PALETTE.panel)
local TROUGH = color(PALETTE.trough)
local EDGE = color(PALETTE.edge)
local TEXT = color(PALETTE.text)
local TEXT_DIM = color(PALETTE.textDim)
local TEXT_FAINT = color(PALETTE.textFaint)
local HEALTH = color(PALETTE.health)
local HEALTH_LOW = color(PALETTE.healthLow)
local AURA = color(PALETTE.aura)
local REFINEMENT = color(PALETTE.refinement)
local CEILING = color(PALETTE.ceiling)
local READY = color(PALETTE.ready)
local COOLING = color(PALETTE.cooling)
local UNAFFORDABLE = color(PALETTE.unaffordable)
local SCRIM = color(PALETTE.scrim)
local DANGER = color(PALETTE.danger)
local KEYBIND = color(PALETTE.keybind)
local LOCK = color(PALETTE.lock)
local SLOW = color(PALETTE.slow)
local NEUTRAL = color(PALETTE.neutral)
--[[ The four aura colours are roster's, in Config.AuraTypes, as integers.
	Kept as Rgb here because the stops function is pure and returns them
	unconverted; the gradient builder converts at the edge. ]]
local AURA_COLORS: { [string]: InterfaceSpec.Rgb } = {}
for key, auraType in Config.AuraTypes :: { [string]: any } do
	AURA_COLORS[key] = auraType.color
end
local BLACK = Color3.new(0, 0, 0)

local NOTICE_COLOR: { [string]: Color3 } = {
	server = CEILING,
	regional = color(InterfaceSpec.KindColor.ruler),
	["local"] = TEXT_DIM,
	refused = DANGER,
	-- A kill reads as a threshold crossed, which is the one thing gold is for
	-- outside ImpactSpec's killing blow. A death is the only red the HUD shows
	-- that is not a health bar, and it means what the vignette means.
	kill = CEILING,
	death = DANGER,
	-- A cross-bracket warning in either direction. Same hue as a refusal,
	-- because it is one kind of thing: the fight you are in is not the fight
	-- you think it is.
	-- Information, not an event: a human asked for it quieter. See NoticeKind.
	bracket = TEXT_DIM,
	-- An NPC falling: its own register, never the kill banner's gold.
	npc = NEUTRAL,
}

local TIER_COLOR: { [string]: Color3 } = {
	common = color(InterfaceSpec.KindColor.striker),
	rare = color(InterfaceSpec.KindColor.ruler),
	prime = CEILING,
}

--[[ One scale factor for the whole interface, resolved once at build.

	Density is a *ratio*, not a pixel count. Shrinking every font is the naive
	route to a tight HUD and it produces something dense on a monitor and
	illegible on a phone, which is where most of this platform plays. Every size
	below is quoted against a 1080-tall viewport and multiplied through here, so
	a small screen gets the same layout at a larger absolute size rather than a
	miniature of the desktop one.

	Resolved once rather than bound to viewport changes: rebuilding the tree on
	every resize is a lot of machinery for a case that happens when someone drags
	a window, and a stale scale is survivable where a rebuild mid-fight is not. ]]
local viewport = if Workspace.CurrentCamera
	then Workspace.CurrentCamera.ViewportSize
	else Vector2.new(1920, 1080)
local SCALE = InterfaceSpec.scale(viewport.Y, viewport.X)

local function px(value: number): number
	return math.round(value * SCALE)
end

local function text(value: number): number
	return math.max(math.round(value * SCALE), 9)
end

--[[ Text over an opaque trough sheds the 2px stroke the old HUD put on
	everything. The stroke was there because text sat over the world; on a panel
	it only buys blur and forces the padding that forced the corner. Text over
	the *world* -- nameplates, damage numbers -- keeps it, and that lives in
	`Nameplates` and `Impact` respectively. ]]
local function caption(parent: Instance, size: number, textColor: Color3, bold: boolean): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = if bold then Enum.Font.GothamBold else Enum.Font.GothamMedium
	label.TextSize = size
	label.TextColor3 = textColor
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Text = ""
	label.Parent = parent
	return label
end

local function corner(instance: Instance, radius: number)
	local ui = Instance.new("UICorner")
	ui.CornerRadius = UDim.new(0, radius)
	ui.Parent = instance
end

local function outline(instance: Instance, strokeColor: Color3, thickness: number): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = strokeColor
	stroke.Thickness = thickness
	stroke.Parent = instance
	return stroke
end

--[[ A bar is a trough plus a fill, and nothing else.

	The old HUD centred `aura 174 / 200` inside every bar. That is correct when
	aura is the only pool you manage and wrong the moment there are several:
	centred numbers fight the fill for the same pixels, and the bars stop reading
	as *shapes* -- which is the entire reason a bar beats a number in peripheral
	vision. Numbers move to the ends and get small. The fill carries the reading;
	the number is an annotation on it. ]]
local function bar(parent: Instance, height: number, fillColor: Color3): (Frame, Frame)
	local back = Instance.new("Frame")
	back.Size = UDim2.new(1, 0, 0, height)
	back.BackgroundColor3 = TROUGH
	back.BackgroundTransparency = 0.1
	back.BorderSizePixel = 0
	back.Parent = parent
	corner(back, 2)

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = fillColor
	fill.BorderSizePixel = 0
	fill.Parent = back
	corner(fill, 2)

	return back, fill
end

-- ===================================================================
-- The bottom cluster: vitals, cast bar, action bar. One visual column.
-- ===================================================================

local SLOT = InterfaceSpec.Slot
local VITALS = InterfaceSpec.Vitals
local TARGET = InterfaceSpec.Target
local CASTSPEC = InterfaceSpec.Cast

local slotNames = Config.LoadoutSlots
local slotCount = #slotNames

local slotSize = px(SLOT.size)
local slotGap = px(SLOT.gap)
local barWidth = px(InterfaceSpec.barWidth(slotCount))
local vitalsWidth = px(VITALS.width)
-- The pair -- vitals and the target frame, side by side -- sets the width.
local pairGap = px(TARGET.pairGap)
local clusterWidth = math.max(vitalsWidth * 2 + pairGap, barWidth)

local headerHeight = text(VITALS.headerTextSize) + px(4)
local healthHeight = px(VITALS.healthHeight)
local auraHeight = px(VITALS.auraHeight)
local rowGap = px(VITALS.rowGap)
local stackGap = px(VITALS.stackGap)
local castHeight = px(CASTSPEC.height)
local vitalsHeight = headerHeight + healthHeight + rowGap + auraHeight

local clusterHeight = vitalsHeight + stackGap + castHeight + stackGap + slotSize

local cluster = Instance.new("Frame")
cluster.Name = "Cluster"
cluster.AnchorPoint = Vector2.new(0.5, 1)
cluster.Position = UDim2.new(0.5, 0, 1, -px(SLOT.bottomMargin))
cluster.Size = UDim2.fromOffset(clusterWidth, clusterHeight)
cluster.BackgroundTransparency = 1
cluster.Parent = screen

local vitals = Instance.new("Frame")
vitals.Name = "Vitals"
--[[ The left half of the pair. Right-anchored against the centre line so the
	target frame, left-anchored against the same line, is its mirror. ]]
vitals.AnchorPoint = Vector2.new(1, 0)
vitals.Position = UDim2.new(0.5, -pairGap / 2, 0, 0)
vitals.Size = UDim2.fromOffset(vitalsWidth, vitalsHeight)
vitals.BackgroundTransparency = 1
vitals.Parent = cluster

--[[ The header line: who you are, in the two facts that decide what you may do.
	Stage decides your PvP bracket -- `Combat.canEngage` refuses across it -- and
	tier decides where you sit inside it. ]]
local vitalsUi: {
	stageLabel: TextLabel,
	powerLabel: TextLabel,
	healthFill: Frame,
	healthValue: TextLabel,
	auraFill: Frame,
	auraGradient: UIGradient,
	auraValue: TextLabel,
	coreChip: Frame,
	coreGradient: UIGradient,
	coreRing: UIStroke,
	slowChip: TextLabel,
	nodeBar: Frame,
	nodeFill: Frame,
}
do
	--[[ The node you are standing in: its reserve, draining, directly above
		your vitals in the guidance gap. The thing you are spending, above the
		vessel you spend it into. Tier-coloured, unlabelled, gone when you
		step out. See InterfaceSpec.NodeBar. ]]
	local nodeBarHeight = px(InterfaceSpec.NodeBar.height)
	local nodeBar = Instance.new("Frame")
	nodeBar.Name = "NodeBar"
	nodeBar.AnchorPoint = Vector2.new(0, 1)
	nodeBar.Position = UDim2.fromOffset(0, -px(InterfaceSpec.NodeBar.margin))
	nodeBar.Size = UDim2.new(1, 0, 0, nodeBarHeight)
	nodeBar.BackgroundTransparency = 1
	nodeBar.Visible = false
	nodeBar.Parent = vitals
	local _nodeBack, nodeFill = bar(nodeBar, nodeBarHeight, CEILING)
	--[[ The core chip: what you have processed, ever, as a disc of colour
		bands in the proportions of your composition. Permanent and static --
		it does not move during a fight, which is what tells identity apart
		from resource on a HUD where everything else drains and refills. In
		the header row, left of the stage name, because the header is the row
		that says who you are; and IN the header row rather than under it, so
		no new row exists for `stackHeight()` to forget. Hollow until the first
		process: you are nobody yet, and the ring says so. ]]
	local chipSize = headerHeight - px(InterfaceSpec.Vessel.chipInset) * 2
	local coreChip = Instance.new("Frame")
	coreChip.Name = "CoreChip"
	coreChip.Size = UDim2.fromOffset(chipSize, chipSize)
	coreChip.Position = UDim2.fromOffset(0, px(InterfaceSpec.Vessel.chipInset))
	coreChip.BackgroundColor3 = Color3.new(1, 1, 1)
	coreChip.BackgroundTransparency = 1
	coreChip.BorderSizePixel = 0
	coreChip.Parent = vitals
	local chipCorner = Instance.new("UICorner")
	chipCorner.CornerRadius = UDim.new(1, 0)
	chipCorner.Parent = coreChip
	local coreGradient = Instance.new("UIGradient")
	coreGradient.Rotation = InterfaceSpec.Vessel.chipRotation
	coreGradient.Enabled = false
	coreGradient.Parent = coreChip
	local coreRing = outline(coreChip, TEXT_FAINT, 1)

	local stageLeft = chipSize + px(InterfaceSpec.Vessel.chipGap)
	local stageLabel = caption(vitals, text(VITALS.headerTextSize), CEILING, true)
	stageLabel.Size = UDim2.new(0.6, -stageLeft, 0, headerHeight)
	stageLabel.Position = UDim2.fromOffset(stageLeft, 0)
	stageLabel.RichText = true
	stageLabel.Text = "--"

	local powerLabel = caption(vitals, text(VITALS.labelTextSize), TEXT_FAINT, false)
	powerLabel.Size = UDim2.new(0.4, 0, 0, headerHeight)
	powerLabel.Position = UDim2.fromScale(0.6, 0)
	powerLabel.TextXAlignment = Enum.TextXAlignment.Right

	local healthRow = Instance.new("Frame")
	healthRow.Size = UDim2.new(1, 0, 0, healthHeight)
	healthRow.Position = UDim2.fromOffset(0, headerHeight)
	healthRow.BackgroundTransparency = 1
	healthRow.Parent = vitals
	local _healthBack, healthFill = bar(healthRow, healthHeight, HEALTH)

	local healthValue = caption(healthRow, text(VITALS.valueTextSize), TEXT, true)
	healthValue.Size = UDim2.new(1, -px(6), 1, 0)
	healthValue.Position = UDim2.fromOffset(px(6), 0)
	healthValue.TextXAlignment = Enum.TextXAlignment.Right
	healthValue.ZIndex = 3

	local auraRow = Instance.new("Frame")
	auraRow.Size = UDim2.new(1, 0, 0, auraHeight)
	auraRow.Position = UDim2.fromOffset(0, headerHeight + healthHeight + rowGap)
	auraRow.BackgroundTransparency = 1
	auraRow.Parent = vitals
	local _auraBack, auraFill = bar(auraRow, auraHeight, AURA)

	--[[ The vessel. The bar was labelled AURA because a blue bar with a word
		from this game's own fiction needed the word. It no longer does: the
		fill is a single frame carrying a hard-stop gradient that divides it by
		aura colour in the proportions held, so the bar says what it holds by
		being those colours, and the core chip beside the stage name is its
		legend. Until the server publishes a typed vessel the bar is the one
		blue it always was. A UIGradient multiplies its parent's colour, so
		the fill goes white the moment the gradient is on and back to blue
		when it is off. ]]
	local auraGradient = Instance.new("UIGradient")
	auraGradient.Enabled = false
	auraGradient.Parent = auraFill

	local auraValue = caption(auraRow, text(VITALS.valueTextSize) - 1, TEXT_DIM, true)
	auraValue.Size = UDim2.new(1, -px(6), 1, 0)
	auraValue.Position = UDim2.fromOffset(px(6), 0)
	auraValue.TextXAlignment = Enum.TextXAlignment.Right
	auraValue.ZIndex = 3

	--[[ The slow, beside your own vitals. A slow is the first thing in this
		game that changes what your own keys do, and the vitals are where you
		look to learn that. Same word and same colour as the cue on another
		combatant's plate, so it is one status effect and not two. Sits in the
		header row's right edge, where the power readout is, and takes that
		space over while a slow is on you -- power is a slow number, a slow is
		a fast one. ]]
	local slowChip = caption(vitals, text(InterfaceSpec.Status.chipTextSize), SLOW, true)
	slowChip.Size = UDim2.new(0.4, 0, 0, headerHeight)
	slowChip.Position = UDim2.fromScale(0.6, 0)
	slowChip.TextXAlignment = Enum.TextXAlignment.Right
	slowChip.Visible = false

	vitalsUi = {
		stageLabel = stageLabel,
		powerLabel = powerLabel,
		healthFill = healthFill,
		healthValue = healthValue,
		auraFill = auraFill,
		auraGradient = auraGradient,
		auraValue = auraValue,
		coreChip = coreChip,
		coreGradient = coreGradient,
		coreRing = coreRing,
		slowChip = slowChip,
		nodeBar = nodeBar,
		nodeFill = nodeFill,
	}
end

--[[ Your own cast bar, immediately above the action bar.

	It is the direct consequence of the button you just pressed, so it sits
	adjacent to the button. It also does something the old HUD could not: a
	windup is a *commitment* -- aim is sampled at cast and the technique resolves
	wherever you were pointing -- and until now nothing on screen said that the
	commitment was in progress. ]]
local castUi: { frame: Frame, fill: Frame, name: TextLabel, timer: TextLabel }
do
	local castFrame = Instance.new("Frame")
	castFrame.Name = "CastBar"
	castFrame.AnchorPoint = Vector2.new(0.5, 0)
	castFrame.Position = UDim2.new(0.5, 0, 0, vitalsHeight + stackGap)
	castFrame.Size = UDim2.fromOffset(px(CASTSPEC.width), castHeight)
	castFrame.BackgroundColor3 = TROUGH
	castFrame.BackgroundTransparency = 0.1
	castFrame.BorderSizePixel = 0
	castFrame.Visible = false
	castFrame.Parent = cluster
	corner(castFrame, 2)
	outline(castFrame, BLACK, 1).Transparency = 0.4

	local castFill = Instance.new("Frame")
	castFill.Size = UDim2.fromScale(0, 1)
	castFill.BackgroundColor3 = READY
	castFill.BorderSizePixel = 0
	castFill.Parent = castFrame
	corner(castFill, 2)

	local castName = caption(castFrame, text(CASTSPEC.textSize), TEXT, true)
	castName.Size = UDim2.new(1, -px(12), 1, 0)
	castName.Position = UDim2.fromOffset(px(6), 0)
	castName.ZIndex = 3

	local castTimer = caption(castFrame, text(CASTSPEC.textSize), TEXT, true)
	castTimer.Size = UDim2.new(1, -px(12), 1, 0)
	castTimer.Position = UDim2.fromOffset(px(6), 0)
	castTimer.TextXAlignment = Enum.TextXAlignment.Right
	castTimer.ZIndex = 3
	castUi = { frame = castFrame, fill = castFill, name = castName, timer = castTimer }
end

-- ===================================================================
-- The action bar.
-- ===================================================================

--[[ Built from `Config.LoadoutSlots` rather than from a literal 4.

	The movement pass adds a fifth kind and a fifth slot; when that lands this
	bar grows on its own with no edit here. It also flagged a five-slot bar as a
	phone-width worry it could not resolve -- at this geometry the worry does not
	arise, because square icon slots put five in 314px where the old wide
	name-plates put four in 468. Denser *and* narrower. ]]
local actionBar = Instance.new("Frame")
actionBar.Name = "ActionBar"
actionBar.AnchorPoint = Vector2.new(0.5, 1)
actionBar.Position = UDim2.fromScale(0.5, 1)
actionBar.Size = UDim2.fromOffset(barWidth, slotSize)
actionBar.BackgroundTransparency = 1
actionBar.Parent = cluster

local KEY_CODES = {
	Enum.KeyCode.One,
	Enum.KeyCode.Two,
	Enum.KeyCode.Three,
	Enum.KeyCode.Four,
	Enum.KeyCode.Five,
	Enum.KeyCode.Six,
}
local KEY_GLYPHS = { "1", "2", "3", "4", "5", "6" }

--[[ On touch the slot *is* the button, so a keybind glyph would be a label for
	a key that does not exist. On a gamepad the digits are equally meaningless.
	Rendered per device rather than assumed. ]]
local showKeyGlyphs = UserInputService.KeyboardEnabled

type SlotWidget = {
	root: TextButton,
	key: TextLabel,
	name: TextLabel,
	cost: TextLabel,
	countdown: TextLabel,
	reach: Frame,
	sweep: Frame,
	sweepLeft: UIGradient,
	sweepRight: UIGradient,
	gcd: Frame,
	stripe: Frame,
	stroke: UIStroke,
	slot: string,
}

local slotWidgets: { SlotWidget } = {}

for index = 1, slotCount do
	--[[ A TextButton rather than a Frame, so the bar is usable by touch and by
		mouse without a second input path. Costs nothing on keyboard. ]]
	local root = Instance.new("TextButton")
	root.Size = UDim2.fromOffset(slotSize, slotSize)
	root.Position = UDim2.fromOffset((index - 1) * (slotSize + slotGap), 0)
	root.BackgroundColor3 = PANEL
	root.BackgroundTransparency = 0.08
	root.BorderSizePixel = 0
	root.AutoButtonColor = false
	root.Text = ""
	root.Parent = actionBar
	corner(root, px(SLOT.cornerRadius))

	local stroke = outline(root, EDGE, 1)

	--[[ The kind stripe along the bottom edge: the icon-family signal, standing
		in for art nobody has drawn. Five kinds is a vocabulary learned in one
		session; sixty-plus technique names is not, so the *kind* is what carries
		colour and the name is printed for whoever has time to read it. ]]
	local stripe = Instance.new("Frame")
	stripe.AnchorPoint = Vector2.new(0, 1)
	stripe.Position = UDim2.fromScale(0, 1)
	stripe.Size = UDim2.new(1, 0, 0, px(SLOT.stripeHeight))
	stripe.BackgroundColor3 = EDGE
	stripe.BorderSizePixel = 0
	stripe.ZIndex = 2
	stripe.Parent = root

	--[[ The cooldown sweep: a radial wedge, unwinding clockwise from twelve.

		Readiness as a *shape* caught peripherally rather than a number you have
		to read -- that was always the point, and the vertical drain this replaces
		did it adequately. A wedge does it in the vocabulary twenty years of the
		register this HUD borrows from have trained into anyone who has played
		it, which is why it was asked for by name.

		**Built without rotating a single GuiObject, and that is the whole
		design.** The obvious rig -- two clipped halves, each holding a rotated
		rectangle -- depends on `ClipsDescendants` clipping *rotated* children,
		which Roblox has historically not done reliably. Get that wrong and the
		failure is not a slightly-off wedge; it is two dark rectangles spinning
		across the whole HUD. So the half-plane each half needs is drawn instead
		with a `UIGradient` carrying a hard transparency step at its midpoint,
		and the gradient's own `Rotation` swings the boundary line. The frames
		never rotate, the clips only ever see axis-aligned children, and the one
		primitive this depends on -- a gradient rotating about its centre -- is
		well supported.

		Two halves, because a rotating half-plane can only ever cover half a
		circle. The right half's dark region is the half-plane to the right of a
		line through the centre, rotated by the elapsed angle; the left half's
		is the mirror. Between them they cover exactly the arc from the current
		angle clockwise round to twelve -- the time *remaining* -- and that arc
		shrinks as the cooldown runs down.

		Behind a switch, because none of this has been seen running: if it looks
		wrong in Studio, `radialSweep = false` returns the drain in one line
		rather than a revert. ]]
	local sweepLeft = Instance.new("Frame")
	sweepLeft.Size = UDim2.fromScale(0.5, 1)
	sweepLeft.BackgroundTransparency = 1
	sweepLeft.BorderSizePixel = 0
	sweepLeft.ClipsDescendants = true
	sweepLeft.ZIndex = 3
	sweepLeft.Parent = root

	local sweepRight = Instance.new("Frame")
	sweepRight.Position = UDim2.fromScale(0.5, 0)
	sweepRight.Size = UDim2.fromScale(0.5, 1)
	sweepRight.BackgroundTransparency = 1
	sweepRight.BorderSizePixel = 0
	sweepRight.ClipsDescendants = true
	sweepRight.ZIndex = 3
	sweepRight.Parent = root

	-- A hard step at the midpoint: one side of the boundary line is the scrim,
	-- the other is nothing. `opaqueFirst` decides which side.
	local function halfPlane(parent: Frame, atLocalX: number, opaqueFirst: boolean): UIGradient
		local dark = Instance.new("Frame")
		dark.AnchorPoint = Vector2.new(0.5, 0.5)
		-- Centred on the SLOT's centre, expressed in the half's own space: the
		-- half is half a slot wide and a whole slot tall.
		dark.Position = UDim2.fromScale(atLocalX, 0.5)
		dark.Size = UDim2.fromScale(2, 1)
		dark.BackgroundColor3 = SCRIM
		dark.BackgroundTransparency = SLOT.scrimTransparency
		dark.BorderSizePixel = 0
		dark.ZIndex = 3
		dark.Parent = parent
		corner(dark, px(SLOT.cornerRadius))

		local a = if opaqueFirst then 0 else 1
		local b = if opaqueFirst then 1 else 0
		local gradient = Instance.new("UIGradient")
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, a),
			NumberSequenceKeypoint.new(0.4999, a),
			NumberSequenceKeypoint.new(0.5, b),
			NumberSequenceKeypoint.new(1, b),
		})
		gradient.Rotation = 0
		gradient.Parent = dark
		return gradient
	end

	-- Right half: dark to the RIGHT of the boundary at rotation zero, so it
	-- starts full and empties as the line swings from twelve round to six.
	local sweepRightGradient = halfPlane(sweepRight, 0, false)
	-- Left half: dark to the LEFT at rotation zero, emptying from six to twelve.
	local sweepLeftGradient = halfPlane(sweepLeft, 1, true)

	-- The drain this replaces, kept beneath the switch so the wedge can be
	-- turned off without a revert. Only one of the two is ever visible.
	local sweep = Instance.new("Frame")
	sweep.AnchorPoint = Vector2.new(0, 1)
	sweep.Position = UDim2.fromScale(0, 1)
	sweep.Size = UDim2.fromScale(1, 0)
	sweep.BackgroundColor3 = SCRIM
	sweep.BackgroundTransparency = SLOT.scrimTransparency
	sweep.BorderSizePixel = 0
	sweep.ZIndex = 3
	sweep.Visible = not SLOT.radialSweep
	sweep.Parent = root
	corner(sweep, px(SLOT.cornerRadius))
	sweepLeft.Visible = SLOT.radialSweep
	sweepRight.Visible = SLOT.radialSweep

	--[[ The global cooldown is a different fact from a technique cooldown: it
		hits every slot at once and is always brief. So it draws as a thin bar
		sweeping across the bottom rather than as a second scrim, and the two are
		never confusable. ]]
	local gcd = Instance.new("Frame")
	gcd.AnchorPoint = Vector2.new(0, 1)
	gcd.Position = UDim2.fromScale(0, 1)
	gcd.Size = UDim2.fromOffset(0, px(SLOT.gcdBarHeight))
	gcd.BackgroundColor3 = READY
	gcd.BackgroundTransparency = 0.25
	gcd.BorderSizePixel = 0
	gcd.ZIndex = 5
	gcd.Visible = false
	gcd.Parent = root

	local key = caption(root, text(SLOT.keyTextSize), KEYBIND, true)
	key.Size = UDim2.fromOffset(px(16), px(14))
	key.Position = UDim2.fromOffset(px(4), px(3))
	key.ZIndex = 4
	key.Text = if showKeyGlyphs then (KEY_GLYPHS[index] or tostring(index)) else ""

	local name = caption(root, text(SLOT.nameTextSize), TEXT, true)
	name.Size = UDim2.new(1, -px(6), 0, px(14))
	name.Position = UDim2.fromOffset(px(4), px(20))
	name.TextXAlignment = Enum.TextXAlignment.Center
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.ZIndex = 4
	name.Text = "--"

	local cost = caption(root, text(SLOT.costTextSize), AURA, false)
	cost.Size = UDim2.new(1, -px(6), 0, px(12))
	cost.Position = UDim2.fromOffset(px(4), px(34))
	cost.TextXAlignment = Enum.TextXAlignment.Center
	cost.ZIndex = 4

	--[[ The swap affordance. A player who is never told a slot can be changed
		will conclude every character in this game is the same one -- which is
		the exact opposite of what a shared pool of twelve techniques across four
		slots is for. A dim glyph in the corner is the cheapest possible way to
		say "this is a thing, not a label". ]]
	local swap = caption(root, text(SLOT.keyTextSize) - 1, TEXT_FAINT, true)
	swap.Size = UDim2.fromOffset(px(14), px(12))
	swap.Position = UDim2.new(1, -px(16), 0, px(4))
	swap.TextXAlignment = Enum.TextXAlignment.Right

	--[[ The reach pip, in the corner opposite the swap glyph so it reads as part
		of the slot rather than as something added to it. Filled when this
		technique has something to touch, hollow when it does not, and hidden
		entirely for kinds whose reach cannot fail. ]]
	local reach = Instance.new("Frame")
	reach.AnchorPoint = Vector2.new(1, 1)
	reach.Position = UDim2.new(1, -px(5), 1, -px(SLOT.stripeHeight) - px(4))
	reach.Size = UDim2.fromOffset(px(SLOT.reachPip), px(SLOT.reachPip))
	reach.BorderSizePixel = 0
	reach.BackgroundColor3 = TEXT
	reach.ZIndex = 4
	reach.Visible = false
	reach.Parent = root
	corner(reach, px(SLOT.reachPip))
	local reachStroke = outline(reach, TEXT, 1)
	reachStroke.Transparency = 0.35
	swap.ZIndex = 4
	swap.Text = "\u{21C4}"

	local countdown = caption(root, text(SLOT.countdownTextSize), TEXT, true)
	countdown.Size = UDim2.fromScale(1, 1)
	countdown.TextXAlignment = Enum.TextXAlignment.Center
	countdown.ZIndex = 6
	local countdownStroke = outline(countdown, BLACK, 2)
	countdownStroke.Transparency = 0.2
	countdownStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual

	slotWidgets[index] = {
		root = root,
		key = key,
		name = name,
		cost = cost,
		countdown = countdown,
		reach = reach,
		sweep = sweep,
		sweepLeft = sweepLeftGradient,
		sweepRight = sweepRightGradient,
		gcd = gcd,
		stripe = stripe,
		stroke = stroke,
		slot = slotNames[index],
	}
end

--[[ The refinement rail, at the very bottom edge of the screen.

	Demoted out of the combat cluster on purpose. Refinement moves over hours;
	health and aura move over frames. Interleaving them puts a bar that never
	visibly changes between two that change constantly, which teaches the eye to
	skip the whole region. Ambient is the correct register for it -- always
	available, never competing. ]]
local progressUi: { railFill: Frame, promptFrame: Frame, promptLabel: TextLabel }
do
	local railHeight = px(InterfaceSpec.Rail.height)
	local rail = Instance.new("Frame")
	rail.Name = "RefinementRail"
	rail.AnchorPoint = Vector2.new(0.5, 1)
	rail.Position = UDim2.fromScale(0.5, 1)
	rail.Size = UDim2.new(1, 0, 0, railHeight)
	rail.BackgroundColor3 = TROUGH
	rail.BackgroundTransparency = 0.3
	rail.BorderSizePixel = 0
	rail.Parent = screen

	local railFill = Instance.new("Frame")
	railFill.Size = UDim2.fromScale(0, 1)
	railFill.BackgroundColor3 = REFINEMENT
	railFill.BorderSizePixel = 0
	railFill.Parent = rail

	--[[ The breakthrough prompt. Hidden until the ceiling is actually reached,
		which is the progressive-disclosure rule applied to the loudest thing the
		interface ever needs to say. ]]
	local promptFrame = Instance.new("Frame")
	promptFrame.Name = "BreakthroughPrompt"
	promptFrame.AnchorPoint = Vector2.new(0.5, 1)
	promptFrame.Position = UDim2.new(0.5, 0, 1, -(px(SLOT.bottomMargin) + clusterHeight + px(8)))
	promptFrame.Size = UDim2.fromOffset(px(320), px(24))
	promptFrame.BackgroundColor3 = PANEL
	promptFrame.BackgroundTransparency = 0.15
	promptFrame.BorderSizePixel = 0
	promptFrame.Visible = false
	promptFrame.Parent = screen
	corner(promptFrame, 3)
	outline(promptFrame, CEILING, 1).Transparency = 0.4

	local promptLabel = caption(promptFrame, text(12), CEILING, true)
	promptLabel.Size = UDim2.fromScale(1, 1)
	promptLabel.TextXAlignment = Enum.TextXAlignment.Center
	progressUi = { railFill = railFill, promptFrame = promptFrame, promptLabel = promptLabel }
end

-- ===================================================================
-- The target frame: the right half of the pair.
-- ===================================================================

--[[ There is no targeting system in this game. The striker raycasts along the
	camera, so "target" here means *whoever you are currently aiming at*,
	resolved client-side by mirroring the server's own ray and held briefly so
	the frame does not strobe as the reticle drifts off a moving opponent.

	Presentation only: this claims nothing, sends nothing and changes no
	outcome. It is a readout of an aim the player is already making.

	It is the vitals block's twin: the same width, the same rows at the same
	heights, built from the same `bar` and `caption`, sitting to the right of
	the vitals across the cluster's centre line. Your half says who you are;
	this half says who you are looking at, in the same shape, so the eye that
	has learned to read one has already learned to read the other. Where your
	header has stage and power, theirs has name and stage; where your second
	bar is aura, theirs is the row their cast runs in -- and when nothing is
	running it carries the one line about the fight: the bracket relation, or
	that they are neutral and will not start one.

	Always present. With no target the half rests -- same silhouette, dimmed,
	troughs empty, "no target" where the name goes -- because a pair that only
	sometimes has a right half reads as a bug the first time it vanishes.

	Nothing is a box here, because the vitals are not a box. The lock still
	draws its border, and a refused bracket its red one, as the only strokes
	the pair ever shows: a border on the right half is a fact about the target
	and never decoration. ]]
local targetUi: {
	frame: Frame,
	stroke: UIStroke,
	nameLabel: TextLabel,
	stageLabel: TextLabel,
	healthFill: Frame,
	healthValue: TextLabel,
	troughs: { Frame },
	castFill: Frame,
	castName: TextLabel,
	castTimer: TextLabel,
	lockTag: TextLabel,
	relation: TextLabel,
}
do
	local targetFrame = Instance.new("Frame")
	targetFrame.Name = "TargetFrame"
	targetFrame.AnchorPoint = Vector2.new(0, 0)
	targetFrame.Position = UDim2.new(0.5, pairGap / 2, 0, 0)
	targetFrame.Size = UDim2.fromOffset(vitalsWidth, vitalsHeight)
	targetFrame.BackgroundTransparency = 1
	targetFrame.Parent = cluster
	local targetStroke = outline(targetFrame, EDGE, px(TARGET.borderThickness))
	targetStroke.Transparency = 1

	-- Header row: their name where your stage is, their stage where your
	-- power is. The name takes the stage's colour, as it does on the plate.
	local targetName = caption(targetFrame, text(TARGET.nameTextSize), TEXT, true)
	targetName.Size = UDim2.new(0.6, 0, 0, headerHeight)
	targetName.TextTruncate = Enum.TextTruncate.AtEnd

	local targetStage = caption(targetFrame, text(TARGET.stageTextSize), TEXT_DIM, true)
	targetStage.Size = UDim2.new(0.4, 0, 0, headerHeight)
	targetStage.Position = UDim2.fromScale(0.6, 0)
	targetStage.TextXAlignment = Enum.TextXAlignment.Right

	--[[ Says "LOCKED" between the name and the stage when the frame is showing
		a lock rather than the aim, so the two idioms are told apart by a word
		and a border rather than left to be inferred. ]]
	local targetLockTag = caption(targetFrame, text(TARGET.stageTextSize), LOCK, true)
	targetLockTag.Size = UDim2.fromOffset(px(56), headerHeight)
	targetLockTag.Position = UDim2.new(0.6, -px(56), 0, 0)
	targetLockTag.TextXAlignment = Enum.TextXAlignment.Right
	targetLockTag.Text = "LOCKED"
	targetLockTag.Visible = false

	-- Health row: the health bar is the health bar.
	local targetHealthRow = Instance.new("Frame")
	targetHealthRow.Size = UDim2.new(1, 0, 0, healthHeight)
	targetHealthRow.Position = UDim2.fromOffset(0, headerHeight)
	targetHealthRow.BackgroundTransparency = 1
	targetHealthRow.Parent = targetFrame
	local targetHealthBack, targetHealthFill = bar(targetHealthRow, healthHeight, HEALTH)

	local targetHealthValue = caption(targetHealthRow, text(TARGET.valueTextSize), TEXT, true)
	targetHealthValue.Size = UDim2.new(1, -px(6), 1, 0)
	targetHealthValue.Position = UDim2.fromOffset(px(6), 0)
	targetHealthValue.TextXAlignment = Enum.TextXAlignment.Right
	targetHealthValue.ZIndex = 3

	--[[ Second row, in the aura slot. Their cast runs here -- the whole
		reason this frame first existed: an opponent's windup was, until it
		did, completely invisible, so a 1.8s Tempest arrived instantaneously
		from the defender's side. A cast and the relation line share the row
		and the cast wins it: what they are about to do outranks what the
		fight is, the same precedence the plate uses. ]]
	local targetSecondRow = Instance.new("Frame")
	targetSecondRow.Size = UDim2.new(1, 0, 0, auraHeight)
	targetSecondRow.Position = UDim2.fromOffset(0, headerHeight + healthHeight + rowGap)
	targetSecondRow.BackgroundTransparency = 1
	targetSecondRow.Parent = targetFrame
	local targetCastBack, targetCastFill = bar(targetSecondRow, auraHeight, READY)
	targetCastFill.Size = UDim2.fromScale(0, 1)

	local rowText = text(TARGET.valueTextSize) - 1
	local targetCastName = caption(targetSecondRow, rowText, TEXT, true)
	targetCastName.Size = UDim2.new(1, -px(12), 1, 0)
	targetCastName.Position = UDim2.fromOffset(px(6), 0)
	targetCastName.ZIndex = 3

	local targetCastTimer = caption(targetSecondRow, rowText, TEXT, true)
	targetCastTimer.Size = UDim2.new(1, -px(12), 1, 0)
	targetCastTimer.Position = UDim2.fromOffset(px(6), 0)
	targetCastTimer.TextXAlignment = Enum.TextXAlignment.Right
	targetCastTimer.ZIndex = 3

	--[[ The line about the fight. `Combat.canEngage` refuses cross-stage
		fights outright under "refuse", and until this line a player discovered
		that by attacking someone and having nothing whatsoever happen --
		indistinguishable from a miss, from lag, or from a broken button.
		Saying it on the frame turns a mystery into a rule. Under "notice" it
		says the true thing instead, and for a neutral it says what they are. ]]
	local targetRelation = caption(targetSecondRow, rowText, TEXT_DIM, true)
	targetRelation.Size = UDim2.new(1, -px(12), 1, 0)
	targetRelation.Position = UDim2.fromOffset(px(6), 0)
	targetRelation.TextTruncate = Enum.TextTruncate.AtEnd
	targetRelation.ZIndex = 3
	targetRelation.Visible = false

	targetUi = {
		frame = targetFrame,
		stroke = targetStroke,
		nameLabel = targetName,
		stageLabel = targetStage,
		healthFill = targetHealthFill,
		healthValue = targetHealthValue,
		troughs = { targetHealthBack, targetCastBack },
		castFill = targetCastFill,
		castName = targetCastName,
		castTimer = targetCastTimer,
		lockTag = targetLockTag,
		relation = targetRelation,
	}
end

-- ===================================================================
-- Sense tracker, top right. Out-of-combat navigation, so it lives at an edge.
-- ===================================================================

local SENSE = InterfaceSpec.Sense
local senseUi: { rows: { TextLabel }, foot: TextLabel }
do
	local senseWidth = px(SENSE.width)
	local senseRowHeight = px(SENSE.rowHeight)

	local sensePanel = Instance.new("Frame")
	sensePanel.Name = "Sense"
	sensePanel.AnchorPoint = Vector2.new(0, 0.5)
	sensePanel.Position = UDim2.new(0, px(SENSE.side), 0.5, 0)
	local senseRowsTop = px(18) + px(SENSE.columnHeight)
	sensePanel.Size =
		UDim2.fromOffset(senseWidth, senseRowsTop + senseRowHeight * SENSE.rows + px(16))
	sensePanel.BackgroundColor3 = PANEL
	sensePanel.BackgroundTransparency = 0.25
	sensePanel.BorderSizePixel = 0
	sensePanel.Parent = screen
	corner(sensePanel, 3)

	local senseHeader = caption(sensePanel, text(SENSE.headerTextSize), TEXT_FAINT, true)
	senseHeader.Size = UDim2.new(1, -px(16), 0, px(16))
	senseHeader.Position = UDim2.fromOffset(px(8), px(2))
	senseHeader.Text = "AURA SENSE"

	--[[ Column names, in the same monospaced font and the same format string as the
		rows, so the labels sit over the columns they describe rather than merely
		near them. Dimmer than the rows: it is read once and then never again. ]]
	local senseColumns = caption(sensePanel, text(SENSE.columnTextSize), TEXT_FAINT, false)
	senseColumns.Size = UDim2.new(1, -px(16), 0, px(SENSE.columnHeight))
	senseColumns.Position = UDim2.fromOffset(px(8), px(18))
	senseColumns.Font = Enum.Font.RobotoMono
	senseColumns.Text = string.format("%s %-6s %4s  %s  %s", " ", "aura", "away", "held", "drain")

	local senseRows: { TextLabel } = {}
	for index = 1, SENSE.rows do
		local row = caption(sensePanel, text(SENSE.rowTextSize), TEXT_DIM, false)
		row.Size = UDim2.new(1, -px(16), 0, senseRowHeight)
		row.Position = UDim2.fromOffset(px(8), senseRowsTop + (index - 1) * senseRowHeight)
		row.Font = Enum.Font.RobotoMono
		senseRows[index] = row
	end

	local senseFoot = caption(sensePanel, text(SENSE.footTextSize), TEXT_FAINT, false)
	senseFoot.Size = UDim2.new(1, -px(16), 0, px(14))
	senseFoot.Position = UDim2.fromOffset(px(8), senseRowsTop + senseRowHeight * SENSE.rows)
	senseUi = { rows = senseRows, foot = senseFoot }
end

-- ===================================================================
-- Notices, top centre. The band the target frame left when it joined the pair.
-- ===================================================================

local NOTICE = InterfaceSpec.Notice

local noticeUi: { frame: Frame, label: TextLabel }
do
	local noticeFrame = Instance.new("Frame")
	noticeFrame.Name = "Notice"
	noticeFrame.AnchorPoint = Vector2.new(0.5, 0)
	noticeFrame.Position = UDim2.new(0.5, 0, 0, px(NOTICE.top))
	--[[ The notice grows to fit rather than clipping.

		It was a fixed 460x26 with a single unwrapped line, which was fine while
		every notice was a short authored sentence. The kill and death copy makes
		that unsafe: a death line carries a player's name *and* the refinement
		number, at 1.34x weight, and a long display name pushes it past the width
		with no wrap and no truncation -- so the one message the player most needs to
		read is the one that would have run off the panel.

		Wrapped, with the frame sized from its contents. The longest realistic death
		line takes two rows and the panel grows by one row to hold it; every ordinary
		notice is unchanged, because one line still measures as one line. ]]
	noticeFrame.Size = UDim2.fromOffset(px(NOTICE.width), 0)
	noticeFrame.AutomaticSize = Enum.AutomaticSize.Y
	noticeFrame.BackgroundColor3 = PANEL
	noticeFrame.BackgroundTransparency = 0.2
	noticeFrame.BorderSizePixel = 0
	noticeFrame.Visible = false
	noticeFrame.Parent = screen
	corner(noticeFrame, 3)

	local noticePadding = Instance.new("UIPadding")
	noticePadding.PaddingTop = UDim.new(0, px(5))
	noticePadding.PaddingBottom = UDim.new(0, px(5))
	noticePadding.PaddingLeft = UDim.new(0, px(10))
	noticePadding.PaddingRight = UDim.new(0, px(10))
	noticePadding.Parent = noticeFrame

	local noticeLabel = caption(noticeFrame, text(NOTICE.textSize), CEILING, true)
	noticeLabel.Size = UDim2.fromScale(1, 0)
	noticeLabel.AutomaticSize = Enum.AutomaticSize.Y
	noticeLabel.TextWrapped = true
	noticeLabel.TextXAlignment = Enum.TextXAlignment.Center
	noticeUi = { frame = noticeFrame, label = noticeLabel }
end

-- ===================================================================
-- Guidance: the one line that says what to do next.
-- ===================================================================

--[[ Every other piece of text in this file is a state *readout* -- stage, tier,
	power, health, aura, a list of distant dots. None of it tells a player who
	has never seen this game what to actually do, and a tier now rolls over in
	two minutes, which is worth nothing at all if nobody knows to stand in the
	node.

	So: one quiet line, always on screen, answering "what should I be doing right
	now" and changing as that answer changes. Not a popup, not a modal, nothing
	to dismiss. It sits directly above the cluster in the dim weight, so it reads
	as an aside rather than as an alert -- the loud registers are already spoken
	for by notices and by the breakthrough prompt, and guidance that shouts
	competes with the two things that have earned the right to.

	The voice is the one `Config.RegionNames` and the announcement copy already
	use: spare, declarative, present tense. This game says "surfaced in the Ember
	Barrens", not "A rare node has spawned!". ]]
local GUIDANCE = InterfaceSpec.Guidance
local cardUi: { guidance: TextLabel, dismiss: () -> (), show: () -> () }
do
	local guidanceLabel = caption(screen, text(GUIDANCE.textSize), TEXT_DIM, false)
	guidanceLabel.Name = "Guidance"
	guidanceLabel.AnchorPoint = Vector2.new(0.5, 1)
	guidanceLabel.Position =
		UDim2.new(0.5, 0, 1, -(px(SLOT.bottomMargin) + clusterHeight + px(GUIDANCE.gap)))
	guidanceLabel.Size = UDim2.fromOffset(px(GUIDANCE.width), px(GUIDANCE.height))
	guidanceLabel.TextXAlignment = Enum.TextXAlignment.Center

	--[[ The first-run card.

		Shown once, on spawn, and gone twelve seconds later or on the first input --
		whichever comes first, because a player who has already started doing things
		does not need to be told to start doing things.

		Three lines, and the third is the one doing real work: four friends who are
		not told they are rivals will very plausibly spend an hour cooperating
		politely, and we will learn nothing about the PvP this entire game is built
		on. Stage and the key range are read from live state rather than hardcoded,
		so the card stays true if either changes. ]]
	local cardFrame = Instance.new("Frame")
	cardFrame.Name = "FirstRunCard"
	cardFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	cardFrame.Position = UDim2.fromScale(0.5, 0.34)
	cardFrame.Size = UDim2.fromOffset(px(468), px(120))
	cardFrame.BackgroundColor3 = PANEL
	cardFrame.BackgroundTransparency = 0.18
	cardFrame.BorderSizePixel = 0
	cardFrame.Visible = false
	cardFrame.Parent = screen
	corner(cardFrame, 4)
	local cardStroke = outline(cardFrame, EDGE, 1)
	cardStroke.Transparency = 0.4

	local cardLines: { TextLabel } = {}
	for index = 1, 4 do
		local line = caption(cardFrame, text(if index == 1 then 15 else 13), TEXT, index == 1)
		line.Size = UDim2.new(1, -px(24), 0, px(22))
		line.Position = UDim2.fromOffset(px(12), px(14) + (index - 1) * px(24))
		line.TextXAlignment = Enum.TextXAlignment.Center
		line.TextColor3 = if index == 1 then TEXT else TEXT_DIM
		cardLines[index] = line
	end

	local cardDismissed = false

	local function dismissCard()
		if cardDismissed or not cardFrame.Visible then
			return
		end
		cardDismissed = true
		-- Faded rather than cut, so it reads as receding rather than as a glitch.
		task.spawn(function()
			local steps = 18
			for step = 1, steps do
				local t = step / steps
				cardFrame.BackgroundTransparency = 0.18 + 0.82 * t
				cardStroke.Transparency = 0.4 + 0.6 * t
				for _, line in cardLines do
					line.TextTransparency = t
				end
				task.wait(0.03)
			end
			cardFrame.Visible = false
		end)
	end

	local function showCard()
		if cardDismissed then
			return
		end
		local stage = player:GetAttribute("Stage")
		cardLines[1].Text = if typeof(stage) == "string"
			then `You are a {stage} cultivator.`
			else "You are a cultivator."
		cardLines[2].Text =
			`Stand inside an aura node to cycle. Keys 1-{slotCount} are your techniques.`
		cardLines[3].Text = "Hold Shift and a technique key to swap it. The kit is yours to choose."
		cardLines[4].Text = "Every cultivator at your stage is a rival. There is no safe ground."
		cardFrame.Visible = true
		task.delay(12, dismissCard)
	end
	cardUi = { guidance = guidanceLabel, dismiss = dismissCard, show = showCard }
end

-- ===================================================================
-- State refresh.
-- ===================================================================

--[[ Stops to a sequence, at the edge where Roblox types begin. ]]
local function sequenceOf(stops: { InterfaceSpec.VesselStop }): ColorSequence
	local keypoints = {}
	for _, stop in stops do
		table.insert(keypoints, ColorSequenceKeypoint.new(stop.at, color(stop.color)))
	end
	return ColorSequence.new(keypoints)
end

--[[ A typed record off the player's attributes, or nil if the server has not
	published that prefix at all -- which is how the client tells "an empty
	vessel" from "no vessel yet". ]]
local function auraRecord(prefix: string, order: { string }): { [string]: number }?
	local record = {}
	local any = false
	for _, key in order do
		local amount = player:GetAttribute(prefix .. key)
		if typeof(amount) == "number" then
			record[key] = amount
			any = true
		end
	end
	return if any then record else nil
end

local function refreshCultivation()
	local stage = player:GetAttribute("Stage") or "--"
	local tier = player:GetAttribute("Tier") or 0
	local progress = player:GetAttribute("Progress") or 0
	local goal = player:GetAttribute("TierGoal") or 1
	local catalysts = player:GetAttribute("Catalysts") or 0
	local power = player:GetAttribute("Power") or 0
	local atCeiling = player:GetAttribute("AtCeiling") == true
	local stageIndex = player:GetAttribute("StageIndex")

	--[[ The headline: stage, tier, and -- once there is a core -- its dominant
		aura in that aura's colour. The chip shows the mix; the word says what
		it mostly is, for the reader who has time to read. Neutral never
		heads a core, by design. ]]
	local core = auraRecord("Core_", InterfaceSpec.Vessel.order)
	local dominant = if core
		then InterfaceSpec.dominantAura(core, InterfaceSpec.Vessel.order)
		else nil
	local headline = `{stage}  ·  {tier}`
	if dominant then
		local rgb = AURA_COLORS[dominant]
		local auraName = (Config.AuraTypes :: { [string]: any })[dominant].name
		headline ..= `  <font color="rgb({rgb.r},{rgb.g},{rgb.b})">·  {string.lower(auraName)}</font>`
	end
	vitalsUi.stageLabel.Text = headline
	if typeof(stageIndex) == "number" then
		vitalsUi.stageLabel.TextColor3 = color(InterfaceSpec.stageColor(stageIndex))
	end

	vitalsUi.powerLabel.Text = if catalysts > 0
		then `power {power}   ◆{catalysts}`
		else `power {power}`

	progressUi.railFill.Size = UDim2.fromScale(InterfaceSpec.fraction(progress, goal), 1)
	progressUi.railFill.BackgroundColor3 = if atCeiling then CEILING else REFINEMENT

	--[[ The prompt is now *only* the actionable case. The ceiling-without-a-
		catalyst message moved to the guidance line below, because two surfaces
		saying the same thing in different words is worse than either alone --
		and because "you cannot act yet" is guidance, while "[B]" is a command. ]]
	progressUi.promptFrame.Visible = atCeiling and catalysts > 0
	if progressUi.promptFrame.Visible then
		progressUi.promptLabel.Text = "[B]  BREAK THROUGH"
	end
end

local function refreshVitals()
	local health = player:GetAttribute("Health") or 0
	local maxHealth = player:GetAttribute("MaxHealth") or 0
	local aura = player:GetAttribute("Aura") or 0
	local auraCapacity = player:GetAttribute("MaxAura") or 0

	--[[ The vessel, once published, is the pool: its typed amounts sum to what
		the blue bar showed, and its capacity is the vessel's. Until then the
		plain pool draws as it always did, so the bar is never empty for want
		of a newer attribute. ]]
	local vessel = auraRecord("Vessel_", InterfaceSpec.Vessel.vesselOrder)
	local vesselCapacity = player:GetAttribute("VesselCapacity")
	if vessel and typeof(vesselCapacity) == "number" then
		aura = 0
		for _, amount in vessel do
			aura += amount
		end
		auraCapacity = vesselCapacity
	end
	local stops = if vessel
		then InterfaceSpec.vesselStops(vessel, InterfaceSpec.Vessel.vesselOrder, AURA_COLORS)
		else {}
	if #stops > 0 then
		vitalsUi.auraGradient.Color = sequenceOf(stops)
		vitalsUi.auraGradient.Enabled = true
		vitalsUi.auraFill.BackgroundColor3 = Color3.new(1, 1, 1)
	else
		vitalsUi.auraGradient.Enabled = false
		vitalsUi.auraFill.BackgroundColor3 = AURA
	end

	-- The core chip: filled by composition, hollow until there is one.
	local core = auraRecord("Core_", InterfaceSpec.Vessel.order)
	local coreStops = if core
		then InterfaceSpec.vesselStops(core, InterfaceSpec.Vessel.order, AURA_COLORS)
		else {}
	if #coreStops > 0 then
		vitalsUi.coreGradient.Color = sequenceOf(coreStops)
		vitalsUi.coreGradient.Enabled = true
		vitalsUi.coreChip.BackgroundTransparency = 0
		vitalsUi.coreRing.Transparency = 1
	else
		vitalsUi.coreGradient.Enabled = false
		vitalsUi.coreChip.BackgroundTransparency = 1
		vitalsUi.coreRing.Transparency = 0
	end

	local healthFraction = InterfaceSpec.fraction(health, maxHealth)
	vitalsUi.healthFill.Size = UDim2.fromScale(healthFraction, 1)
	vitalsUi.healthFill.BackgroundColor3 = if healthFraction <= VITALS.lowHealthFraction
		then HEALTH_LOW
		else HEALTH
	vitalsUi.healthValue.Text = `{InterfaceSpec.commas(health)} / {InterfaceSpec.commas(maxHealth)}`

	vitalsUi.auraFill.Size = UDim2.fromScale(InterfaceSpec.fraction(aura, auraCapacity), 1)
	vitalsUi.auraValue.Text = `{InterfaceSpec.commas(aura)} / {InterfaceSpec.commas(auraCapacity)}`

	local slow = player:GetAttribute("SlowMultiplier")
	local slowed = typeof(slow) == "number" and slow < 1
	vitalsUi.slowChip.Visible = slowed
	vitalsUi.powerLabel.Visible = not slowed
	if slowed then
		vitalsUi.slowChip.Text = if InterfaceSpec.Status.showMultiplier
			then string.format("SLOWED  ×%.1f", slow)
			else "SLOWED"
	end
end

--[[ Locally predicted cooldowns. The server still owns every refusal; this only
	lets a press explain itself, and a desynced prediction costs a wasted
	keypress rather than a wrong outcome. ]]
--[[ Soft-target state, declared here rather than beside the targeting code that
	maintains it, because the slot bar reads it too: a striker slot's reach pip
	and the reticle are answers to the same question and must not be able to
	disagree. Maintained by `pollTarget` further down.

	`aimOnTarget` is whether the ray is on a player *right now*, as against the
	sticky target the frame holds for a few seconds. Both the reticle and the pip
	want the live answer -- either of them staying lit three seconds after you
	looked away would be promising a shot you no longer have. ]]
local currentTarget: Nameplates.Combatant? = nil
local aimOnTarget = false

--[[ The lock: a promotion of the soft target, never a replacement for it.

	This game aims by camera, and every existing technique keeps doing so -- the
	reticle keeps meaning "where the ray goes" and the soft target keeps being
	whoever that ray would hit. A lock is what you get when you press the lock
	key with the reticle on someone: the same combatant, held until you release
	it, they die, or they stay out of reach long enough. Techniques that declare
	`targeting = "lock"` require one; everything else ignores it entirely.

	So the reticle stays honest in both idioms. For an aim technique it IS the
	aim; for a lock technique it is how you CHOSE the lock. Two idioms, each
	with its own readout, and neither has to lie. ]]
local lockedTarget: Nameplates.Combatant? = nil
local lockOutOfReachSince: number? = nil
-- Set once the aura helpers below are defined; unlock is needed before them.
local onUnlock: ((Nameplates.Combatant) -> ())? = nil

local function unlock()
	local released = lockedTarget
	lockedTarget = nil
	lockOutOfReachSince = nil
	if released and onUnlock then
		onUnlock(released)
	end
end

local cooldownUntil: { [string]: number } = {}
local gcdUntil = 0

local function slotTechnique(slot: string): Config.Technique?
	local techId = player:GetAttribute("Slot_" .. slot)
	if typeof(techId) ~= "string" then
		return nil
	end
	return Config.Techniques[techId]
end

--[[ Can a fight be had with this combatant -- the ONE answer every reader uses.

	Four things read the bracket: the reach pip's striker and ruler checks, the
	reticle's tint, and the target frame's line. When cross-bracket combat was
	opened behind the development profile, the server's one chokepoint learned
	the new rule and these four did not: the frame kept saying "neither of you
	can hit the other" over a hit that had just landed, and a player caught
	it. Same flag, second reader, missed -- the shape from the day before. So
	the four readers now call this, and this reads the flag.

	  "same"    same bracket -- always a fight.
	  "neutral" an NPC -- always a fight, in every mode. It has no bracket
	            relation to anyone; a practice target must not be refused.
	            Read off the Neutral attribute NpcService publishes, never
	            inferred from StageIndex, which an NPC also carries.
	  "open"    cross-bracket, and Config.Combat.crossBracket is "notice": the
	            fight can be had, and it is lopsided.
	  "refused" cross-bracket under "refuse": the server will not apply it.

	Config is replicated, so the client reads the same flag the chokepoint
	does. Presentation only; the server still decides. ]]
type FightRelation = "same" | "neutral" | "open" | "refused"

local function fightRelation(source: Instance): FightRelation
	if source:GetAttribute("Neutral") == true then
		return "neutral"
	end
	local ownStage = player:GetAttribute("StageIndex")
	local theirStage = source:GetAttribute("StageIndex")
	if
		typeof(ownStage) == "number"
		and typeof(theirStage) == "number"
		and ownStage == theirStage
	then
		return "same"
	end
	return if Config.Combat.crossBracket == "notice" then "open" else "refused"
end

local function canFight(source: Instance): boolean
	return fightRelation(source) ~= "refused"
end

--[[ Is anyone we are allowed to fight standing inside a radius around us.

	The ruler half of the reach question. Bracket is checked as well as distance,
	because `Combat.canEngage` refuses across stages -- a Truegold standing on
	your toes is not something your tempest can touch, and a pip that lit for
	them would be lying in the most expensive possible way.

	Client-side and presentational, like the cooldown prediction beside it: it
	decides what the slot *says*, never what the server does. A disagreement
	costs a misleading pip for a frame, never a wrong outcome. ]]
local function anyEngageableWithin(radius: number): boolean
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if not root or not root:IsA("BasePart") then
		return false
	end
	for _, other in Players:GetPlayers() do
		if other == player then
			continue
		end
		if not canFight(other) then
			continue
		end
		local health = other:GetAttribute("Health")
		if typeof(health) == "number" and health <= 0 then
			continue
		end
		local otherCharacter = other.Character
		local otherRoot = if otherCharacter
			then otherCharacter:FindFirstChild("HumanoidRootPart")
			else nil
		if otherRoot and otherRoot:IsA("BasePart") then
			if (otherRoot.Position - root.Position).Magnitude <= radius then
				return true
			end
		end
	end
	return false
end

--[[ Whether the aim ray is currently on someone we may fight. The striker half,
	and the same answer the reticle draws, computed once and read by both so the
	crosshair and the slot can never disagree about the same fact. ]]
local function strikerInReach(): boolean
	if not aimOnTarget or not currentTarget then
		return false
	end
	return canFight(currentTarget.source)
end

--[[ Drive the cooldown sweep from the fraction of cooldown REMAINING.

	The wedge covers the arc from the elapsed angle clockwise round to twelve.
	The right half handles the first half-turn, the left half the second: each
	gradient's rotation is the elapsed angle clamped to its own 180 degrees, so
	at a quarter elapsed the right half is a quarter open and the left is still
	full; at three quarters the right is empty and the left is half open. The
	drain beneath the switch reads the same fraction as a height. ]]
local function setSweep(widget: SlotWidget, remainingFraction: number)
	if SLOT.radialSweep then
		local elapsedDegrees = (1 - remainingFraction) * 360
		widget.sweepRight.Rotation = math.clamp(elapsedDegrees, 0, 180)
		widget.sweepLeft.Rotation = math.clamp(elapsedDegrees - 180, 0, 180)
	else
		widget.sweep.Size = UDim2.fromScale(1, remainingFraction)
	end
end

local function refreshSlots()
	local now = os.clock()
	local aura = player:GetAttribute("Aura") or 0
	local gcdRemaining = gcdUntil - now
	local gcdLength = Config.Combat.globalCooldown
	--[[ Resolved once per frame rather than per slot: a loadout can hold more
		than one ruler technique later, and walking the player list four times to
		answer the same question would be four times the work for one answer. ]]
	local rulerReach: boolean? = nil

	for _, widget in slotWidgets do
		local tech = slotTechnique(widget.slot)
		if not tech then
			widget.name.Text = "--"
			widget.cost.Text = ""
			widget.countdown.Text = ""
			setSweep(widget, 0)
			widget.gcd.Visible = false
			continue
		end

		widget.name.Text = tech.name
		widget.cost.Text = tostring(tech.auraCost)
		local kind = color(InterfaceSpec.kindColor(tech.kind))
		widget.stripe.BackgroundColor3 = kind

		local remaining = (cooldownUntil[tech.id] or 0) - now
		local affordable = aura >= tech.auraCost

		if remaining > 0 and tech.cooldown > 0 then
			setSweep(widget, math.clamp(remaining / tech.cooldown, 0, 1))
			widget.stroke.Color = COOLING
			widget.name.TextColor3 = TEXT_FAINT
			widget.cost.TextColor3 = TEXT_FAINT
			widget.stripe.BackgroundTransparency = 0.6
			widget.countdown.Text = if remaining >= SLOT.countdownMinSeconds
				then InterfaceSpec.countdown(remaining)
				else ""
		else
			setSweep(widget, 0)
			widget.countdown.Text = ""
			widget.stripe.BackgroundTransparency = 0
			widget.stroke.Color = if affordable then kind else UNAFFORDABLE
			widget.name.TextColor3 = if affordable then TEXT else UNAFFORDABLE
			widget.cost.TextColor3 = if affordable then AURA else UNAFFORDABLE
		end

		--[[ Reach. Only kinds whose reach can actually fail get a pip; for
			forger and enforcer its absence is the statement that reach does not
			apply, rather than an omission. ]]
		if InterfaceSpec.hasReach(tech.kind) then
			local inReach: boolean
			if tech.kind == "striker" then
				inReach = strikerInReach()
			else
				if rulerReach == nil then
					rulerReach = anyEngageableWithin(Config.Combat.ranges.ruler)
				end
				inReach = rulerReach == true
			end
			widget.reach.Visible = true
			-- Filled when there is something to touch, hollow when there is not.
			widget.reach.BackgroundTransparency = if inReach then 0 else 1
		else
			widget.reach.Visible = false
		end

		if gcdRemaining > 0 and gcdLength > 0 then
			widget.gcd.Visible = true
			widget.gcd.Size =
				UDim2.new(math.clamp(gcdRemaining / gcdLength, 0, 1), 0, 0, px(SLOT.gcdBarHeight))
		else
			widget.gcd.Visible = false
		end
	end
end

--[[ Prediction starts from the server's confirmation of our own cast, not from
	the keypress. A refused press therefore never puts a slot on a cooldown it
	did not pay for. Kept exactly as the previous HUD had it, because it was
	right. ]]
local function noteOwnCast(techId: string)
	local tech = Config.Techniques[techId]
	if not tech then
		return
	end
	local now = os.clock()
	cooldownUntil[techId] = now + tech.cooldown
	gcdUntil = now + Config.Combat.globalCooldown
end

--[[ Movement prediction.

	A server-set WalkSpeed does not reach the player instantly. The client owns
	and simulates its own character, so a server write has to replicate down
	before the character actually moves faster -- 50 to 150ms on a real
	connection. Against Lunge, which is 80 speed for 0.25s, that is not a detail:
	up to sixty percent of the pulse can be gone before it starts, and the part
	a player feels most -- the instant answer to their own keypress -- is exactly
	the part latency eats. It would read as a slippery floor rather than a juke,
	and a tester would honestly report that the burst does not work when the
	truth is that the plumbing does not.

	So the client writes the speed the instant the key goes down, and stops
	waiting for permission to *start* moving. It is not a second authority. It
	reads `moveSpeed` and `buffDuration` from the same Config the server charges
	from, exactly as the cooldown prediction reads `auraCost` and `cooldown`,
	and it holds no copy of anything.

	The seam, named explicitly rather than discovered:

	  - The client writes WalkSpeed ONCE, on press, behind the same local gate
	    the windup effect uses. It never writes position, never writes a buff,
	    never tells the server anything it does not already send.
	  - The server applies the real speed, owns the real duration, and its
	    expiry write is what ends the effect. A client write does not replicate
	    up; a server write does replicate down. The asymmetry runs the right way.
	  - On `CastStarted` for our own cast of this technique, the client CANCELS
	    its revert and never touches the property again. From there the server
	    owns it.
	  - If no confirmation arrives within windup plus a grace, the client
	    reverts to base speed. The refused-press case, and the same shape as
	    `Vfx.clearCharge` collapsing an unconfirmed charge.

	The client deliberately does NOT restore itself at `buffDuration` on the
	confirmed path, and Lunge is the reason. At 0.25s, a slow enough connection
	lands the server's replicated 80 *after* a client self-restore -- and the
	character goes 80, 16, 80, 16: a double pulse from a mechanic whose entire
	value is feeling like one clean juke. Leaving the server's restore as the
	only restore makes the burst *longer* by one latency on a bad link instead,
	which still reads as a dash. Long beats double. That is a property of any
	client prediction of a sub-second burst, not of this one, and it is why the
	burst has to be measured in the published place: on loopback neither case
	ever occurs.

	What this grants a cheater: nothing. Roblox gives the client its own
	character, so a modified client can already set its own WalkSpeed to
	anything it likes, today. The trade is entirely about honest clients' feel,
	and a desync costs a brief wrong speed rather than a wrong outcome. ]]
local MOVE_CONFIRM_GRACE = 0.3

local pendingMove: { techId: string, token: number }? = nil
local moveToken = 0

local function ownHumanoid(): Humanoid?
	local character = player.Character
	return if character then character:FindFirstChildOfClass("Humanoid") else nil
end

local function predictMovement(tech: Config.Technique)
	if tech.moveSpeed <= 0 then
		return
	end
	local humanoid = ownHumanoid()
	if not humanoid then
		return
	end

	moveToken += 1
	local token = moveToken
	pendingMove = { techId = tech.id, token = token }
	humanoid.WalkSpeed = tech.moveSpeed

	task.delay(tech.windup + MOVE_CONFIRM_GRACE, function()
		-- Still pending means the server never confirmed this press.
		if pendingMove and pendingMove.token == token then
			pendingMove = nil
			local current = ownHumanoid()
			--[[ Revert only if the speed is still the one we wrote. If the
				server has written anything since -- a slow landing in this
				window, a different buff -- that value is the truth and ours
				is stale; writing base over a server slow would hand the client
				a frame of speed it has no right to. Named before the slow
				existed so it was not discovered as "slows sometimes do not
				apply". ]]
			if current and current.WalkSpeed == tech.moveSpeed then
				current.WalkSpeed = Config.Combat.baseWalkSpeed
			end
		end
	end)
end

--[[ The server confirmed our cast: hand the property over and stop caring.
	Matched on technique rather than merely on caster, so a spammed second key
	cannot confirm the first. ]]
local function confirmMovement(techId: string)
	if pendingMove and pendingMove.techId == techId then
		pendingMove = nil
	end
end

-- ===================================================================
-- Soft targeting.
-- ===================================================================

local targetSeenAt = 0
local lastPoll = 0

--[[ Mirrors `CombatService.resolveStriker` deliberately: the ray starts at the
	root and runs along the camera's look vector for the striker's range. Using
	the camera's *position* instead would be easier to aim and would lie -- the
	frame would say you are on someone the shot will miss. ]]
local function pollTarget()
	local now = os.clock()
	local character = player.Character
	local camera = Workspace.CurrentCamera
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if not camera or not root or not root:IsA("BasePart") then
		return
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character :: Instance }

	local hit = Workspace:Raycast(
		root.Position,
		camera.CFrame.LookVector * Config.Combat.ranges.striker,
		params
	)
	local found = if hit then Nameplates.combatantFromInstance(hit.Instance) else nil
	aimOnTarget = found ~= nil
	if found then
		currentTarget = found
		targetSeenAt = now
	elseif currentTarget and now - targetSeenAt > TARGET.stickySeconds then
		currentTarget = nil
	end

	--[[ The lock's own upkeep. It drops when its combatant is gone or dead, and
		when they have been out of reach for longer than the grace -- long enough
		to survive a corner, short enough that walking away from someone clears
		them. Reach for the lock is the striker's range, which is the longest
		anything reaches, so a lock never claims more than the ray could. ]]
	local locked = lockedTarget
	if locked then
		if not Nameplates.isLive(locked) then
			unlock()
			return
		end
		local theirRoot = locked.model:FindFirstChild("HumanoidRootPart")
		local within = theirRoot
			and theirRoot:IsA("BasePart")
			and (theirRoot.Position - root.Position).Magnitude <= Config.Combat.ranges.striker
		if within then
			lockOutOfReachSince = nil
		else
			local since = lockOutOfReachSince or now
			lockOutOfReachSince = since
			if now - since > TARGET.lockReachGrace then
				unlock()
			end
		end
	end
end

--[[ Lock whatever the reticle is on. A second press on the same target, or a
	press with nothing under the reticle, releases. Pressing it on a different
	combatant moves the lock rather than clearing it first, because "I want
	that one now" should be one press, not two. ]]
local function toggleLock()
	local under = if aimOnTarget then currentTarget else nil
	if not under then
		unlock()
		return
	end
	if lockedTarget and lockedTarget.id == under.id then
		unlock()
		return
	end
	unlock()
	lockedTarget = under
	lockOutOfReachSince = nil
end

--[[ The lock's mark in the world.

	PresenceService already puts a Highlight on every player as the stage aura,
	so a second Highlight for the lock would stack on it or fight it. Instead the
	existing one is RETINTED to the lock colour while locked, and restored to the
	stage colour on release. A dummy carries no aura, so it gets a client-side
	Highlight of its own for the duration of the lock and loses it after.

	Re-asserted every frame rather than set once, for the reason the nameplate
	stand-down is: PresenceService destroys and rebuilds the aura on any stage or
	tier change, and a one-shot retint would come undone at the next tier roll.
	The write only happens when the colour differs, so the steady state is a
	comparison. ]]
local AURA_NAME = "CultivatorAura"
local ownedLockHighlight: Highlight? = nil

local function auraOf(model: Model): Highlight?
	local root = model:FindFirstChild("HumanoidRootPart")
	local aura = if root then root:FindFirstChild(AURA_NAME) else nil
	return if aura and aura:IsA("Highlight") then aura else nil
end

local function refreshLockHighlight()
	local locked = lockedTarget
	if locked then
		local aura = auraOf(locked.model)
		if aura then
			if aura.OutlineColor ~= LOCK then
				aura.OutlineColor = LOCK
				aura.FillColor = LOCK
			end
		else
			-- No aura to retint: a dummy, or a player whose aura has not built
			-- yet. Draw our own until the lock releases.
			if not ownedLockHighlight or ownedLockHighlight.Parent ~= locked.model then
				if ownedLockHighlight then
					ownedLockHighlight:Destroy()
				end
				local own = Instance.new("Highlight")
				own.Name = "LockHighlight"
				own.OutlineColor = LOCK
				own.FillColor = LOCK
				own.FillTransparency = 0.86
				own.OutlineTransparency = 0.2
				own.DepthMode = Enum.HighlightDepthMode.Occluded
				own.Parent = locked.model
				ownedLockHighlight = own
			end
		end
		return
	end

	-- Not locked: give any retinted aura its stage colour back, and drop ours.
	if ownedLockHighlight then
		ownedLockHighlight:Destroy()
		ownedLockHighlight = nil
	end
end

--[[ Restoring a retinted aura needs the target we just released, so it is done
	at the moment of release rather than in the per-frame refresh. ]]
local function restoreAura(who: Nameplates.Combatant)
	local aura = auraOf(who.model)
	if not aura then
		return
	end
	local stageIndex = who.source:GetAttribute("StageIndex")
	if typeof(stageIndex) == "number" then
		local stage = color(InterfaceSpec.stageColor(stageIndex))
		aura.OutlineColor = stage
		aura.FillColor = stage
	end
end

--[[ Click-to-target: a ray from the cursor rather than the camera centre, so a
	player can pick someone off to the side without turning to face them. The
	server never sees this; it only ever sees the combatant id a lock technique
	is eventually cast at, and validates that itself. ]]
local function lockUnderCursor()
	local camera = Workspace.CurrentCamera
	local character = player.Character
	if not camera or not character then
		return
	end
	local position = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(position.X, position.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character :: Instance }
	local hit = Workspace:Raycast(ray.Origin, ray.Direction * Config.Combat.ranges.striker, params)
	local found = if hit then Nameplates.combatantFromInstance(hit.Instance) else nil
	if found then
		unlock()
		lockedTarget = found
		lockOutOfReachSince = nil
	end
end

onUnlock = restoreAura

--[[ The reticle.

	This game aims with the camera -- `resolveStriker` raycasts from the root
	along the look vector -- and until now nothing on screen said where that ray
	went. In third person, with a free camera, that means a player firing a
	140-stud bolt is guessing. The hitmarker in `Impact` tells you afterwards
	that you connected; nothing told you beforehand where you were pointing.

	Four axis-aligned ticks around a centre gap, deliberately *not* an X: the X
	at screen centre is already spoken for by `ImpactSpec.Marker`, and a reticle
	a player could confuse with a hit confirmation would be worse than none.

	It also carries the one fact that decides whether a fight is even legal.
	`Combat.canEngage` refuses across brackets, and the reticle is where a player
	is already looking, so that refusal is cheapest to read here. ]]
local reticleUi: { ticks: { Frame } }
do
	local RETICLE_GAP = px(5)
	local RETICLE_LEN = px(6)
	local RETICLE_THICK = math.max(px(2), 2)

	--[[ The reticle lives in its own ScreenGui, and the reason is a bug that was
		live in the deployed build.

		The HUD's ScreenGui respects Roblox's top inset -- correctly, so notices and
		the target frame sit below the engine's own chrome. But that means its
		(0.5, 0.5) is not the viewport's centre; it is half an inset below it, which
		at a high-DPI display was measured at 27 pixels. The aim ray follows the
		camera's optical axis, which IS the viewport centre, and so does the
		hitmarker in `Impact`, whose ScreenGui ignores the inset. So the reticle
		sat 27 pixels under where the shot actually went and under the X it is
		meant to be concentric with. A tester who knew exactly where to look
		cropped the true centre at 4x and 12x and found hair.

		Its own ScreenGui with the inset ignored puts it in the same space as the
		ray and the hitmarker, with no arithmetic to drift when the inset does. ]]
	local reticleScreen = Instance.new("ScreenGui")
	reticleScreen.Name = "CultivationReticle"
	reticleScreen.ResetOnSpawn = false
	reticleScreen.IgnoreGuiInset = true
	reticleScreen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	reticleScreen.Parent = player:WaitForChild("PlayerGui")

	local reticle = Instance.new("Frame")
	reticle.Name = "Reticle"
	reticle.AnchorPoint = Vector2.new(0.5, 0.5)
	reticle.Position = UDim2.fromScale(0.5, 0.5)
	reticle.Size = UDim2.fromOffset(px(40), px(40))
	reticle.BackgroundTransparency = 1
	reticle.Parent = reticleScreen

	local reticleTicks: { Frame } = {}
	for _, spec in
		{
			{ x = 0, y = -1, vertical = true },
			{ x = 0, y = 1, vertical = true },
			{ x = -1, y = 0, vertical = false },
			{ x = 1, y = 0, vertical = false },
		}
	do
		local tick = Instance.new("Frame")
		tick.AnchorPoint = Vector2.new(0.5, 0.5)
		tick.Position = UDim2.new(
			0.5,
			spec.x * (RETICLE_GAP + RETICLE_LEN / 2),
			0.5,
			spec.y * (RETICLE_GAP + RETICLE_LEN / 2)
		)
		tick.Size = if spec.vertical
			then UDim2.fromOffset(RETICLE_THICK, RETICLE_LEN)
			else UDim2.fromOffset(RETICLE_LEN, RETICLE_THICK)
		tick.BorderSizePixel = 0
		tick.BackgroundColor3 = TEXT
		tick.BackgroundTransparency = InterfaceSpec.Reticle.idleTransparency
		tick.Parent = reticle
		table.insert(reticleTicks, tick)

		-- A hairline of black under each tick, so the reticle survives a bright
		-- wall or a pale sky. The same value-contrast rule the impact grammar uses.
		local shadow = Instance.new("Frame")
		shadow.AnchorPoint = Vector2.new(0.5, 0.5)
		shadow.Position = UDim2.fromScale(0.5, 0.5)
		shadow.Size = UDim2.new(1, 2, 1, 2)
		shadow.BackgroundColor3 = BLACK
		shadow.BackgroundTransparency = 0.5
		shadow.BorderSizePixel = 0
		shadow.ZIndex = tick.ZIndex - 1
		shadow.Parent = tick
	end
	reticleUi = { ticks = reticleTicks }
end

local function refreshReticle()
	local tint = TEXT
	local transparency = InterfaceSpec.Reticle.idleTransparency

	if aimOnTarget and currentTarget then
		-- Lit for a fight you can have -- same bracket, a neutral, or a
		-- cross-bracket fight the profile has opened -- dim red only for one
		-- the server will refuse.
		local fightable = canFight(currentTarget.source)
		tint = if fightable then READY else UNAFFORDABLE
		transparency = if fightable then 0 else 0.25
	end

	for _, tick in reticleUi.ticks do
		tick.BackgroundColor3 = tint
		tick.BackgroundTransparency = transparency
	end
end

--[[ The right half at rest: the same silhouette with nothing in it. The
	troughs stay, dimmed, so the pair is always a pair; the words say why it is
	empty. ]]
local function restTarget()
	targetUi.nameLabel.Text = "no target"
	targetUi.nameLabel.TextColor3 = TEXT_FAINT
	targetUi.stageLabel.Text = ""
	targetUi.lockTag.Visible = false
	targetUi.stroke.Transparency = 1
	targetUi.healthFill.Size = UDim2.fromScale(0, 1)
	targetUi.healthValue.Text = ""
	targetUi.castFill.Size = UDim2.fromScale(0, 1)
	targetUi.castName.Text = ""
	targetUi.castTimer.Text = ""
	targetUi.relation.Visible = false
	for _, trough in targetUi.troughs do
		trough.BackgroundTransparency = TARGET.restTransparency
	end
end

local function refreshTarget()
	-- The lock outranks the soft target: once you have chosen someone, the
	-- frame stays on them however the reticle wanders.
	local target = lockedTarget or currentTarget
	if not target or not Nameplates.isLive(target) then
		restTarget()
		return
	end

	-- Live: the troughs at the vitals' own weight.
	for _, trough in targetUi.troughs do
		trough.BackgroundTransparency = 0.1
	end
	targetUi.nameLabel.Text = target.name
	targetUi.nameLabel.TextColor3 = TEXT
	--[[ The frame says which idiom it is showing. A locked target is a choice
		the player made and the border is the lock colour, solid; a soft target
		is a readout of the aim and shows no border at all, the same as your own
		half. ]]
	local locked = lockedTarget ~= nil
	targetUi.lockTag.Visible = locked

	local stage = target.source:GetAttribute("Stage")
	local tier = target.source:GetAttribute("Tier")
	local stageIndex = target.source:GetAttribute("StageIndex")
	targetUi.stageLabel.Text = if typeof(stage) == "string" and typeof(tier) == "number"
		then `{stage}  ·  {tier}`
		elseif typeof(stage) == "string" then stage
		else "--"
	if typeof(stageIndex) == "number" then
		targetUi.nameLabel.TextColor3 = color(InterfaceSpec.stageColor(stageIndex))
	end

	local health = target.source:GetAttribute("Health")
	local maxHealth = target.source:GetAttribute("MaxHealth")
	local numericHealth = if typeof(health) == "number" then health else 0
	local numericMax = if typeof(maxHealth) == "number" then maxHealth else 0
	local fraction = InterfaceSpec.fraction(numericHealth, numericMax)
	targetUi.healthFill.Size = UDim2.fromScale(fraction, 1)
	targetUi.healthFill.BackgroundColor3 = if fraction <= VITALS.lowHealthFraction
		then HEALTH_LOW
		else HEALTH
	targetUi.healthValue.Text =
		`{InterfaceSpec.commas(numericHealth)} / {InterfaceSpec.commas(numericMax)}`

	local relation = fightRelation(target.source)

	local cast = Nameplates.castOf(target.id)
	-- A snap is drawn even for a cast under the floor: the bar could not be
	-- seen, but its breaking is an event and is shown. Same rule as the plate.
	local drawingCast = cast ~= nil
		and (InterfaceSpec.telegraphs(cast.duration) or Nameplates.isSnapped(cast))

	--[[ The second row's resting line says what the fight is, in the register
		the bracket notices use. Under "refuse" it says the server will not
		apply the hit, as it always did. Under "notice" the hit lands and the
		line says the true thing instead: out of your bracket, open for
		testing, not a fair fight. A neutral gets no bracket line at all -- it
		has no bracket relation to anyone, and telling a player that a practice
		target is "out of bracket" would be inventing a rule -- but it is told
		for what it is, in the plate's words and colour. ]]
	if relation == "refused" then
		targetUi.stroke.Color = DANGER
		targetUi.relation.TextColor3 = DANGER
		targetUi.relation.Text = "different bracket — neither of you can hit the other"
	elseif relation == "open" then
		targetUi.stroke.Color = LOCK
		targetUi.relation.TextColor3 = TEXT_DIM
		targetUi.relation.Text = "out of your bracket — open for testing, and not a fair fight"
	elseif relation == "neutral" then
		targetUi.stroke.Color = LOCK
		targetUi.relation.TextColor3 = NEUTRAL
		targetUi.relation.Text = "NEUTRAL  ·  will not start it"
	else
		targetUi.stroke.Color = LOCK
		targetUi.relation.Text = ""
	end
	targetUi.stroke.Transparency = if locked or relation == "refused" then 0 else 1
	targetUi.relation.Visible = not drawingCast and targetUi.relation.Text ~= ""

	if cast and drawingCast then
		targetUi.castName.Text =
			InterfaceSpec.castLabel(cast.techId, Config.Techniques[cast.techId])
		if Nameplates.isSnapped(cast) then
			-- Broken, not finished: the whole bar in the danger hue for a beat,
			-- and no timer, because there is no time left to count.
			targetUi.castFill.Size = UDim2.fromScale(1, 1)
			targetUi.castFill.BackgroundColor3 = DANGER
			targetUi.castTimer.Text = ""
		else
			local elapsed = os.clock() - cast.startedAt
			local remaining = math.max(cast.duration - elapsed, 0)
			targetUi.castFill.Size = UDim2.fromScale(math.clamp(elapsed / cast.duration, 0, 1), 1)
			targetUi.castFill.BackgroundColor3 = color(InterfaceSpec.kindColor(cast.kind))
			targetUi.castTimer.Text = string.format("%.1f", remaining)
		end
	else
		targetUi.castFill.Size = UDim2.fromScale(0, 1)
		targetUi.castName.Text = ""
		targetUi.castTimer.Text = ""
	end
end

-- ===================================================================
-- Own cast bar.
-- ===================================================================

local ownCast: Nameplates.Cast? = nil

local function refreshOwnCast()
	local cast = ownCast
	if not cast then
		castUi.frame.Visible = false
		return
	end
	--[[ The registry owns the record's lifetime, including the snap. Reading
		through castOf rather than holding our own timer means an interrupt or a
		fizzle ends this bar the same frame it ends the nameplate's. ]]
	local live = Nameplates.castOf(player.UserId)
	if not live or live ~= cast then
		ownCast = nil
		castUi.frame.Visible = false
		return
	end
	if not InterfaceSpec.telegraphs(cast.duration) and not Nameplates.isSnapped(cast) then
		castUi.frame.Visible = false
		return
	end

	castUi.frame.Visible = true
	castUi.name.Text = InterfaceSpec.castLabel(cast.techId, Config.Techniques[cast.techId])
	if Nameplates.isSnapped(cast) then
		castUi.fill.Size = UDim2.fromScale(1, 1)
		castUi.fill.BackgroundColor3 = DANGER
		castUi.timer.Text = ""
	else
		local elapsed = os.clock() - cast.startedAt
		castUi.fill.Size = UDim2.fromScale(math.clamp(elapsed / cast.duration, 0, 1), 1)
		castUi.fill.BackgroundColor3 = color(InterfaceSpec.kindColor(cast.kind))
		castUi.timer.Text = string.format("%.1f", math.max(cast.duration - elapsed, 0))
	end
end

-- ===================================================================
-- Sense.
-- ===================================================================

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

--[[ Bearing to a node, in eight buckets, taken against the camera's own forward
	and right vectors rather than a cross product -- so the handedness is
	whatever Roblox says it is rather than whatever this file assumed. ]]
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
	local angle = math.atan2(flatRight:Dot(flatTo), flatForward:Dot(flatTo))
	local index = math.round(angle / (math.pi / 4)) % 8
	return ARROWS[index + 1]
end

--[[ The node bar follows the nearest node inside the capture radius -- the
	one the server is cycling you on -- and hides otherwise. Reserve is read
	off the same payload the Sense rows use, so the row and the bar cannot
	disagree about how much is left. ]]
local function refreshNodeBar(nodes: { any })
	local inside: any = nil
	local nearest = math.huge
	for _, entry in nodes do
		local distance = tonumber(entry.distance)
		if distance and distance <= Config.Field.captureRadius and distance < nearest then
			nearest = distance
			inside = entry
		end
	end
	if not inside or typeof(inside.maxReserve) ~= "number" or inside.maxReserve <= 0 then
		vitalsUi.nodeBar.Visible = false
		return
	end
	local reserve = if typeof(inside.reserve) == "number" then inside.reserve else 0
	vitalsUi.nodeBar.Visible = true
	vitalsUi.nodeFill.Size = UDim2.fromScale(InterfaceSpec.fraction(reserve, inside.maxReserve), 1)
	vitalsUi.nodeFill.BackgroundColor3 = TIER_COLOR[inside.tier] or TEXT_DIM
end

local function refreshSense(nodes: { any })
	refreshNodeBar(nodes)
	for index, row in senseUi.rows do
		local entry = nodes[index]
		if not entry then
			row.Text = ""
			continue
		end
		row.TextColor3 = TIER_COLOR[entry.tier] or TEXT_DIM
		-- Reserve is ALWAYS in the payload once the driver lands; until then a
		-- missing pair reads as an untouched node rather than a broken row.
		local reserve = if typeof(entry.reserve) == "number" then entry.reserve else 0
		local maxReserve = if typeof(entry.maxReserve) == "number" then entry.maxReserve else 0
		row.Text = string.format(
			"%s %-6s %4d  %d/%d  %s",
			arrowTo(entry.x, entry.z),
			entry.tier,
			math.floor(entry.distance),
			entry.occupants,
			entry.capacity,
			InterfaceSpec.drainMeter(reserve, maxReserve)
		)
	end

	local senseRange = player:GetAttribute("SenseRange") or 0
	senseUi.foot.Text = if senseRange <= 0
		then "no aura sense at this stage"
		elseif #nodes == 0 then "nothing within range"
		elseif #nodes > #senseUi.rows then `+{#nodes - #senseUi.rows} more`
		else ""
end

local noticeToken = 0
--[[ What is currently on the line, so a lower-priority notice cannot erase a
	kill or a death that has only just landed. The channel has one slot; this is
	what stops a Prime-node announcement arriving half a second after a death
	from simply deleting it. ]]
local noticePriority = -1
local noticeFloorUntil = 0

local function showNotice(kind: string, message: string)
	local weight = InterfaceSpec.noticeKind(kind)
	local now = os.clock()
	if weight.priority < noticePriority and now < noticeFloorUntil then
		return
	end

	noticeToken += 1
	local token = noticeToken
	noticePriority = weight.priority
	noticeFloorUntil = now + weight.floor

	noticeUi.label.TextColor3 = NOTICE_COLOR[kind] or CEILING
	noticeUi.label.TextSize = text(NOTICE.textSize * weight.scale)
	noticeUi.label.Text = message
	noticeUi.frame.Visible = true

	task.delay(weight.seconds, function()
		if noticeToken == token then
			noticeUi.frame.Visible = false
			noticePriority = -1
		end
	end)
end

-- ===================================================================
-- Wiring.
-- ===================================================================

local CULTIVATION_ATTRIBUTES = {
	"Stage",
	"StageIndex",
	"Tier",
	"Progress",
	"TierGoal",
	"Catalysts",
	"Power",
	"SenseRange",
	"AtCeiling",
	-- The headline carries the core's dominant aura.
	"Core_ash",
	"Core_verdant",
	"Core_lumen",
}
local VITAL_ATTRIBUTES = {
	"Health",
	"MaxHealth",
	"Aura",
	"MaxAura",
	"SlowMultiplier",
	"Vessel_ash",
	"Vessel_verdant",
	"Vessel_lumen",
	"Vessel_neutral",
	"VesselCapacity",
	"Core_ash",
	"Core_verdant",
	"Core_lumen",
}

--[[ A breakthrough rebuilds the server's actor with genuinely empty cooldowns,
	but the local prediction table knew nothing about it -- so a slot could sit
	there showing up to twenty seconds of Tempest cooldown that the server would
	have fired instantly. Self-correcting and cosmetic, except that it landed on
	the single most triumphant moment in the game. ]]
player:GetAttributeChangedSignal("StageIndex"):Connect(function()
	table.clear(cooldownUntil)
	gcdUntil = 0
end)

for _, attribute in CULTIVATION_ATTRIBUTES do
	player:GetAttributeChangedSignal(attribute):Connect(refreshCultivation)
end
for _, attribute in VITAL_ATTRIBUTES do
	player:GetAttributeChangedSignal(attribute):Connect(refreshVitals)
end
for _, slot in slotNames do
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
local techniqueFired = remotes:WaitForChild("TechniqueFired") :: RemoteEvent
local castStarted = remotes:WaitForChild("CastStarted") :: RemoteEvent

--[[ Looked up without waiting, unlike every remote above it. `SetLoadout` is
	landing from the combat workstream in a separate change, and a `WaitForChild`
	on a remote that has not shipped yet would hang this script forever -- taking
	the entire HUD with it, to add a feature. Absent, cycling simply does
	nothing; present, it works. Nothing else in this file depends on it. ]]
local setLoadout = remotes:FindFirstChild("SetLoadout")

--[[ Looked up without waiting, like SetLoadout, for the same reason: these land
	from the combat workstream in a separate change, and a WaitForChild on a
	remote that has not shipped would hang the whole HUD. Absent, a channel's
	bar clears on its own clock as every bar does today; present, an interrupt
	or a fizzle snaps it early. Their shapes are the REMOTES section of
	frostbolt-ruling.md, and are revised there, never here. ]]
local castInterrupted = remotes:FindFirstChild("CastInterrupted")
local castCompleted = remotes:FindFirstChild("CastCompleted")

--[[ Loadout cycling, without a picker.

	Every player has been running the identical character -- `CombatService`
	clones `Config.DefaultLoadout` once and nothing ever writes to that table
	again -- so eight of the twelve finished techniques have never been in
	anyone's hands. `Config`'s own comment calls 81 loadouts the point of the
	shared pool, and that entire axis was dead.

	A picker panel is the obvious answer and the wrong one this afternoon: it is
	a new screen, a new focus state and a new thing to explain to four people who
	have never played. Instead the action bar *is* the picker -- Shift and a slot
	key steps that slot to the next technique of its kind, and the slot relabels
	itself off the `Slot_<slot>` attribute the server publishes back. No new
	screen at all.

	Options are enumerated from the replicated `Config`, ordered by aura cost so
	cycling reads cheap-to-dear rather than in hash order. That client-side guess
	only decides what to *ask for*; the server validates the slot, the technique,
	the kind match, and whether the technique being swapped away is mid-cooldown
	-- otherwise swapping would be a free cooldown reset. ]]
local optionsBySlot: { [string]: { string } } = {}
for _, slot in slotNames do
	local options: { string } = {}
	for id, tech in Config.Techniques do
		if tech.kind == slot then
			table.insert(options, id)
		end
	end
	table.sort(options, function(a: string, b: string): boolean
		local left, right = Config.Techniques[a], Config.Techniques[b]
		if left.auraCost ~= right.auraCost then
			return left.auraCost < right.auraCost
		end
		-- Ties broken by id so the order is stable across clients and sessions.
		return a < b
	end)
	optionsBySlot[slot] = options
end

--[[ Request a slot change. One place that talks to `SetLoadout`, so the cycle
	chord and the picker cannot drift apart about what a swap is. ]]
local function requestLoadout(slot: string, techId: string)
	local current = player:GetAttribute("Slot_" .. slot)
	if techId == current then
		return
	end
	if setLoadout and setLoadout:IsA("RemoteEvent") then
		(setLoadout :: RemoteEvent):FireServer(slot, techId)
	end
end

local function cycleSlot(slot: string)
	local options = optionsBySlot[slot]
	if not options or #options < 2 then
		return
	end
	local current = player:GetAttribute("Slot_" .. slot)
	local index = 0
	for position, id in options do
		if id == current then
			index = position
			break
		end
	end
	local nextId = options[(index % #options) + 1]
	if nextId then
		requestLoadout(slot, nextId)
	end
end

-- ===================================================================
-- The loadout picker. Development profile only.
-- ===================================================================

--[[ The whole pool, visible and swappable, behind a toggle.

	Gated on `Config.Profile` exactly as the tuning numbers are: the ask was
	"just for testing purposes for right now", and that is a lifetime this
	project already has a place for. It cannot ship by accident, and setting the
	profile to release removes it with no deletion and nothing to remember.

	**Grouped by kind, because the grouping is the rule.** One slot per kind is
	what makes a loadout a loadout, and a flat list of fifteen names hides it. A
	row per kind with the current pick marked says, by its shape, that choosing a
	new striker replaces your striker and touches nothing else.

	**The client offers; the server still refuses.** Only same-kind techniques
	appear in a slot's row, because offering an illegal choice is a bad
	affordance -- but that filter carries no authority. `CombatService.onSetLoadout`
	validates the slot, the technique, the kind match, that the player is alive
	and that the outgoing technique is not mid-cooldown, exactly as it did before
	this panel existed. A picker makes swapping fast and comfortable, which makes
	it the natural way to try to dodge a cooldown -- so that last check gets *more*
	load-bearing here, not less. ]]
local PICKER = InterfaceSpec.Picker
local pickerEnabled = Config.Profile == "development"

type ChipWidget = {
	button: TextButton,
	stroke: UIStroke,
	label: TextLabel,
	slot: string,
	techId: string,
}

local pickerChips: { ChipWidget } = {}
local pickerFrame: Frame? = nil

local function buildPicker()
	if not pickerEnabled then
		return
	end

	--[[ Laid out by the engine rather than by arithmetic.

		The first version sized chips as `available / count`, which is correct
		for three options per kind and wrong for eight: the roster pass takes
		the pool from fifteen to thirty, and a chip a third its width is not a
		chip. Rather than patch the division, the layout is handed to a grid
		that wraps and a list that stacks -- so the number of options per kind
		is something the panel discovers rather than something this code has to
		be told. There is no width formula left to be wrong.

		The body scrolls once it would exceed a fraction of the viewport, so a
		pool of any size stays inside the screen and never over the bar it
		edits. ]]
	local frame = Instance.new("Frame")
	frame.Name = "LoadoutPicker"
	frame.AnchorPoint = Vector2.new(0.5, 1)
	-- Above the bottom cluster, so the panel never covers the bar it edits.
	frame.Position = UDim2.new(0.5, 0, 1, -(px(SLOT.bottomMargin) + clusterHeight + px(30)))
	frame.Size = UDim2.fromOffset(px(PICKER.width), 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundColor3 = PANEL
	frame.BackgroundTransparency = 0.06
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = screen
	corner(frame, 4)
	outline(frame, EDGE, 1).Transparency = 0.3
	pickerFrame = frame

	local framePadding = Instance.new("UIPadding")
	framePadding.PaddingTop = UDim.new(0, px(PICKER.padding))
	framePadding.PaddingBottom = UDim.new(0, px(PICKER.padding))
	framePadding.PaddingLeft = UDim.new(0, px(PICKER.padding))
	framePadding.PaddingRight = UDim.new(0, px(PICKER.padding))
	framePadding.Parent = frame

	local stack = Instance.new("UIListLayout")
	stack.FillDirection = Enum.FillDirection.Vertical
	stack.SortOrder = Enum.SortOrder.LayoutOrder
	stack.Padding = UDim.new(0, px(PICKER.blockGap))
	stack.Parent = frame

	local header = Instance.new("Frame")
	header.Size = UDim2.new(1, 0, 0, px(PICKER.headerHeight))
	header.BackgroundTransparency = 1
	header.LayoutOrder = 0
	header.Parent = frame

	local title = caption(header, text(PICKER.titleTextSize), CEILING, true)
	title.Size = UDim2.fromScale(1, 1)
	title.Text = "LOADOUT"

	local hint = caption(header, text(PICKER.footTextSize), TEXT_FAINT, false)
	hint.Size = UDim2.fromScale(1, 1)
	hint.TextXAlignment = Enum.TextXAlignment.Right
	hint.Text = "[L] close    ·    one per kind"

	--[[ The scrolling body. Its height is whatever its contents need, capped at
		a fraction of the viewport; past the cap it scrolls. ]]
	local body = Instance.new("ScrollingFrame")
	body.Size = UDim2.fromScale(1, 0)
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.CanvasSize = UDim2.new()
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.ScrollBarThickness = px(4)
	body.ScrollBarImageColor3 = EDGE
	body.ScrollingDirection = Enum.ScrollingDirection.Y
	body.LayoutOrder = 1
	body.Parent = frame

	local bodyCap = Instance.new("UISizeConstraint")
	bodyCap.MaxSize = Vector2.new(math.huge, math.floor(viewport * PICKER.maxHeightFraction))
	bodyCap.Parent = body

	local blocks = Instance.new("UIListLayout")
	blocks.FillDirection = Enum.FillDirection.Vertical
	blocks.SortOrder = Enum.SortOrder.LayoutOrder
	blocks.Padding = UDim.new(0, px(PICKER.blockGap))
	blocks.Parent = body

	for rowIndex, slot in slotNames do
		--[[ One block per kind: a label on the left, and a grid of chips that
			wraps to as many rows as the options need. ]]
		local block = Instance.new("Frame")
		block.Size = UDim2.fromScale(1, 0)
		block.AutomaticSize = Enum.AutomaticSize.Y
		block.BackgroundTransparency = 1
		block.LayoutOrder = rowIndex
		block.Parent = body

		local kindLabel = caption(block, text(PICKER.kindTextSize), TEXT_DIM, true)
		kindLabel.Size = UDim2.fromOffset(px(PICKER.kindLabelWidth), px(PICKER.chipHeight))
		kindLabel.Text = string.upper(slot)
		kindLabel.TextColor3 = color(InterfaceSpec.kindColor(slot))

		local chips = Instance.new("Frame")
		chips.Position = UDim2.fromOffset(px(PICKER.kindLabelWidth), 0)
		chips.Size = UDim2.new(1, -px(PICKER.kindLabelWidth), 0, 0)
		chips.AutomaticSize = Enum.AutomaticSize.Y
		chips.BackgroundTransparency = 1
		chips.Parent = block

		local grid = Instance.new("UIGridLayout")
		grid.CellSize = UDim2.fromOffset(px(PICKER.chipWidth), px(PICKER.chipHeight))
		grid.CellPadding = UDim2.fromOffset(px(PICKER.chipGap), px(PICKER.chipGap))
		grid.FillDirection = Enum.FillDirection.Horizontal
		grid.SortOrder = Enum.SortOrder.LayoutOrder
		grid.Parent = chips

		local options: { string } = optionsBySlot[slot] or {}
		for chipIndex, techId in options do
			local tech = Config.Techniques[techId]
			local button = Instance.new("TextButton")
			button.BackgroundColor3 = TROUGH
			button.BackgroundTransparency = 0.15
			button.BorderSizePixel = 0
			button.AutoButtonColor = false
			button.Text = ""
			button.LayoutOrder = chipIndex
			button.Parent = chips
			corner(button, 3)
			local stroke = outline(button, EDGE, 1)

			local label = caption(button, text(PICKER.chipTextSize), TEXT, true)
			label.Size = UDim2.fromScale(1, 1)
			label.TextXAlignment = Enum.TextXAlignment.Center
			label.TextTruncate = Enum.TextTruncate.AtEnd
			label.Text = if tech then `{tech.name}  {tech.auraCost}` else techId

			button.Activated:Connect(function()
				requestLoadout(slot, techId)
			end)

			table.insert(pickerChips, {
				button = button,
				stroke = stroke,
				label = label,
				slot = slot,
				techId = techId,
			})
		end
	end
end

--[[ Marks the equipped technique in each row, and dims anything a swap would
	currently be refused for -- dimmed rather than hidden, so the panel explains
	the refusal instead of appearing to lose an option. ]]
local function refreshPicker()
	if not pickerFrame or not pickerFrame.Visible then
		return
	end
	local now = os.clock()
	for _, chip in pickerChips do
		local equipped = player:GetAttribute("Slot_" .. chip.slot) == chip.techId
		local tech = Config.Techniques[chip.techId]
		local kind = color(InterfaceSpec.kindColor(chip.slot))

		-- The outgoing technique being mid-cooldown is what the server refuses
		-- on, so that is what the panel reflects.
		local outgoing = player:GetAttribute("Slot_" .. chip.slot)
		local outgoingCooling = typeof(outgoing) == "string"
			and (cooldownUntil[outgoing] or 0) > now
		local blocked = outgoingCooling and not equipped

		chip.stroke.Color = if equipped then kind elseif blocked then COOLING else EDGE
		chip.stroke.Thickness = if equipped then 2 else 1
		chip.button.BackgroundTransparency = if equipped then 0 else 0.15
		chip.button.BackgroundColor3 = if equipped then PANEL else TROUGH
		chip.label.TextTransparency = if blocked then PICKER.unavailableTransparency else 0
		chip.label.TextColor3 = if equipped then TEXT else TEXT_DIM
		if tech then
			chip.label.Text = `{tech.name}  {tech.auraCost}`
		end
	end
end

local function togglePicker()
	local frame = pickerFrame
	if not frame then
		return
	end
	frame.Visible = not frame.Visible
	refreshPicker()
end

local latest: { any } = {}
sensed.OnClientEvent:Connect(function(nodes: { any })
	latest = nodes
	refreshSense(latest)
end)
notice.OnClientEvent:Connect(showNotice)

techniqueFired.OnClientEvent:Connect(function(shot: Vfx.Shot)
	if shot.casterId == player.UserId then
		noteOwnCast(shot.techId)
	end
	Vfx.play(shot)
end)

--[[ The telegraph, arriving at intent time rather than after the windup. Fed
	into `Nameplates` so there is exactly one record of who is casting what, and
	the nameplate, the target frame and your own bar cannot disagree about it. ]]
castStarted.OnClientEvent:Connect(function(event: any)
	if typeof(event) ~= "table" then
		return
	end
	local casterId = tonumber(event.casterId)
	if not casterId then
		return
	end
	--[[ `duration` is the commit -- castTime for a channel, windup otherwise --
		and the server sends it on every cast per the REMOTES section. The
		fallback to `windup` exists only for the window before the server half
		ships; once it has, the two are equal for every ordinary technique and
		the fallback is never taken. ]]
	local duration = tonumber(event.duration) or tonumber(event.windup) or 0
	Nameplates.noteCast(casterId, tostring(event.techId), tostring(event.kind), duration)
	if casterId == player.UserId then
		ownCast = Nameplates.castOf(casterId)
		confirmMovement(tostring(event.techId))
	end
end)

local function onCastEnded(event: any, snapped: boolean)
	if typeof(event) ~= "table" then
		return
	end
	local casterId = tonumber(event.casterId)
	if not casterId then
		return
	end
	Nameplates.endCast(casterId, tostring(event.techId), snapped)
end

if castInterrupted and castInterrupted:IsA("RemoteEvent") then
	castInterrupted.OnClientEvent:Connect(function(event: any)
		-- An interrupt is always a snap: the cast broke.
		onCastEnded(event, true)
	end)
end
if castCompleted and castCompleted:IsA("RemoteEvent") then
	castCompleted.OnClientEvent:Connect(function(event: any)
		-- A fizzled completion produced nothing, so it reads as broken too. A
		-- clean one just ends the record; the bar was about to end anyway.
		local fizzled = typeof(event) == "table" and event.fizzled == true
		onCastEnded(event, fizzled)
	end)
end

--[[ The guidance state machine. First match wins, and the order is the order a
	player's attention should follow: what is stopping you, then what you are
	doing, then where to go.

	`Sensed` already carries a distance per node, so "inside a node" is simply
	within `Config.Field.captureRadius` -- the same 14 studs the server uses to
	decide whether you are drawing from it. No new protocol, no server change,
	and the line cannot disagree with the rule it is describing. ]]
local NEARBY_STUDS = 120

local function guidanceText(): string
	local health = player:GetAttribute("Health")
	if typeof(health) == "number" and health <= 0 then
		-- The death feedback already speaks, and loudly. Nothing to add.
		return ""
	end

	local atCeiling = player:GetAttribute("AtCeiling") == true
	local catalysts = player:GetAttribute("Catalysts") or 0
	if atCeiling then
		if catalysts > 0 then
			-- The breakthrough prompt has this. Do not say it twice.
			return ""
		end
		return "At your ceiling. Only a Prime node yields a catalyst. Hold one until it drains."
	end

	local nearest = math.huge
	for _, entry in latest do
		local distance = tonumber(entry.distance)
		if distance and distance < nearest then
			nearest = distance
		end
	end

	if nearest <= Config.Field.captureRadius then
		-- Teaches capacity and the fight over it in one line: three can draw,
		-- and the fourth has no option but to take a place by force.
		return "Cycling. Three can draw from this node. A fourth has to take it."
	end
	if nearest <= NEARBY_STUDS then
		return "A node is close. Stand in it to cycle."
	end

	local senseRange = player:GetAttribute("SenseRange") or 0
	if #latest > 0 then
		return "Seek aura nodes, or cultivate and purify mana in the volcano."
	end
	if senseRange <= 0 then
		return "No aura sense at this stage. Search on foot."
	end
	return "No aura within reach. Move."
end

local function refreshGuidance()
	cardUi.guidance.Text = guidanceText()
end

--[[ Fault-isolated, for the reason `init.server.luau` learned the hard way: one
	throw in an early subsystem silently took every later one with it.

	The client version of that mistake is worse than the server's. Input is bound
	at the bottom of this file, so anything that throws up here would leave a
	player with a working game, a visible world, and **no keys at all** -- unable
	to cast, unable to break through, and with no way to tell that the cause was
	a nameplate rather than the server. Losing hit feedback is survivable for an
	evening. Losing the ability to press a button is not.

	Warned rather than swallowed, so a failure is visible in the output window
	instead of being merely quiet. ]]
local function startSubsystem(name: string, start: () -> ())
	-- Same arity cast, same reason.
	local protectedStart = start :: () -> any
	local ok, err = pcall(protectedStart)
	if not ok then
		warn(`[hud] {name} failed to start: {err}`)
	end
end

startSubsystem("Impact", require(script.Impact).start)
startSubsystem("Nameplates", Nameplates.start)
startSubsystem("LoadoutPicker", buildPicker)

--[[ The card waits for cultivation state rather than firing at load, so it can
	name the stage the player actually spawned into. ]]
task.spawn(function()
	for _ = 1, 100 do
		if typeof(player:GetAttribute("Stage")) == "string" then
			break
		end
		task.wait(0.1)
	end
	cardUi.show()
end)

--[[ Guarded, and the warning throttled, for the same reason the server tick is.

	A throw in here fires sixty times a second. Unguarded it would bury the
	output window in the noise of its own reporting -- and the output window is
	the only diagnostic anyone has during a session, so an error that destroys it
	takes the ability to diagnose anything else with it. Guarded, a fault in the
	target frame costs the target frame and leaves the action bar working. ]]
local lastRenderWarnAt = 0

local function renderStep()
	refreshSlots()
	refreshOwnCast()

	local now = os.clock()
	if now - lastPoll >= TARGET.pollSeconds then
		lastPoll = now
		pollTarget()
	end
	refreshTarget()
	refreshReticle()
	refreshLockHighlight()
	refreshPicker()
end

-- pcall's result arity follows its callee, and this returns nothing, so the
-- error value has to be asked for explicitly -- the same cast init.server.luau
-- already documents for its own guarded ticks.
local protectedRenderStep = renderStep :: () -> any

RunService.RenderStepped:Connect(function()
	local ok, err = pcall(protectedRenderStep)
	if ok then
		return
	end
	local now = os.clock()
	if now - lastRenderWarnAt >= 5 then
		lastRenderWarnAt = now
		warn(`[hud] render step failed: {err}`)
	end
end)

-- Arrows are relative to the camera, so they are redrawn as it turns even when
-- the node list has not changed.
task.spawn(function()
	while true do
		task.wait(0.25)
		if #latest > 0 then
			refreshSense(latest)
		end
		refreshGuidance()
	end
end)

--[[ Input. Slot keys are derived from `Config.LoadoutSlots`, so a fifth kind
	binds itself to `5` the day it lands. Everything sent here is intent -- a
	slot name and where the camera is looking -- and the server owns every
	decision that follows. ]]

local function fireSlot(slot: string)
	local camera = Workspace.CurrentCamera
	--[[ The third argument is the lock, when there is one: the combatant id
		already held in `lockedTarget`, and nothing else. The server resolves the
		id back to a combatant and validates range, line of sight, bracket and
		liveness itself; this sends what the player chose and claims nothing
		about whether the choice is legal. For an aim technique the server
		ignores it. Argument order is CombatService.onUseTechnique's -- player,
		slot, aim, targetId -- and it is written in the REMOTES section of
		frostbolt-ruling.md, where it should have been before this line was
		missing. ]]
	local locked = lockedTarget
	useTechnique:FireServer(
		slot,
		if camera then camera.CFrame.LookVector else nil,
		if locked then locked.id else nil
	)
	--[[ The speculative windup effect, drawn from here rather than from a second
		input listener inside Vfx. There is one input owner, so there is nothing
		to keep in agreement about what a press with Shift held means. The gate
		result is reused for movement, so there is also one gate. ]]
	if Vfx.predictWindup(slot) then
		local tech = slotTechnique(slot)
		if tech then
			predictMovement(tech)
		end
	end
end

local SLOT_KEYS: { [Enum.KeyCode]: string } = {}
for index, slot in slotNames do
	local keyCode = KEY_CODES[index]
	if keyCode then
		SLOT_KEYS[keyCode] = slot
	end
end

for _, widget in slotWidgets do
	widget.root.Activated:Connect(function()
		cardUi.dismiss()
		fireSlot(widget.slot)
	end)
	--[[ Right-click cycles the slot, as a second route to the same thing the
		Shift chord does. Two ways in, because a player who never finds either
		concludes every character in this game is identical. ]]
	widget.root.MouseButton2Click:Connect(function()
		cardUi.dismiss()
		cycleSlot(widget.slot)
	end)
end

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	--[[ Any input at all retires the card, ahead of the `processed` guard and
		ahead of every other check. A player who has started doing things does
		not need to be told to start doing things, and the card outstaying its
		welcome is the one way a non-interactive overlay can still annoy. ]]
	cardUi.dismiss()
	if processed then
		return
	end
	local slot = SLOT_KEYS[input.KeyCode]
	if slot then
		-- Shift and a slot key swaps the technique in it rather than casting it.
		if
			UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		then
			cycleSlot(slot)
		else
			fireSlot(slot)
		end
	elseif input.KeyCode == Enum.KeyCode.B then
		breakthrough:FireServer()
	elseif input.KeyCode == Enum.KeyCode.L then
		-- Absent outside the development profile: buildPicker made no frame,
		-- so the toggle is a no-op rather than a key that seems dead.
		togglePicker()
	elseif input.KeyCode == Enum.KeyCode.T then
		--[[ T, not Tab: Tab is Roblox's player-list toggle, and we spent a day
			learning there are no corners left. The same is true of keys. ]]
		toggleLock()
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		-- Click-to-target. `processed` above already excludes clicks on UI.
		lockUnderCursor()
	end
end)
