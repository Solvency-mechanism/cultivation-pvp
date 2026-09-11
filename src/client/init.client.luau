--!strict
--[[ The heads-up display, and the input layer that drives it.

	Rebuilt out of the Roblox-traditional register -- big panels pinned to the
	four corners -- and into the dense, anchored one this game's combat now
	needs. The argument is not aesthetic. The old HUD carried four facts and
	carried them well; the fight it has to describe now involves health, madra,
	a per-technique cooldown, a global cooldown, a windup you must react to, an
	opponent whose state you have never once been able to see, and a bracket rule
	that silently refuses fights. Corner panels cannot carry that, and the
	information architecture that can is well known.

	**The organising rule: combat-critical state is anchored to the action bar,
	everything else is exiled to the edges.** The action bar's position is the
	one thing that was already right -- bottom centre, under the character -- so
	health, madra and the cast bar stack directly on top of it. Reading your own
	health used to cost a diagonal saccade to the far corner and back, mid
	exchange. It now costs a few degrees.

	Everything here is presentation and intent. The client sends a slot name and
	an aim vector and nothing else; it predicts cooldowns locally so a press can
	explain itself, and the server remains the only authority on every refusal.

	Tuning lives in `src/shared/InterfaceSpec.luau`, in the shape `ImpactSpec`
	established, so the numbers behind the layout are testable outside Studio and
	sit next to the impact numbers they have to agree with. ]]

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
local MADRA = color(PALETTE.madra)
local REFINEMENT = color(PALETTE.refinement)
local CEILING = color(PALETTE.ceiling)
local READY = color(PALETTE.ready)
local COOLING = color(PALETTE.cooling)
local UNAFFORDABLE = color(PALETTE.unaffordable)
local SCRIM = color(PALETTE.scrim)
local DANGER = color(PALETTE.danger)
local KEYBIND = color(PALETTE.keybind)
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
local viewport = Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize.Y or 1080
local SCALE = InterfaceSpec.scale(viewport)

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

	The old HUD centred `madra 174 / 200` inside every bar. That is correct when
	madra is the only pool you manage and wrong the moment there are several:
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
local CASTSPEC = InterfaceSpec.Cast

local slotNames = Config.LoadoutSlots
local slotCount = #slotNames

local slotSize = px(SLOT.size)
local slotGap = px(SLOT.gap)
local barWidth = px(InterfaceSpec.barWidth(slotCount))
local vitalsWidth = px(VITALS.width)
local clusterWidth = math.max(vitalsWidth, barWidth)

local headerHeight = text(VITALS.headerTextSize) + px(4)
local healthHeight = px(VITALS.healthHeight)
local madraHeight = px(VITALS.madraHeight)
local rowGap = px(VITALS.rowGap)
local stackGap = px(VITALS.stackGap)
local castHeight = px(CASTSPEC.height)

local clusterHeight = headerHeight
	+ healthHeight
	+ rowGap
	+ madraHeight
	+ stackGap
	+ castHeight
	+ stackGap
	+ slotSize

local cluster = Instance.new("Frame")
cluster.Name = "Cluster"
cluster.AnchorPoint = Vector2.new(0.5, 1)
cluster.Position = UDim2.new(0.5, 0, 1, -px(SLOT.bottomMargin))
cluster.Size = UDim2.fromOffset(clusterWidth, clusterHeight)
cluster.BackgroundTransparency = 1
cluster.Parent = screen

local vitals = Instance.new("Frame")
vitals.Name = "Vitals"
vitals.AnchorPoint = Vector2.new(0.5, 0)
vitals.Position = UDim2.fromScale(0.5, 0)
vitals.Size = UDim2.fromOffset(vitalsWidth, headerHeight + healthHeight + rowGap + madraHeight)
vitals.BackgroundTransparency = 1
vitals.Parent = cluster

--[[ The header line: who you are, in the two facts that decide what you may do.
	Stage decides your PvP bracket -- `Combat.canEngage` refuses across it -- and
	tier decides where you sit inside it. ]]
local stageLabel = caption(vitals, text(VITALS.headerTextSize), CEILING, true)
stageLabel.Size = UDim2.new(0.6, 0, 0, headerHeight)
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

local madraRow = Instance.new("Frame")
madraRow.Size = UDim2.new(1, 0, 0, madraHeight)
madraRow.Position = UDim2.fromOffset(0, headerHeight + healthHeight + rowGap)
madraRow.BackgroundTransparency = 1
madraRow.Parent = vitals
local _madraBack, madraFill = bar(madraRow, madraHeight, MADRA)

--[[ The resource is named, and health is not.

	Moving the numbers to the ends of the bars dropped the word the old HUD
	carried -- it read `madra 174 / 200`, this read `174 / 200` -- and that was a
	real loss rather than a tidy-up. A red bar that empties when you are hit
	needs no label in any game anyone has played. "Madra" is a word from this
	game's own fiction, on an unlabelled blue bar, with the cost on every slot a
	bare number in the same blue: colour was carrying the entire meaning of a
	term nobody arrives knowing.

	So the bar is labelled and the slot cost is not. Once the bar says MADRA in
	this blue, the blue number on a technique is joined to it by colour, which is
	the association the palette was built to make -- and a unit printed four
	times across the action bar would cost more room than it buys. ]]
local madraLabel = caption(madraRow, text(VITALS.valueTextSize) - 1, TEXT_DIM, true)
madraLabel.Size = UDim2.new(1, -px(12), 1, 0)
madraLabel.Position = UDim2.fromOffset(px(6), 0)
madraLabel.ZIndex = 3
madraLabel.Text = "MADRA"

local madraValue = caption(madraRow, text(VITALS.valueTextSize) - 1, TEXT_DIM, true)
madraValue.Size = UDim2.new(1, -px(6), 1, 0)
madraValue.Position = UDim2.fromOffset(px(6), 0)
madraValue.TextXAlignment = Enum.TextXAlignment.Right
madraValue.ZIndex = 3

--[[ Your own cast bar, immediately above the action bar.

	It is the direct consequence of the button you just pressed, so it sits
	adjacent to the button. It also does something the old HUD could not: a
	windup is a *commitment* -- aim is sampled at cast and the technique resolves
	wherever you were pointing -- and until now nothing on screen said that the
	commitment was in progress. ]]
local castFrame = Instance.new("Frame")
castFrame.Name = "CastBar"
castFrame.AnchorPoint = Vector2.new(0.5, 0)
castFrame.Position =
	UDim2.new(0.5, 0, 0, headerHeight + healthHeight + rowGap + madraHeight + stackGap)
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

	--[[ The cooldown sweep, kept from the previous HUD because it was already
		the right answer: readiness as a *shape* caught peripherally rather than
		a number you have to read. It drains downward over the technique's own
		cooldown.

		A true radial wedge is what this register would use, and Roblox has no
		conic gradient to build one from -- a real wedge means a four-frame
		rotate-and-clip rig with a fair chance of looking wrong, and at 58px a
		wedge and a vertical drain are near-indistinguishable. The numeric
		countdown below is the half of a radial sweep that players actually read
		off an icon anyway. Revisit after the playtest, not under the clock. ]]
	local sweep = Instance.new("Frame")
	sweep.AnchorPoint = Vector2.new(0, 1)
	sweep.Position = UDim2.fromScale(0, 1)
	sweep.Size = UDim2.fromScale(1, 0)
	sweep.BackgroundColor3 = SCRIM
	sweep.BackgroundTransparency = SLOT.scrimTransparency
	sweep.BorderSizePixel = 0
	sweep.ZIndex = 3
	sweep.Parent = root
	corner(sweep, px(SLOT.cornerRadius))

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

	local cost = caption(root, text(SLOT.costTextSize), MADRA, false)
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
		gcd = gcd,
		stripe = stripe,
		stroke = stroke,
		slot = slotNames[index],
	}
end

--[[ The refinement rail, at the very bottom edge of the screen.

	Demoted out of the combat cluster on purpose. Refinement moves over hours;
	health and madra move over frames. Interleaving them puts a bar that never
	visibly changes between two that change constantly, which teaches the eye to
	skip the whole region. Ambient is the correct register for it -- always
	available, never competing. ]]
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

-- ===================================================================
-- The target frame, top centre.
-- ===================================================================

--[[ There is no targeting system in this game. The striker raycasts along the
	camera, so "target" here means *whoever you are currently aiming at*,
	resolved client-side by mirroring the server's own ray and held briefly so
	the frame does not strobe as the reticle drifts off a moving opponent.

	Presentation only: this claims nothing, sends nothing and changes no
	outcome. It is a readout of an aim the player is already making.

	Top centre rather than WoW's top left, because the enemy is in front of you
	near the reticle, and putting their frame in the same vertical column as
	their body means a telegraph and its resolution are read in one glance. ]]
local TARGET = InterfaceSpec.Target
local targetWidth = px(TARGET.width)

local targetFrame = Instance.new("Frame")
targetFrame.Name = "TargetFrame"
targetFrame.AnchorPoint = Vector2.new(0.5, 0)
targetFrame.Position = UDim2.new(0.5, 0, 0, px(TARGET.top))
targetFrame.Size = UDim2.fromOffset(targetWidth, px(52))
targetFrame.BackgroundColor3 = PANEL
targetFrame.BackgroundTransparency = 0.12
targetFrame.BorderSizePixel = 0
targetFrame.Visible = false
targetFrame.Parent = screen
corner(targetFrame, 3)
local targetStroke = outline(targetFrame, EDGE, px(TARGET.borderThickness))

local targetName = caption(targetFrame, text(TARGET.nameTextSize), TEXT, true)
targetName.Size = UDim2.new(0.6, -px(8), 0, px(18))
targetName.Position = UDim2.fromOffset(px(8), px(3))

local targetStage = caption(targetFrame, text(TARGET.stageTextSize), TEXT_DIM, true)
targetStage.Size = UDim2.new(0.4, -px(8), 0, px(18))
targetStage.Position = UDim2.new(0.6, 0, 0, px(3))
targetStage.TextXAlignment = Enum.TextXAlignment.Right

local targetHealthRow = Instance.new("Frame")
targetHealthRow.Size = UDim2.new(1, -px(16), 0, px(TARGET.healthHeight))
targetHealthRow.Position = UDim2.fromOffset(px(8), px(22))
targetHealthRow.BackgroundTransparency = 1
targetHealthRow.Parent = targetFrame
local _targetBack, targetHealthFill = bar(targetHealthRow, px(TARGET.healthHeight), HEALTH)

local targetHealthValue = caption(targetHealthRow, text(TARGET.valueTextSize), TEXT, true)
targetHealthValue.Size = UDim2.new(1, -px(6), 1, 0)
targetHealthValue.Position = UDim2.fromOffset(px(6), 0)
targetHealthValue.TextXAlignment = Enum.TextXAlignment.Right
targetHealthValue.ZIndex = 3

--[[ The target's cast bar. The whole reason this frame exists tonight: an
	opponent's windup was, until now, completely invisible -- the server
	broadcast nothing until the technique had already resolved, so a 1.8s Tempest
	arrived instantaneously from the defender's side. ]]
local targetCast = Instance.new("Frame")
targetCast.Size = UDim2.new(1, -px(16), 0, px(CASTSPEC.targetHeight))
targetCast.Position = UDim2.fromOffset(px(8), px(22) + px(TARGET.healthHeight) + px(3))
targetCast.BackgroundColor3 = TROUGH
targetCast.BackgroundTransparency = 0.1
targetCast.BorderSizePixel = 0
targetCast.Visible = false
targetCast.Parent = targetFrame
corner(targetCast, 2)

local targetCastFill = Instance.new("Frame")
targetCastFill.Size = UDim2.fromScale(0, 1)
targetCastFill.BackgroundColor3 = READY
targetCastFill.BorderSizePixel = 0
targetCastFill.Parent = targetCast
corner(targetCastFill, 2)

local targetCastName = caption(targetCast, text(CASTSPEC.textSize), TEXT, true)
targetCastName.Size = UDim2.new(1, -px(12), 1, 0)
targetCastName.Position = UDim2.fromOffset(px(6), 0)
targetCastName.ZIndex = 3

local targetCastTimer = caption(targetCast, text(CASTSPEC.textSize), TEXT, true)
targetCastTimer.Size = UDim2.new(1, -px(12), 1, 0)
targetCastTimer.Position = UDim2.fromOffset(px(6), 0)
targetCastTimer.TextXAlignment = Enum.TextXAlignment.Right
targetCastTimer.ZIndex = 3

--[[ The bracket line. `Combat.canEngage` refuses cross-stage fights outright,
	and until now a player discovered that by attacking someone and having
	nothing whatsoever happen -- indistinguishable from a miss, from lag, or from
	a broken button. Saying it on the frame turns a mystery into a rule. ]]
local targetRefusal = caption(targetFrame, text(TARGET.stageTextSize), DANGER, true)
targetRefusal.Size = UDim2.new(1, -px(16), 0, px(14))
targetRefusal.Position = UDim2.fromOffset(px(8), px(22) + px(TARGET.healthHeight) + px(3))
targetRefusal.TextXAlignment = Enum.TextXAlignment.Center
targetRefusal.Visible = false

-- ===================================================================
-- Sense tracker, top right. Out-of-combat navigation, so it lives at an edge.
-- ===================================================================

local SENSE = InterfaceSpec.Sense
local senseWidth = px(SENSE.width)
local senseRowHeight = px(SENSE.rowHeight)

local sensePanel = Instance.new("Frame")
sensePanel.Name = "Sense"
sensePanel.AnchorPoint = Vector2.new(1, 0)
sensePanel.Position = UDim2.new(1, -px(14), 0, px(SENSE.top))
sensePanel.Size = UDim2.fromOffset(senseWidth, px(20) + senseRowHeight * SENSE.rows + px(16))
sensePanel.BackgroundColor3 = PANEL
sensePanel.BackgroundTransparency = 0.25
sensePanel.BorderSizePixel = 0
sensePanel.Parent = screen
corner(sensePanel, 3)

local senseHeader = caption(sensePanel, text(SENSE.headerTextSize), TEXT_FAINT, true)
senseHeader.Size = UDim2.new(1, -px(16), 0, px(18))
senseHeader.Position = UDim2.fromOffset(px(8), px(2))
senseHeader.Text = "AURA SENSE"

local senseRows: { TextLabel } = {}
for index = 1, SENSE.rows do
	local row = caption(sensePanel, text(SENSE.rowTextSize), TEXT_DIM, false)
	row.Size = UDim2.new(1, -px(16), 0, senseRowHeight)
	row.Position = UDim2.fromOffset(px(8), px(20) + (index - 1) * senseRowHeight)
	row.Font = Enum.Font.RobotoMono
	senseRows[index] = row
end

local senseFoot = caption(sensePanel, text(SENSE.footTextSize), TEXT_FAINT, false)
senseFoot.Size = UDim2.new(1, -px(16), 0, px(14))
senseFoot.Position = UDim2.fromOffset(px(8), px(20) + senseRowHeight * SENSE.rows)

-- ===================================================================
-- Notices, top centre above the target frame.
-- ===================================================================

local NOTICE = InterfaceSpec.Notice

local noticeFrame = Instance.new("Frame")
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

-- ===================================================================
-- Guidance: the one line that says what to do next.
-- ===================================================================

--[[ Every other piece of text in this file is a state *readout* -- stage, tier,
	power, health, madra, a list of distant dots. None of it tells a player who
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
local guidanceLabel = caption(screen, text(GUIDANCE.textSize), TEXT_DIM, false)
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

-- ===================================================================
-- State refresh.
-- ===================================================================

local function refreshCultivation()
	local stage = player:GetAttribute("Stage") or "--"
	local tier = player:GetAttribute("Tier") or 0
	local progress = player:GetAttribute("Progress") or 0
	local goal = player:GetAttribute("TierGoal") or 1
	local catalysts = player:GetAttribute("Catalysts") or 0
	local power = player:GetAttribute("Power") or 0
	local atCeiling = player:GetAttribute("AtCeiling") == true
	local stageIndex = player:GetAttribute("StageIndex")

	stageLabel.Text = `{stage}  ·  {tier}`
	if typeof(stageIndex) == "number" then
		stageLabel.TextColor3 = color(InterfaceSpec.stageColor(stageIndex))
	end

	powerLabel.Text = if catalysts > 0 then `power {power}   ◆{catalysts}` else `power {power}`

	railFill.Size = UDim2.fromScale(InterfaceSpec.fraction(progress, goal), 1)
	railFill.BackgroundColor3 = if atCeiling then CEILING else REFINEMENT

	--[[ The prompt is now *only* the actionable case. The ceiling-without-a-
		catalyst message moved to the guidance line below, because two surfaces
		saying the same thing in different words is worse than either alone --
		and because "you cannot act yet" is guidance, while "[B]" is a command. ]]
	promptFrame.Visible = atCeiling and catalysts > 0
	if promptFrame.Visible then
		promptLabel.Text = "[B]  BREAK THROUGH"
	end
end

local function refreshVitals()
	local health = player:GetAttribute("Health") or 0
	local maxHealth = player:GetAttribute("MaxHealth") or 0
	local madra = player:GetAttribute("Madra") or 0
	local maxMadra = player:GetAttribute("MaxMadra") or 0

	local healthFraction = InterfaceSpec.fraction(health, maxHealth)
	healthFill.Size = UDim2.fromScale(healthFraction, 1)
	healthFill.BackgroundColor3 = if healthFraction <= VITALS.lowHealthFraction
		then HEALTH_LOW
		else HEALTH
	healthValue.Text = `{InterfaceSpec.commas(health)} / {InterfaceSpec.commas(maxHealth)}`

	madraFill.Size = UDim2.fromScale(InterfaceSpec.fraction(madra, maxMadra), 1)
	madraValue.Text = `{InterfaceSpec.commas(madra)} / {InterfaceSpec.commas(maxMadra)}`
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
local currentTarget: Player? = nil
local aimOnTarget = false

local cooldownUntil: { [string]: number } = {}
local gcdUntil = 0

local function slotTechnique(slot: string): Config.Technique?
	local techId = player:GetAttribute("Slot_" .. slot)
	if typeof(techId) ~= "string" then
		return nil
	end
	return Config.Techniques[techId]
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
	local ownStage = player:GetAttribute("StageIndex")
	if typeof(ownStage) ~= "number" then
		return false
	end

	for _, other in Players:GetPlayers() do
		if other == player then
			continue
		end
		if other:GetAttribute("StageIndex") ~= ownStage then
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
	local ownStage = player:GetAttribute("StageIndex")
	local theirStage = currentTarget:GetAttribute("StageIndex")
	return typeof(ownStage) == "number" and ownStage == theirStage
end

local function refreshSlots()
	local now = os.clock()
	local madra = player:GetAttribute("Madra") or 0
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
			widget.sweep.Size = UDim2.fromScale(1, 0)
			widget.gcd.Visible = false
			continue
		end

		widget.name.Text = tech.name
		widget.cost.Text = tostring(tech.madraCost)
		local kind = color(InterfaceSpec.kindColor(tech.kind))
		widget.stripe.BackgroundColor3 = kind

		local remaining = (cooldownUntil[tech.id] or 0) - now
		local affordable = madra >= tech.madraCost

		if remaining > 0 and tech.cooldown > 0 then
			widget.sweep.Size = UDim2.fromScale(1, math.clamp(remaining / tech.cooldown, 0, 1))
			widget.stroke.Color = COOLING
			widget.name.TextColor3 = TEXT_FAINT
			widget.cost.TextColor3 = TEXT_FAINT
			widget.stripe.BackgroundTransparency = 0.6
			widget.countdown.Text = if remaining >= SLOT.countdownMinSeconds
				then InterfaceSpec.countdown(remaining)
				else ""
		else
			widget.sweep.Size = UDim2.fromScale(1, 0)
			widget.countdown.Text = ""
			widget.stripe.BackgroundTransparency = 0
			widget.stroke.Color = if affordable then kind else UNAFFORDABLE
			widget.name.TextColor3 = if affordable then TEXT else UNAFFORDABLE
			widget.cost.TextColor3 = if affordable then MADRA else UNAFFORDABLE
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

-- ===================================================================
-- Soft targeting.
-- ===================================================================

local targetSeenAt = 0
local lastPoll = 0

local function playerFromInstance(instance: Instance): Player?
	local model = instance:FindFirstAncestorWhichIsA("Model")
	while model do
		local found = Players:GetPlayerFromCharacter(model)
		if found then
			return found
		end
		model = model:FindFirstAncestorWhichIsA("Model")
	end
	return nil
end

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
	local found = if hit then playerFromInstance(hit.Instance) else nil
	aimOnTarget = found ~= nil and found ~= player
	if found and found ~= player then
		currentTarget = found
		targetSeenAt = now
	elseif currentTarget and now - targetSeenAt > TARGET.stickySeconds then
		currentTarget = nil
	end
end

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
local RETICLE_GAP = px(5)
local RETICLE_LEN = px(6)
local RETICLE_THICK = math.max(px(2), 2)

local reticle = Instance.new("Frame")
reticle.Name = "Reticle"
reticle.AnchorPoint = Vector2.new(0.5, 0.5)
reticle.Position = UDim2.fromScale(0.5, 0.5)
reticle.Size = UDim2.fromOffset(px(40), px(40))
reticle.BackgroundTransparency = 1
reticle.Parent = screen

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
	tick.BackgroundTransparency = 0.45
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

local function refreshReticle()
	local tint = TEXT
	local transparency = 0.45

	if aimOnTarget and currentTarget then
		local ownStage = player:GetAttribute("StageIndex")
		local theirStage = currentTarget:GetAttribute("StageIndex")
		local sameBracket = typeof(ownStage) == "number"
			and typeof(theirStage) == "number"
			and ownStage == theirStage
		-- Lit for a fight you can have, dim red for one the bracket refuses.
		tint = if sameBracket then READY else UNAFFORDABLE
		transparency = if sameBracket then 0 else 0.25
	end

	for _, tick in reticleTicks do
		tick.BackgroundColor3 = tint
		tick.BackgroundTransparency = transparency
	end
end

local function refreshTarget()
	local target = currentTarget
	if not target or not target.Parent or not target.Character then
		targetFrame.Visible = false
		return
	end

	targetFrame.Visible = true
	targetName.Text = target.DisplayName

	local stage = target:GetAttribute("Stage")
	local tier = target:GetAttribute("Tier")
	local stageIndex = target:GetAttribute("StageIndex")
	targetStage.Text = if typeof(stage) == "string" and typeof(tier) == "number"
		then `{stage}  ·  {tier}`
		else "--"
	if typeof(stageIndex) == "number" then
		targetName.TextColor3 = color(InterfaceSpec.stageColor(stageIndex))
	end

	local health = target:GetAttribute("Health")
	local maxHealth = target:GetAttribute("MaxHealth")
	local numericHealth = if typeof(health) == "number" then health else 0
	local numericMax = if typeof(maxHealth) == "number" then maxHealth else 0
	local fraction = InterfaceSpec.fraction(numericHealth, numericMax)
	targetHealthFill.Size = UDim2.fromScale(fraction, 1)
	targetHealthFill.BackgroundColor3 = if fraction <= VITALS.lowHealthFraction
		then HEALTH_LOW
		else HEALTH
	targetHealthValue.Text =
		`{InterfaceSpec.commas(numericHealth)} / {InterfaceSpec.commas(numericMax)}`

	-- Bracket check, mirroring Combat.canEngage's only rule.
	local ownStage = player:GetAttribute("StageIndex")
	local sameBracket = typeof(ownStage) == "number"
		and typeof(stageIndex) == "number"
		and ownStage == stageIndex

	local cast = Nameplates.castOf(target.UserId)
	local drawingCast = cast ~= nil and InterfaceSpec.telegraphs(cast.windup)

	if not sameBracket then
		targetStroke.Color = DANGER
		targetRefusal.Visible = not drawingCast
		targetRefusal.Text = "different bracket — neither of you can hit the other"
	else
		targetStroke.Color = EDGE
		targetRefusal.Visible = false
	end

	if cast and drawingCast then
		local elapsed = os.clock() - cast.startedAt
		local remaining = math.max(cast.windup - elapsed, 0)
		targetCast.Visible = true
		targetCastFill.Size = UDim2.fromScale(math.clamp(elapsed / cast.windup, 0, 1), 1)
		targetCastFill.BackgroundColor3 = color(InterfaceSpec.kindColor(cast.kind))
		local tech = Config.Techniques[cast.techId]
		targetCastName.Text = if tech then string.upper(tech.name) else string.upper(cast.techId)
		targetCastTimer.Text = string.format("%.1f", remaining)
	else
		targetCast.Visible = false
	end
end

-- ===================================================================
-- Own cast bar.
-- ===================================================================

local ownCast: Nameplates.Cast? = nil

local function refreshOwnCast()
	local cast = ownCast
	if not cast then
		castFrame.Visible = false
		return
	end
	local now = os.clock()
	local elapsed = now - cast.startedAt
	if elapsed > cast.windup + CASTSPEC.holdSeconds then
		ownCast = nil
		castFrame.Visible = false
		return
	end
	if not InterfaceSpec.telegraphs(cast.windup) then
		castFrame.Visible = false
		return
	end

	local tech = Config.Techniques[cast.techId]
	castFrame.Visible = true
	castFill.Size = UDim2.fromScale(math.clamp(elapsed / cast.windup, 0, 1), 1)
	castFill.BackgroundColor3 = color(InterfaceSpec.kindColor(cast.kind))
	castName.Text = if tech then string.upper(tech.name) else string.upper(cast.techId)
	castTimer.Text = string.format("%.1f", math.max(cast.windup - elapsed, 0))
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

local function refreshSense(nodes: { any })
	for index, row in senseRows do
		local entry = nodes[index]
		if not entry then
			row.Text = ""
			continue
		end
		row.TextColor3 = TIER_COLOR[entry.tier] or TEXT_DIM
		row.Text = string.format(
			"%s %-6s %4d  %d/%d",
			arrowTo(entry.x, entry.z),
			entry.tier,
			math.floor(entry.distance),
			entry.occupants,
			entry.capacity
		)
	end

	local senseRange = player:GetAttribute("SenseRange") or 0
	senseFoot.Text = if senseRange <= 0
		then "no aura sense at this stage"
		elseif #nodes == 0 then "nothing within range"
		elseif #nodes > #senseRows then `+{#nodes - #senseRows} more`
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

	noticeLabel.TextColor3 = NOTICE_COLOR[kind] or CEILING
	noticeLabel.TextSize = text(NOTICE.textSize * weight.scale)
	noticeLabel.Text = message
	noticeFrame.Visible = true

	task.delay(weight.seconds, function()
		if noticeToken == token then
			noticeFrame.Visible = false
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
}
local VITAL_ATTRIBUTES = { "Health", "MaxHealth", "Madra", "MaxMadra" }

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
	Nameplates.noteCast(
		casterId,
		tostring(event.techId),
		tostring(event.kind),
		tonumber(event.windup) or 0
	)
	if casterId == player.UserId then
		ownCast = Nameplates.castOf(casterId)
	end
end)

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
		return "Refinement comes only from aura nodes. Follow your sense."
	end
	if senseRange <= 0 then
		return "No aura sense at this stage. Search on foot."
	end
	return "No aura within reach. Move."
end

local function refreshGuidance()
	guidanceLabel.Text = guidanceText()
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

--[[ The card waits for cultivation state rather than firing at load, so it can
	name the stage the player actually spawned into. ]]
task.spawn(function()
	for _ = 1, 100 do
		if typeof(player:GetAttribute("Stage")) == "string" then
			break
		end
		task.wait(0.1)
	end
	showCard()
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
	useTechnique:FireServer(slot, if camera then camera.CFrame.LookVector else nil)
end

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

	Options are enumerated from the replicated `Config`, ordered by madra cost so
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
		if left.madraCost ~= right.madraCost then
			return left.madraCost < right.madraCost
		end
		-- Ties broken by id so the order is stable across clients and sessions.
		return a < b
	end)
	optionsBySlot[slot] = options
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
	if nextId and nextId ~= current and setLoadout and setLoadout:IsA("RemoteEvent") then
		(setLoadout :: RemoteEvent):FireServer(slot, nextId)
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
		dismissCard()
		fireSlot(widget.slot)
	end)
	--[[ Right-click cycles the slot, as a second route to the same thing the
		Shift chord does. Two ways in, because a player who never finds either
		concludes every character in this game is identical. ]]
	widget.root.MouseButton2Click:Connect(function()
		dismissCard()
		cycleSlot(widget.slot)
	end)
end

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	--[[ Any input at all retires the card, ahead of the `processed` guard and
		ahead of every other check. A player who has started doing things does
		not need to be told to start doing things, and the card outstaying its
		welcome is the one way a non-interactive overlay can still annoy. ]]
	dismissCard()
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
	end
end)
