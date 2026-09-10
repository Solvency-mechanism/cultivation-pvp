--!strict
--[[
	Impact tuning: the numbers behind every hit, and the curves that map one
	value onto all seven channels an impact is expressed in.

	Pure data and pure math. No requires, no Roblox datatypes -- colours are RGB
	triples rather than Color3, and Config arrives as a parameter rather than a
	require -- so this module loads unchanged under both Roblox and Lune, which
	is the rule every module in src/shared/ lives by.

	**Severity, not damage, drives presentation.** This is the one idea here and
	everything below follows from it. 128 damage is a third of a Lowgold health
	bar and a rounding error at Truegold. Scaling a flash, a shake and a hitstop
	off raw damage would let late-game hits escalate into a screen-wide seizure
	while early-game hits stayed invisible. Every curve reads the *fraction of a
	bar removed* instead, so a hit that takes a quarter of your health looks the
	same at every stage -- which is exactly what the flat time-to-kill across
	brackets already promises the player.
]]

export type Rgb = { r: number, g: number, b: number }

local ImpactSpec = {}

--[[ The two-material contrast rule, applied to impact.

	A near-white hot core and pure-white shards against a near-black dust puff.
	Value contrast is what carries "something happened" at any distance, on any
	ground, on a six-inch screen; hue only ever says *whose* hit it was. That is
	why the flash is warm-white rather than the technique's colour -- the
	technique already had its colour on the way in. ]]
ImpactSpec.Palette = {
	flashCore = { r = 255, g = 246, b = 214 } :: Rgb,
	sparkCore = { r = 255, g = 255, b = 255 } :: Rgb,
	dust = { r = 26, g = 24, b = 30 } :: Rgb,

	-- Damage you dealt is white; damage you took is red; a killing blow is
	-- gold. Three colours, three meanings, no legend needed.
	dealtText = { r = 255, g = 255, b = 255 } :: Rgb,
	takenText = { r = 255, g = 108, b = 96 } :: Rgb,
	killText = { r = 255, g = 205, b = 96 } :: Rgb,

	markerDealt = { r = 255, g = 255, b = 255 } :: Rgb,
	markerKill = { r = 255, g = 205, b = 96 } :: Rgb,

	vignette = { r = 176, g = 26, b = 26 } :: Rgb,
}

--[[ Damage numbers. Sized in pixels rather than studs, so a hit reads the same
	whether it landed at your feet or across a Ruler radius.

	**Sized against the reference, not against a desktop editor.** The critic
	measured our combat-critical text at roughly half Blox Fruits' glyph height:
	their HUD digits are ~30 px tall in a 1920-wide frame. A damage number is
	the loudest transient text in the game, so it has to beat that number, not
	match it. Gotham's digits render at roughly 0.72 of TextSize, which makes
	44 px a ~32 px glyph -- already past the reference at the floor -- and 76 px
	a ~55 px one on a heavy hit. A killing blow goes half again above that. ]]
ImpactSpec.Number = {
	minTextSize = 44,
	maxTextSize = 76,
	-- A killing blow is the one number in the game worth reading twice.
	killTextScale = 1.25,

	--[[ The stroke has to track the glyph. A fixed 3 px outline is right at
		36 px text and invisible at 76 px, and the outline is most of why white
		digits stay legible over a bright effect. ]]
	strokeFraction = 0.09,
	minStroke = 3,

	--[[ Spawned above the nameplate, not on the body. PresenceService floats
		the stage plate 2.6 studs over the head, so a number starting at chest
		height would climb straight through it. This starts clear of the plate
		and leaves upward. ]]
	anchorStuds = 4.6,
	riseStuds = 5.0,
	-- A hair longer than the 0.6 s it used to run: the number is bigger, it
	-- travels further, and it now spends its first 0.12 s settling.
	seconds = 0.7,

	-- Tilt off vertical, thrown along the camera's right. Two hits inside the
	-- same second have to separate *on screen*, which drifting in depth would
	-- not do.
	driftDegrees = 15,

	-- Fraction of its life the number holds at full opacity before fading. It
	-- has to be readable before it is pretty.
	holdFraction = 0.4,

	-- Born oversized and settling, which is what makes it read as struck rather
	-- than as printed.
	popFrom = 1.35,
	popSeconds = 0.12,

	maxDistance = 300,
}

--[[ Hitstop. Client-visual only: the local camera stops writing new CFrames for
	four or five frames and then resumes. No DeltaTime is touched, no Humanoid is
	slowed, nothing is sent to the server, and both machines keep simulating. ]]
ImpactSpec.Hitstop = {
	minSeconds = 0.06,
	maxSeconds = 0.09,
	-- No second hitstop inside this window. A Ruler sweep that catches you and
	-- a construct that ticks on the same frame is one punch, not a third of a
	-- second of frozen camera.
	refractorySeconds = 0.18,
}

--[[ Camera shake, as trauma that decays. Applied as an offset composed onto
	whatever the camera scripts already wrote, so it is never stored and can
	never strand the camera somewhere strange. ]]
ImpactSpec.Shake = {
	minTrauma = 0.10,
	maxTrauma = 0.55,
	decayPerSecond = 2.6,
	offsetStuds = 0.9,
	rollRadians = 0.05,
	-- Being hit shakes harder than landing one. The screen is allowed to tell
	-- you that you are losing.
	takenMultiplier = 1.35,
}

-- The warm core at the point of contact. Shortest lifetime of the three.
ImpactSpec.Flash = {
	minDiameter = 2.2,
	maxDiameter = 7.5,
	growth = 2.6,
	seconds = 0.14,
}

-- White shards thrown outward. Middle lifetime.
ImpactSpec.Sparks = {
	minCount = 5,
	maxCount = 16,
	thickness = 0.22,
	minLength = 1.4,
	maxLength = 3.6,
	minTravel = 5.0,
	maxTravel = 13.0,
	seconds = 0.26,
}

--[[ The dust puff. Longest lifetime, and the only dark element -- it is what
	the white shards are legible *against*, and it is still there after the
	flash has gone, which is what turns a flicker into an event. ]]
ImpactSpec.Dust = {
	puffs = 3,
	minDiameter = 2.4,
	maxDiameter = 6.0,
	growth = 2.2,
	riseStuds = 2.5,
	spreadStuds = 1.6,
	transparency = 0.45,
	seconds = 0.85,
}

--[[ The hitmarker: a tight X at screen centre, for the player who landed the
	hit. In third person the impact happens where the enemy is, not where the
	eye is, so this is the one channel aimed at the caster rather than the
	scene. Driven by damage the server already applied, so it fires for a Ruler
	sweep and a construct tick exactly as it does for a striker bolt. ]]
ImpactSpec.Marker = {
	pixels = 34,
	thickness = 3,
	armPixels = 26,
	punchFrom = 0.55,
	minScale = 0.95,
	maxScale = 1.45,
	seconds = 0.24,
}

-- Red at the screen edges when you are the one taking it.
ImpactSpec.Vignette = {
	minStrength = 0.15,
	maxStrength = 0.62,
	-- Fraction of each screen dimension the coloured band covers.
	bandFraction = 0.22,
	seconds = 0.45,
}

--[[ Ceilings, so a six-player brawl degrades to fewer shards rather than to a
	frame-rate cliff, and so nothing is drawn for a hit the camera cannot see. ]]
ImpactSpec.Budget = {
	maxLiveParts = 240,
	cullStuds = 340,
	reducedStuds = 150,
}

--[[ Impact audio.

	These are sounds Roblox ships inside the client, not catalogue uploads, so
	they need no upload, no moderation wait and no network fetch. Each id below
	was verified by loading it in Studio and checking that it resolved with a
	non-zero TimeLength -- the durations in the comments are the measured values.
	Nothing here is recalled or guessed.

	Six other plausible-sounding paths were probed and did NOT resolve
	(pop_mid, swoosh, rockbreak, whoosh, hurt, bump), which is exactly why the
	list was tested rather than written from memory. ]]
ImpactSpec.Audio = {
	impactAssetId = "rbxasset://sounds/hit.wav", -- 0.836s
	killAssetId = "rbxasset://sounds/glassbreak.wav", -- 1.578s
	volume = 0.55,
	minPitch = 0.92,
	maxPitch = 1.12,
	rollOffMaxStuds = 220,
	--[[ A hit you were part of plays flat and full rather than positionally.
		Hit confirmation is information, not scenery, and information should not
		get quieter because the camera happened to be facing the wrong way. Hits
		between other people stay positional -- those *are* scenery. ]]
	ownVolumeBoost = 1.3,
}

--[[ Cast audio.

	The striker is the most-pressed button in the game and until now it made no
	sound at all, which meant the atom of the combat loop was inaudible. This is
	routed off the same TechniqueFired broadcast the vfx layer draws from, so
	casting stays a thing that happens once, in one place, whether it connects
	or not -- and the silence of a whiff is then a real signal rather than an
	absence of work.

	One sound per kind, chosen for silhouette rather than realism, so the four
	are told apart with the eyes shut. All four are rbxasset paths verified to
	resolve with a non-zero TimeLength in a real Studio run:

		striker   snap.wav     0.418s   a crack -- something left, fast
		enforcer  metal.ogg    0.601s   a ring on the body -- armour going on
		forger    switch3.wav  0.366s   a mechanism latching -- something placed
		ruler     bass.wav     1.008s   a low swell -- the ground answering

	Twelve techniques out of four files: pitch tracks madra cost, so Lance,
	Volley and Pierce share a crack and are told apart by weight -- which is
	also how they are told apart in the fight. ]]
ImpactSpec.Cast = {
	byKind = {
		striker = "rbxasset://sounds/snap.wav",
		enforcer = "rbxasset://sounds/metal.ogg",
		forger = "rbxasset://sounds/switch3.wav",
		ruler = "rbxasset://sounds/bass.wav",
	} :: { [string]: string },
	--[[ Cheapest technique speaks highest, dearest speaks lowest. The range is
		set by the narrowest case rather than the widest: the three strikers sit
		at costs 18/30/44 and have to be told apart, which needs the steps
		between them to clear roughly a semitone. ]]
	lightPitch = 1.22,
	heavyPitch = 0.74,
	minVolume = 0.34,
	maxVolume = 0.62,
	rollOffMaxStuds = 260,
	ownVolumeBoost = 1.25,
}

--[[ FOV punch: the other half of camera shake. Shake says the world moved; the
	field of view says how you met it.

	Landing a hit *narrows* the view for a moment -- the camera flinches into
	the blow, and paired with hitstop the frozen frame is already a push-in.
	Taking one *widens* it, so the world shoves away from you. Opposite signs on
	purpose: the two can land in the same frame and must never be confusable. ]]
ImpactSpec.Fov = {
	dealtDegrees = -3.4,
	takenDegrees = 5.2,
	-- Floor on the severity scaling, so even a construct tick is felt.
	minScale = 0.45,
	decayPerSecond = 9.0,
	maxOffsetDegrees = 9.0,
	--[[ Absolute guards. Whatever happens above, the camera is handed back a
		field of view a person can play with -- this is the one channel in the
		file that could leave the game unplayable if it ever ran away. ]]
	minFov = 30.0,
	maxFov = 110.0,
}

--[[ Above this fraction of a health bar, a hit is already as loud as impacts
	get. A quarter of the bar is a heavy exchange; nothing short of a one-shot
	ever reaches a full one, so saturating at 1.0 would waste the whole range. ]]
local SEVERITY_SATURATION = 0.25

local function clamp01(value: number): number
	return math.clamp(value, 0, 1)
end

local function lerp(from: number, to: number, t: number): number
	return from + (to - from) * clamp01(t)
end

--[[ How much of a full health bar this hit removed, on a 0-1 curve.

	The pool formula mirrors Combat.maxHealth, which owns it. Combat cannot be
	required from here -- shared modules take their dependencies as arguments --
	so the two lines must be kept in step by hand. Drift costs weight, not
	correctness: impacts would read heavy or light, never wrong. ]]
function ImpactSpec.severity(config: any, stageIndex: number, dealt: number): number
	local stage = config.Stages[stageIndex]
	if not stage then
		return 0.5
	end
	local pool = stage.basePower * config.Combat.healthMultiplier
	if pool <= 0 then
		return 0.5
	end
	return clamp01(dealt / pool / SEVERITY_SATURATION)
end

function ImpactSpec.hitstopSeconds(severity: number): number
	return lerp(ImpactSpec.Hitstop.minSeconds, ImpactSpec.Hitstop.maxSeconds, severity)
end

function ImpactSpec.shakeTrauma(severity: number, taken: boolean): number
	local amount = lerp(ImpactSpec.Shake.minTrauma, ImpactSpec.Shake.maxTrauma, severity)
	if taken then
		amount *= ImpactSpec.Shake.takenMultiplier
	end
	return math.min(1, amount)
end

function ImpactSpec.sparkCount(severity: number): number
	return math.round(lerp(ImpactSpec.Sparks.minCount, ImpactSpec.Sparks.maxCount, severity))
end

function ImpactSpec.flashDiameter(severity: number): number
	return lerp(ImpactSpec.Flash.minDiameter, ImpactSpec.Flash.maxDiameter, severity)
end

function ImpactSpec.dustDiameter(severity: number): number
	return lerp(ImpactSpec.Dust.minDiameter, ImpactSpec.Dust.maxDiameter, severity)
end

function ImpactSpec.textSize(severity: number, killing: boolean): number
	local size = lerp(ImpactSpec.Number.minTextSize, ImpactSpec.Number.maxTextSize, severity)
	if killing then
		size *= ImpactSpec.Number.killTextScale
	end
	return math.round(size)
end

--[[ Stroke thickness for a given glyph size, so the outline never thins out
	from under a heavy hit. ]]
function ImpactSpec.strokeThickness(textSize: number): number
	local scaled = textSize * ImpactSpec.Number.strokeFraction
	return math.max(ImpactSpec.Number.minStroke, math.round(scaled))
end

--[[ Billboard width and height in pixels for a given glyph size. Returned as
	two numbers rather than a UDim2, because this module holds no Roblox
	datatypes. Wide enough for five digits, tall enough that the outline is
	never clipped by the box -- which the old fixed 76 px height did as soon as
	the text grew past it. ]]
function ImpactSpec.numberBounds(textSize: number): (number, number)
	return math.round(textSize * 5), math.round(textSize * 1.9)
end

--[[ Degrees to add to the camera's field of view. Negative when you landed the
	hit, positive when you took it. ]]
function ImpactSpec.fovDegrees(severity: number, taken: boolean): number
	local spec = ImpactSpec.Fov
	local base = if taken then spec.takenDegrees else spec.dealtDegrees
	local scaled = base * lerp(spec.minScale, 1, severity)
	return math.clamp(scaled, -spec.maxOffsetDegrees, spec.maxOffsetDegrees)
end

-- Where a technique sits between the cheapest and the dearest in the pool.
local function costWeight(config: any, techId: string): number
	local tech = config.Techniques[techId]
	if not tech then
		return 0.5
	end
	local cheapest, dearest = math.huge, 0
	for _, entry in config.Techniques do
		cheapest = math.min(cheapest, entry.madraCost)
		dearest = math.max(dearest, entry.madraCost)
	end
	if dearest <= cheapest then
		return 0.5
	end
	return clamp01((tech.madraCost - cheapest) / (dearest - cheapest))
end

function ImpactSpec.castSound(kind: string): string
	return ImpactSpec.Cast.byKind[kind] or ""
end

-- Heavier techniques speak lower.
function ImpactSpec.castPitch(config: any, techId: string): number
	return lerp(ImpactSpec.Cast.lightPitch, ImpactSpec.Cast.heavyPitch, costWeight(config, techId))
end

function ImpactSpec.castVolume(config: any, techId: string): number
	return lerp(ImpactSpec.Cast.minVolume, ImpactSpec.Cast.maxVolume, costWeight(config, techId))
end

function ImpactSpec.markerScale(severity: number): number
	return lerp(ImpactSpec.Marker.minScale, ImpactSpec.Marker.maxScale, severity)
end

function ImpactSpec.vignetteStrength(severity: number): number
	return lerp(ImpactSpec.Vignette.minStrength, ImpactSpec.Vignette.maxStrength, severity)
end

return ImpactSpec
