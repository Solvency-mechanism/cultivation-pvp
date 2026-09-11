--!strict
--[[
	Interface tuning: the geometry, palette and curves behind the HUD.

	Pure data and pure math, in the shape `ImpactSpec` established. No requires
	and no Roblox datatypes -- colours are RGB triples rather than Color3 -- so
	this module loads unchanged under both Roblox and Lune like every other
	module in src/shared/.

	It goes one step further than the house rule asks: `ImpactSpec` takes
	`Config` as a parameter because its severity curve genuinely needs stage
	data, and nothing here does. Every function below closes over its own
	arguments alone. That is worth stating rather than leaving to be discovered,
	because the obvious way to extend this file -- a helper that wants a
	technique's cost or a stage's name -- should take `Config` as an argument
	when it arrives, and must never reach for a require.

	**Density is a ratio, not a pixel count.** This is the one idea here and the
	rest follows from it. Moving from the Roblox-traditional register to the WoW
	one means more information per unit of screen, and the naive way to get there
	-- shrink every font -- produces a HUD that is dense on a monitor and
	illegible on a phone, which is where most of this platform plays. So every
	size below is quoted against a 1080-tall reference viewport and passed
	through `InterfaceSpec.scale`, which grows the whole interface on small
	screens rather than letting it collapse. A phone gets the same *layout* at a
	larger absolute size, not a miniature of the desktop one.

	The second idea: **the resting HUD is small and the busy HUD is dense.**
	Elements that spend most of their life at a constant value are not drawn at
	that value -- a cast bar with nothing casting, a breakthrough prompt with no
	ceiling reached. Attention is the budget, and progressive disclosure is how
	an eleven-quantity interface stays readable.
]]

export type Rgb = { r: number, g: number, b: number }

local InterfaceSpec = {}

--[[ The palette.

	Deliberately continuous with `ImpactSpec.Palette`, because the HUD and the
	impact layer are read in the same glance and must not contradict each other.
	Three meanings are already spoken for there and are not reused here for
	anything else:

		white  -- damage you dealt
		red    -- damage you took
		gold   -- a killing blow

	So the HUD's red appears only on the health bar and on danger, where it means
	the same thing the vignette does; and gold appears only at genuine threshold
	moments (refinement ceiling, a technique becoming available) rather than as
	decoration. Everything else carries its meaning in *value contrast* -- bright
	fill against a near-black trough -- exactly as the impact grammar does, so the
	interface stays legible at distance, at small size, and to a player who
	cannot separate the hues at all. ]]
InterfaceSpec.Palette = {
	-- Panel grounds. Near-black, so a bright fill on top of one is the loudest
	-- thing in that region of screen.
	panel = { r = 10, g = 11, b = 16 } :: Rgb,
	trough = { r = 26, g = 28, b = 38 } :: Rgb,
	edge = { r = 62, g = 66, b = 84 } :: Rgb,

	text = { r = 232, g = 236, b = 246 } :: Rgb,
	textDim = { r = 146, g = 153, b = 176 } :: Rgb,
	textFaint = { r = 96, g = 102, b = 124 } :: Rgb,

	-- Vitals. Health red agrees with `ImpactSpec.Palette.vignette`'s meaning.
	health = { r = 208, g = 62, b = 62 } :: Rgb,
	healthLow = { r = 244, g = 96, b = 76 } :: Rgb,
	madra = { r = 96, g = 124, b = 255 } :: Rgb,

	-- Progression. Blue while climbing, gold at the ceiling -- the one place
	-- gold is allowed outside a killing blow, because it is the same kind of
	-- event: a threshold crossed.
	refinement = { r = 108, g = 178, b = 248 } :: Rgb,
	ceiling = { r = 255, g = 195, b = 90 } :: Rgb,

	-- States on a slot.
	ready = { r = 150, g = 200, b = 255 } :: Rgb,
	cooling = { r = 58, g = 62, b = 82 } :: Rgb,
	unaffordable = { r = 150, g = 68, b = 74 } :: Rgb,
	scrim = { r = 6, g = 7, b = 11 } :: Rgb,

	-- Danger. The target frame border when the bracket refuses the fight, and
	-- anything else the player must not miss.
	danger = { r = 226, g = 88, b = 84 } :: Rgb,

	keybind = { r = 255, g = 214, b = 138 } :: Rgb,

	--[[ The lock. A choice the player made, as against the aim which is a
		readout. Warm and distinct from every kind colour and from the three
		meanings the impact layer owns, so a locked frame is not mistaken for a
		ready slot, a striker, or a killing blow. ]]
	lock = { r = 255, g = 176, b = 96 } :: Rgb,

	--[[ A slow. The first status effect this game has ever shown, so it gets
		its own hue rather than borrowing one: cold, desaturated, and unlike
		every kind colour, the lock, and the three meanings the impact layer
		owns. It has to read as "something is on you" on a plate at distance
		and as "something is on me" beside your own vitals, and be the same
		colour in both places. ]]
	slow = { r = 168, g = 214, b = 232 } :: Rgb,
}

--[[ One colour per technique kind, and the reason it is per *kind* rather than
	per technique.

	Round 8 takes the pool from fifteen techniques toward sixty-plus. Five kinds
	is a vocabulary a player learns in one session; sixty is not. A cast bar and
	a slot border therefore say *what kind of thing is happening* -- something
	left fast, armour going on, something placed, the ground answering, someone
	moved -- and the technique's name is printed for the reader who has time to
	read it. This mirrors `ImpactSpec.Cast.byKind`, which already made exactly
	this call for audio: four sounds for twelve techniques, told apart by pitch.

	None of these is near the white/red/gold the impact layer owns. ]]
InterfaceSpec.KindColor = {
	striker = { r = 138, g = 190, b = 255 } :: Rgb,
	enforcer = { r = 214, g = 146, b = 74 } :: Rgb,
	forger = { r = 104, g = 202, b = 158 } :: Rgb,
	ruler = { r = 172, g = 122, b = 250 } :: Rgb,
	-- Not a legal kind yet -- `strider` lands with round 6's movement pass. The
	-- entry exists now so the slot bar does not fall back to grey the day it
	-- does, which is the same failure `ImpactSpec.Cast.byKind` is flagged for.
	strider = { r = 96, g = 220, b = 226 } :: Rgb,
}

--[[ The ladder read as colour, for nameplates and the target frame.

	Knowingly a second copy of `PresenceService.STAGE_COLOR`, which owns the
	same ramp for the worn aura. They must agree -- a player whose aura burns
	jade-green and whose nameplate reads gold is worse than either alone -- and
	the honest fix is for PresenceService to read this table. That is a
	cross-domain edit to a server file on a four-hour clock, so it is flagged
	here rather than made: **if you change one ramp, change both.** ]]
InterfaceSpec.StageColor = {
	{ r = 126, g = 132, b = 148 } :: Rgb, -- foundation
	{ r = 184, g = 115, b = 74 } :: Rgb, -- copper
	{ r = 150, g = 160, b = 176 } :: Rgb, -- iron
	{ r = 96, g = 196, b = 150 } :: Rgb, -- jade
	{ r = 240, g = 196, b = 96 } :: Rgb, -- lowgold
	{ r = 252, g = 168, b = 58 } :: Rgb, -- highgold
	{ r = 255, g = 244, b = 168 } :: Rgb, -- truegold
}

function InterfaceSpec.stageColor(stageIndex: number): Rgb
	local ramp = InterfaceSpec.StageColor
	return ramp[stageIndex] or ramp[#ramp]
end

--[[ Nameplates.

	The highest-value pixels on screen tonight: this game has never been run
	with two players, so until now there has literally been nothing above another
	cultivator's head but a stage name. Health and a cast bar go up there because
	there is no tab-target in this game -- nameplates are how you read the *other*
	three people in a node fight, not just the one you are aiming at, which makes
	them carry more weight here than they do in the game this register is
	borrowed from.

	Sized in pixels rather than studs, for the same reason `ImpactSpec.Number`
	is: a plate has to be readable across a Ruler radius, and one that shrinks
	with distance stops being readable exactly when a fight is spreading out. ]]
InterfaceSpec.Plate = {
	width = 158,
	--[[ Clearance above the TOP of whatever the plate anchors to, not above its
		centre. `Nameplates` adds half the anchor's height before applying this.

		2.6 rather than the 3.2 it was, and the difference is exactly half a
		player's head: the flat 3.2 was measured from a Head's centre, so keeping
		it while switching to a top-edge measurement would have nudged every
		verified-working player plate upward. Recomputed so a player's plate
		lands in precisely the same place it already does, and a dummy's clears
		its five-stud slab instead of floating inside it. ]]
	studsOffset = 2.6,
	nameTextSize = 13,
	stageTextSize = 11,
	healthHeight = 8,
	castHeight = 7,
	rowGap = 2,
	-- Beyond this a plate is clutter rather than information. Matches the 260
	-- PresenceService already uses for the stage plate, so the two vanish
	-- together rather than leaving a headless health bar floating.
	maxDistance = 260,
}

--[[ Viewport scaling.

	Reference is a 1080-tall viewport. Below that the interface grows relative to
	the screen rather than shrinking with it: a phone at 480 logical pixels tall
	gets roughly 1.35x, so a 12px caption renders at ~16px and stays readable at
	arm's length. Above 1080 it grows only slightly, because a 1440p monitor is
	not viewed from proportionally further away.

	Clamped at both ends. An unclamped ratio on an unusual viewport is how a HUD
	ends up either invisible or covering the whole screen. ]]
InterfaceSpec.Scale = {
	referenceHeight = 1080,
	minScale = 0.85,
	maxScale = 1.6,
	-- Below this the viewport is a phone and density has to be bought back.
	smallHeight = 600,
	smallScale = 1.34,

	--[[ The ceiling that was missing.

		The curve above is a *floor* for legibility: below 600px it pins the
		scale at 1.34 so text stays readable. It had no matching ceiling for
		footprint, and the two are not the same constraint -- as a viewport gets
		shorter, a fixed-pixel stack keeps its absolute size and eventually eats
		the screen. Measured before this cap existed: at 450px the bottom cluster
		took 47% of the frame and the guidance line sat at 53%, dead centre; at
		320px it took 66%.

		That was not only a tiny-window problem. A phone in landscape is 854x480
		-- precisely the case the small-screen branch was written for -- and it
		took 44%. The scale curve was solving legibility on exactly the device
		whose screen it was consuming.

		So: the stack may not exceed this fraction of viewport height, whatever
		legibility would prefer. 700px and up are unaffected, because the curve
		already returns less than the cap there. ]]
	stackBudget = 0.38,
}

--[[ Guidance line geometry, which the footprint cap has to know about because
	the line sits above the cluster and is part of the same stack. ]]
InterfaceSpec.Guidance = {
	width = 520,
	height = 18,
	textSize = 12,
	-- Space between the guidance line and the top of the cluster.
	gap = 10,
}

--[[ The full height of the bottom stack at scale 1: vitals, cast bar, action
	bar, the margin under it, and the guidance line above it.

	Summed from the specs rather than written as a constant, so it cannot drift
	when a bar height or the slot size changes -- a stale literal here would make
	the footprint cap silently wrong in the direction of "looks fine on my
	monitor", which is the failure it exists to prevent. ]]
function InterfaceSpec.stackHeight(): number
	local vitals = InterfaceSpec.Vitals
	local slot = InterfaceSpec.Slot
	local cast = InterfaceSpec.Cast
	local guidance = InterfaceSpec.Guidance
	local header = vitals.headerTextSize + 4
	local cluster = header
		+ vitals.healthHeight
		+ vitals.rowGap
		+ vitals.madraHeight
		+ vitals.stackGap
		+ cast.height
		+ vitals.stackGap
		+ slot.size
	return cluster + slot.bottomMargin + guidance.gap + guidance.height
end

function InterfaceSpec.scale(viewportHeight: number): number
	local spec = InterfaceSpec.Scale
	if viewportHeight <= 0 then
		return 1
	end
	local ratio: number
	if viewportHeight <= spec.smallHeight then
		ratio = spec.smallScale
	else
		-- Between phone and reference, ease from the small scale back to 1 so a
		-- tablet is not treated as either.
		local t = math.clamp(
			(viewportHeight - spec.smallHeight) / (spec.referenceHeight - spec.smallHeight),
			0,
			1
		)
		ratio = spec.smallScale + (1 - spec.smallScale) * t
	end
	if viewportHeight > spec.referenceHeight then
		-- Grow with the square root of the excess, not linearly.
		ratio = math.sqrt(viewportHeight / spec.referenceHeight)
	end

	--[[ Footprint cap. Legibility asks for a bigger interface on a small screen;
		this is the limit past which a bigger interface stops being an interface
		and becomes the screen. Applied after the curve rather than inside it, so
		the reasoning stays two separable ideas: how big should this be to read,
		and how big is it allowed to get. ]]
	local budget = (spec.stackBudget * viewportHeight) / InterfaceSpec.stackHeight()
	ratio = math.min(ratio, budget)

	--[[ `minScale` deliberately wins over the cap at the very bottom. Below
		roughly 390px there is no scale that both fits the budget and keeps text
		legible, and a HUD too small to read is a worse answer than one that is
		too large. The trade is stated here and asserted in the suite rather than
		being an accident of clamp ordering. ]]
	return math.clamp(ratio, spec.minScale, spec.maxScale)
end

--[[ The action bar.

	Square icon slots rather than the wide name-plates the previous HUD used.
	This is what buys the fifth slot: five 58px squares with 6px gaps is 314px,
	*narrower* than the four 108px slots it replaces, which came to 468px. The
	movement pass flagged a five-slot bar as a phone-width worry it could not
	resolve; at this geometry the worry does not arise. ]]
InterfaceSpec.Slot = {
	size = 58,
	gap = 6,
	bottomMargin = 16,
	cornerRadius = 4,
	-- The kind stripe along the bottom of each slot: the icon-family signal,
	-- standing in for art nobody has drawn yet.
	stripeHeight = 4,

	keyTextSize = 12,
	nameTextSize = 11,
	costTextSize = 10,
	-- The cooldown countdown printed over the slot, OmniCC-style. Large,
	-- because it is read peripherally, and it is the only text on the slot that
	-- matters while it is showing.
	countdownTextSize = 20,
	-- Below this, a countdown is noise -- the sweep alone carries a sub-second
	-- cooldown better than a number flickering through two digits.
	countdownMinSeconds = 0.7,

	-- How dark the cooldown scrim is over the icon.
	scrimTransparency = 0.42,
	--[[ Radial wedge rather than vertical drain. Behind a switch because the
		wedge has not been seen running: if it looks wrong in Studio this is one
		line back to the drain rather than a revert, and the drain stays built
		beneath it for exactly that reason. ]]
	radialSweep = true,
	-- The global cooldown is a *different* fact from a technique cooldown -- it
	-- affects every slot at once and is always short -- so it draws as a thin
	-- sweep across the bottom of every slot rather than as a second scrim.
	gcdBarHeight = 3,

	--[[ The reach pip: is there anything for this technique to touch right now.

		A new channel rather than a fourth meaning layered onto an existing one.
		Border colour, name colour, cost colour and stripe transparency are all
		already carrying ready / cooling / cannot-afford between them, and a 58px
		square stops being readable if any of them has to say two things at once.

		Deliberately small and quiet. This is a *soft* state -- unlike a cooldown
		or an empty madra pool, nothing refuses the press. It is information
		about the world, not about the button. ]]
	reachPip = 5,
}

--[[ Which kinds have a reach that can fail, and which do not.

	`forger` and `enforcer` are absent on purpose and their absence is the
	statement: a construct dropped with nobody nearby is legitimate zoning, and a
	self-buff has no reach at all. Showing either of them an "out of reach" state
	would invent a failure that does not exist, and a player who saw it would
	reasonably conclude the technique was unusable.

	Keyed by kind rather than by technique, so a roster of sixty-plus needs no
	entries added here. ]]
InterfaceSpec.ReachKind = {
	striker = true,
	ruler = true,
}

function InterfaceSpec.hasReach(kind: string): boolean
	return InterfaceSpec.ReachKind[kind] == true
end

--[[ Vitals, anchored directly above the action bar.

	The single most consequential layout decision here. The previous HUD put
	health in the bottom-left corner and abilities in the bottom centre, which
	costs a diagonal saccade of most of the screen and back, mid-exchange, every
	time you want to know whether you are winning. Stacking vitals on the action
	bar collapses that to a few degrees of eye travel.

	Health is widest and tallest because it is checked most. Madra is the same
	*shape* on purpose -- both are depth-of-reserve quantities that drain and
	refill -- and is told apart by size and hue. The resources round 7 adds are
	deliberately *not* bars, so that this similarity stays meaningful. ]]
InterfaceSpec.Vitals = {
	width = 316,
	healthHeight = 17,
	madraHeight = 10,
	rowGap = 3,
	-- Space between the vitals block and the cast bar under it.
	stackGap = 7,
	-- Numbers sit at the ends of a bar, not centred in it. Centred numbers
	-- fight the fill for the same pixels; at the end they read as an annotation
	-- on a shape rather than as competition with it.
	valueTextSize = 11,
	labelTextSize = 11,
	headerTextSize = 12,
	-- Below this fraction the health bar switches to the brighter, more urgent
	-- hue. A threshold rather than a gradient: a gradient is not perceptible
	-- peripherally, a switch is.
	lowHealthFraction = 0.3,
}

--[[ Cast bars, for the player and for the target.

	`windupFloor` is the honest limit. A technique with a 0.06s windup cannot
	have a cast bar -- it would appear and vanish inside two frames, and the
	real cost of that is not that it is useless but that it *trains the eye to
	look for something that is not reliably there*. Anything under the floor
	gets a single bright flash instead, which says "a thing happened" without
	promising a duration that could have been read. ]]
InterfaceSpec.Cast = {
	width = 268,
	height = 15,
	targetWidth = 296,
	targetHeight = 13,
	textSize = 11,
	windupFloor = 0.15,
	flashSeconds = 0.18,
	-- A finished cast holds for a beat before clearing, so a fast technique
	-- does not simply blink out of existence the instant it lands.
	holdSeconds = 0.12,
	--[[ How long a bar shows its snap after an interrupt or a fizzle. Long
		enough to be seen as an event -- the bar did not finish, it broke --
		and short enough that a defender who just interrupted someone is not
		staring at a red bar while the next thing happens. ]]
	snapSeconds = 0.35,
}

--[[ The target frame.

	There is no targeting system in this game -- the striker raycasts along the
	camera -- so "target" here means *whoever you are currently aiming at*,
	resolved client-side and held briefly so the frame does not strobe as the
	reticle drifts off a moving opponent. `stickySeconds` is that hold. Long
	enough to survive a strafe, short enough that walking away from someone
	clears them. ]]
InterfaceSpec.Target = {
	width = 296,
	top = 54,
	nameTextSize = 13,
	stageTextSize = 11,
	healthHeight = 16,
	valueTextSize = 11,
	stickySeconds = 3.0,
	--[[ How long a locked target may stay out of reach before the lock lets
		go. Long enough to survive them stepping behind a pillar; short enough
		that walking away from someone clears them. ]]
	lockReachGrace = 4.0,
	-- How often the aim ray is cast. Every frame is wasteful for something a
	-- human reads a few times a second.
	pollSeconds = 0.08,
	borderThickness = 1,
}

--[[ The refinement rail.

	Demoted out of the combat cluster entirely. Refinement moves over hours;
	health and madra move over frames. Interleaving them puts a bar that never
	visibly changes between two that change constantly, which teaches the eye to
	skip the whole region. As a thin full-width rail at the very bottom edge it
	is ambient -- always available, never competing. ]]
InterfaceSpec.Rail = {
	height = 3,
	ceilingHeight = 5,
}

--[[ The sense tracker.

	Out-of-combat navigation, so it goes to an edge. Small type is *correct*
	here and nowhere else in this file: you read it while walking, not while
	fighting, and density costs nothing when there is no time pressure. That is
	the honest version of "dense and small" -- applied where the read is
	unhurried rather than uniformly. ]]
InterfaceSpec.Sense = {
	width = 196,

	--[[ Left edge, vertically centred, and the reason is that every corner is
		already spoken for.

		This panel sat in the top right and was occluded by Roblox's own player
		list, which lives in that corner, cannot be moved, and got a reason to be
		open the moment leaderstats shipped. Losing it matters more than losing
		any other panel: bearing, distance and occupancy are the only instruments
		this game gives you for *finding* anything, so the occluded panel was the
		one you navigate by.

		Roblox owns three of the four corners and it owns them on every platform:
		the menu button and chat top left, the player list top right, and on touch
		the movement stick bottom left with jump bottom right. The bottom centre
		is the action bar's and is not negotiable. That leaves the vertical edges,
		and the left edge at mid height is clear of chat above it and of the
		thumbstick below it.

		Worth writing down rather than rediscovering: **the corners are gone.**
		The next element that wants one will hit exactly this, and the answer will
		be an edge again. ]]
	side = 14,
	rowHeight = 17,
	rows = 6,
	headerTextSize = 11,
	rowTextSize = 11,
	footTextSize = 10,

	--[[ A column header row.

		Each sense row packs four facts -- bearing, tier, distance, occupancy --
		into one monospaced line with nothing naming any of them. That was flagged
		as a teaching gap and then deferred twice under a deadline: a player can
		read `> rare  84  1/3` for an hour without learning that the last pair is
		how many of three places are taken, which is the single fact that decides
		whether walking there is worth it.

		Cheap to fix and worth the fourteen pixels, because this panel is read
		while walking rather than while fighting -- density costs nothing where
		there is no time pressure, which is the same reason the rows are allowed
		to be small in the first place. ]]
	columnHeight = 13,
	columnTextSize = 10,
}

--[[ The loadout picker: the whole pool, visible, swappable.

	A development affordance, gated on `Config.Profile` exactly as the tuning
	numbers are. The ask was "just for testing purposes for right now", which is
	a lifetime, and this project now has a place to put things with that
	lifetime -- so it cannot ship by accident and it disappears on release with
	no deletion and nothing to remember.

	**Grouped by kind rather than listed flat, because the grouping is the rule.**
	One slot per kind is the constraint that makes a loadout a loadout, and a flat
	list of fifteen names hides it. Laid out as a row per kind with the current
	pick marked, the panel explains the system by its shape: picking a new striker
	visibly replaces your striker and touches nothing else. That is worth more
	than a tidier list.

	**A toggle rather than furniture.** Fifteen techniques is not a small panel,
	there are no corners left, and the HUD's job during a fight is to stay
	readable. It opens, it is used, it closes.

	What it quietly fixes: the playtest brief had to spend a paragraph warning
	that the swap is the one nobody finds on their own, and that four friends who
	never press Shift all play the identical character. That was a documentation
	patch over a discoverability hole. Nobody *chooses* to be unaware the pool
	exists -- that is an accident, not a decision, so the right fix removes it
	rather than explaining it. ]]
InterfaceSpec.Picker = {
	width = 470,
	padding = 12,
	headerHeight = 22,
	kindLabelWidth = 74,
	-- Space between one kind's block and the next.
	blockGap = 8,
	--[[ Chips are a fixed size and WRAP, rather than being sized to fit the
		row. The roster pass takes the pool from fifteen techniques to thirty --
		six to eight per kind -- and a chip sized as `available / count` would be
		a third its current width by then. Fixed cells hand the wrapping to the
		engine, so the option count is something the panel discovers rather than
		something this file has to be told. ]]
	chipWidth = 116,
	chipHeight = 26,
	chipGap = 5,
	-- The body scrolls past this fraction of the viewport, so a pool of any
	-- size stays on screen and never over the bar it edits.
	maxHeightFraction = 0.5,
	titleTextSize = 13,
	kindTextSize = 11,
	chipTextSize = 11,
	footTextSize = 10,
	-- Dimmed rather than hidden when a swap would be refused, so the panel
	-- explains the refusal instead of appearing to lose an option.
	unavailableTransparency = 0.55,
}

--[[ The reticle's resting weight.

	It was 0.45 -- deliberately quiet, because a loud crosshair at screen
	centre for the whole session is exactly the clutter this HUD exists to
	refuse. Then a tester who knew precisely what to look for, and where,
	could not find it in two honest magnified crops over a dark-haired
	character. In third person the reticle sits over your own character's head
	and shoulders essentially always, which is the busiest background on the
	screen, and a two-pixel light tick at 45% over dark hair is mid-grey on
	dark. 0.25 keeps it quiet and makes it findable; the lit state on a valid
	target is unchanged at fully opaque, which is the state that matters. ]]
InterfaceSpec.Reticle = {
	idleTransparency = 0.25,
}

--[[ Status cues: the first one is a slow.

	Two places show it, deliberately in the same colour and the same word. On
	another combatant's nameplate the third row -- the one a cast bar borrows --
	says SLOWED with the multiplier, outranked only by a cast in progress, since
	what they are about to do beats what has been done to them. On your own
	vitals a chip says the same beside madra, because a slow is the first thing
	in this game that changes what your own keys do, and the vitals are where
	you look to learn that. ]]
InterfaceSpec.Status = {
	chipHeight = 14,
	chipTextSize = 10,
	-- Below this the multiplier is not worth a decimal; "SLOWED" alone is the
	-- read, and the number is for the reader who has time.
	showMultiplier = true,
}

--[[ Projectile dressing. The server owns the part and its motion entirely; the
	client adds a trail and a light to a part that is already moving, and
	destroys nothing -- the dressing dies with the part. Sized in studs against
	the 1.4-stud ball the server spawns. ]]
InterfaceSpec.Projectile = {
	trailLifetime = 0.22,
	trailWidth = 1.1,
	lightRange = 9,
	lightBrightness = 2.2,
}

InterfaceSpec.Notice = {
	width = 460,
	top = 14,
	height = 26,
	textSize = 13,
	seconds = 6,
}

--[[ Not every notice is the same size of event, and until now the channel
	treated them as though they were: one line, one weight, first-come
	first-served, six seconds each.

	That is fine for telegraphs and refusals. It is wrong for a kill and badly
	wrong for a death. A death costs 35% of a refinement tier -- the single most
	consequential thing that happens to a player -- and it currently arrives, if
	it arrives at all, in the same grey as "your cultivation resumes where you
	left it". Meanwhile the *killer* is already well served: `ImpactSpec` gives a
	killing blow a gold oversized number, a gold marker and a glassbreak. The
	asymmetry is the bug. The victim's side of the most dramatic moment in the
	loop is the empty one.

	So a notice kind now carries three things beyond its colour:

	`scale`    -- glyph size against the base, because weight is read as size
	             before it is read as hue, and the impact grammar already makes
	             exactly this argument about damage numbers.
	`seconds`  -- how long it holds. A death should outlast a node telegraph.
	`priority` -- and this is the one that matters. The channel has a single
	             slot, so without a priority a Prime-node announcement landing
	             half a second after a kill simply erases it. A notice cannot be
	             replaced by one of *lower* priority until its `floor` has
	             elapsed. Equal or higher always replaces, so nothing is ever
	             stuck and no queue has to exist. ]]
InterfaceSpec.NoticeKind = {
	death = { scale = 1.34, seconds = 7.0, priority = 3, floor = 3.0 },
	kill = { scale = 1.22, seconds = 5.5, priority = 3, floor = 2.5 },
	server = { scale = 1.0, seconds = 6.0, priority = 2, floor = 1.5 },
	refused = { scale = 1.0, seconds = 4.0, priority = 1, floor = 0.0 },
	regional = { scale = 1.0, seconds = 6.0, priority = 1, floor = 0.0 },
	["local"] = { scale = 1.0, seconds = 6.0, priority = 0, floor = 0.0 },
}

function InterfaceSpec.noticeKind(kind: string)
	return InterfaceSpec.NoticeKind[kind] or InterfaceSpec.NoticeKind["local"]
end

--[[ Fraction of a bar, guarded. Every bar in the HUD goes through this rather
	than dividing inline, because a zero maximum arrives routinely -- a client
	renders before the server has published anything at all. ]]
function InterfaceSpec.fraction(value: number, maximum: number): number
	if maximum <= 0 then
		return 0
	end
	return math.clamp(value / maximum, 0, 1)
end

--[[ Thousands separators. Refinement at Lowgold runs to 9,000 per tier and
	90,000 per stage, and an unseparated five-figure number is read digit by
	digit rather than at a glance. ]]
function InterfaceSpec.commas(value: number): string
	local text = tostring(math.floor(value))
	local sign = ""
	if string.sub(text, 1, 1) == "-" then
		sign = "-"
		text = string.sub(text, 2)
	end
	local out = text
	while true do
		local replaced, count = string.gsub(out, "^(%d+)(%d%d%d)", "%1,%2")
		out = replaced
		if count == 0 then
			break
		end
	end
	return sign .. out
end

--[[ A cooldown countdown, in the shape WoW's icons print it: seconds with one
	decimal under ten, whole seconds above. Two digits at most, because the
	number is drawn inside a 58px square and read peripherally. ]]
function InterfaceSpec.countdown(seconds: number): string
	if seconds <= 0 then
		return ""
	end
	if seconds < 10 then
		return string.format("%.1f", seconds)
	end
	return string.format("%d", math.ceil(seconds))
end

-- Whether a windup is long enough to be worth drawing as a bar at all.
function InterfaceSpec.telegraphs(windup: number): boolean
	return windup >= InterfaceSpec.Cast.windupFloor
end

function InterfaceSpec.kindColor(kind: string): Rgb
	return InterfaceSpec.KindColor[kind] or InterfaceSpec.Palette.ready
end

--[[ The width the action bar needs for a given slot count, so the caller does
	not re-derive the arithmetic that decides whether five slots fit. ]]
function InterfaceSpec.barWidth(slotCount: number): number
	if slotCount <= 0 then
		return 0
	end
	local slot = InterfaceSpec.Slot
	return slotCount * slot.size + (slotCount - 1) * slot.gap
end

return InterfaceSpec
