--!strict
--[[
	Technique presentation.

	The server broadcasts a resolved technique over the TechniqueFired remote and
	this draws it. Presentation only: damage is already applied by the time this
	runs, so nothing here decides an outcome and a client that ignores it changes
	nothing but its own screen.

	Payload shape:
		techId   string   -- key into Config.Techniques
		kind     string   -- striker | enforcer | forger | ruler
		casterId number   -- Player.UserId of the caster
		origin   Vector3  -- where the technique came from
		target   Vector3? -- where a striker landed; nil for area kinds
		hit      boolean  -- whether it connected

	================================ THE FOUR LAWS ================================

	Measured off the reference, not invented, and every technique below obeys all
	four. The first pass broke three of them and the frames showed it: Lance read
	as a white blob because it had no dark volume, and Siphon washed the screen
	purple because hue was carrying readability that value should have carried.

	1. VALUE CARRIES READABILITY; HUE ONLY CARRIES FLAVOUR.
	   Every effect pairs a near-black opaque volume (`VOID`, which occludes the
	   world) with a pure-white neon shell (`SHELL`). That pairing is legible
	   against grass, stone, daylight or shadow with no reliance on colour at all.
	   The technique's own colour appears only as a thin, very transparent rim and
	   in particles. **No large, low-transparency neon plane, ever** -- an emissive
	   sheet flattens the frame, and in a PvP game that means you cannot see the
	   person you are fighting.

	2. MASS, AND THE CHEAP MOVE GETS THE MOST OF IT.
	   Everything is sized in character-heights, not studs: Pierce spans up to
	   fourteen, a Ruler field is fifteen across, Lance is five plus half a second
	   of rings that outlive it. The earlier instinct here was backwards --
	   "cheap technique, cheap effect" -- and it was the single worst call in the
	   file. Lance is pressed more often than every other input combined, so the
	   game's *texture* is whatever Lance looks like. It gets the most craft, not
	   the least.

	   The corollary, learned the same way: **no technique may occlude the person
	   casting it.** Muzzles fire from in front of the caster and charges gather
	   at arm's length, because a frame that is less readable with the effect in
	   it than without has failed no matter how big it is.

	3. IMPACT IS THREE ELEMENTS WITH THREE LIFETIMES.
	   A white flash core (~0.15s), white spark shards (~0.4s), and a dark dust
	   puff that outlives both (~1.2s). The dust is what gives a move screen time
	   without adding a single lumen of glare, because it is dark.

	4. A MOVE OCCUPIES 1.5-2.5 SECONDS. Charge, body, impact, settle. Techniques
	   that command terrain leave a scar behind that both players have to read.

	================================== THE SEAMS ==================================

	**Impact.luau owns the moment of contact and this file does not touch it.**
	It is driven by its own server broadcast, fired from `damagePlayer` at the
	instant damage is applied, and it draws the flash, the shards, the dust, the
	damage number, the hitmarker, the hitstop and the camera shake -- all scaled
	to the fraction of a health bar that just vanished. So a technique that
	*connects* stops here at its own destruction: drawing a second flash and a
	second dust puff on the same stud would not read as twice the punch, it would
	read as mush. The camera belongs to Impact too, and nothing below writes to
	it.

	What is left on this side of that line is everything Impact cannot know
	about: the charge, the body, the travel, the terrain, the auras -- and the
	*miss*, which applies no damage, fires no impact event, and would otherwise
	be completely silent.

	`Vfx.charge` renders a windup. The server broadcasts only on *resolve*, so
	the client cannot see an opponent's windup at all -- the counterplay half of
	that needs one broadcast at cast time, and this is the function it should
	call. Until then the local caster's own windup is driven from the keypress and
	collapses visibly if the server never confirms it.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Vfx = {}

export type Shot = {
	techId: string,
	kind: string,
	casterId: number,
	origin: Vector3,
	target: Vector3?,
	hit: boolean,
}

-- Colour is flavour. `core` is the hot near-white, `glow` the identity hue, used
-- only for thin rims and particles.
type Palette = {
	core: Color3,
	glow: Color3,
}

-- Everything a draw function needs, resolved once at dispatch. One table, so
-- adding a field is not twelve signature changes.
type Cast = {
	shot: Shot,
	palette: Palette,
	duration: number,
	weight: number,
	level: number,
}

type Draw = (Cast) -> ()

local RNG = Random.new()

-- ------------------------------------------------------------------- the laws

-- One character height. Every size below that claims to be "big" is written as a
-- multiple of this, so the ratio survives anyone retuning the numbers.
local CHAR = 5.5

--[[ Law one, as two constants.

	VOID is opaque and reads dark against a world whose ground sits around 55%
	grey and whose stone sits at 30-50%. SHELL is the brightest thing allowed on
	screen. Everything reads off the distance between them. ]]
local VOID = Color3.fromRGB(10, 10, 14)
local SHELL = Color3.fromRGB(255, 255, 255)
local ASH = Color3.fromRGB(96, 96, 104)
local ROCK = Color3.fromRGB(52, 45, 40)

-- Cylinder parts run along their local X: a quarter turn about Z stands the axis
-- up (a ground plate), a quarter turn about Y lays it down a look-frame's -Z.
local FLAT = CFrame.Angles(0, 0, math.pi / 2)
local ALONG = CFrame.Angles(0, math.pi / 2, 0)

local DETAIL_NONE = 0
local DETAIL_LOW = 1
local DETAIL_MID = 2
local DETAIL_FULL = 3

local DETAIL_NEAR = 110
local DETAIL_MEDIUM = 260
local DETAIL_FAR = 520

--[[ Above the first ceiling every new cast drops to DETAIL_LOW; above the second
	it is skipped entirely. Dark opaque volume is the cheapest thing the renderer
	does, so this pass costs *less* fill rate than the glowing one it replaces
	despite being far larger on screen. What it spends is instance count, and
	these two numbers are what cap that -- held deliberately below what this file
	alone could afford, because Impact.luau is spending from the same frame. ]]
local PART_BUDGET = 220
local PART_CEILING = 560

local RULER_RADIUS = Config.Combat.ranges.ruler
local FORGER_RADIUS = Config.Combat.ranges.forger

-- Constructs damage on this interval, so they pulse on it. The tell and the tick
-- are the same number on purpose: stepping out during the pulse is the counter.
local PULSE_SECONDS = Config.Combat.constructTickSeconds

local PALETTE: { [string]: Palette } = {
	lance = { core = Color3.fromRGB(220, 246, 255), glow = Color3.fromRGB(60, 170, 255) },
	volley = { core = Color3.fromRGB(255, 240, 200), glow = Color3.fromRGB(255, 165, 50) },
	pierce = { core = Color3.fromRGB(255, 255, 255), glow = Color3.fromRGB(190, 90, 255) },

	surge = { core = Color3.fromRGB(255, 226, 170), glow = Color3.fromRGB(255, 92, 40) },
	bulwark = { core = Color3.fromRGB(222, 240, 255), glow = Color3.fromRGB(70, 130, 255) },
	swiftstep = { core = Color3.fromRGB(226, 255, 232), glow = Color3.fromRGB(70, 235, 140) },

	barrier = { core = Color3.fromRGB(228, 248, 255), glow = Color3.fromRGB(90, 185, 255) },
	caltrops = { core = Color3.fromRGB(255, 214, 160), glow = Color3.fromRGB(226, 88, 46) },
	sentry = { core = Color3.fromRGB(255, 246, 214), glow = Color3.fromRGB(255, 188, 66) },

	upheaval = { core = Color3.fromRGB(255, 186, 112), glow = Color3.fromRGB(198, 96, 40) },
	siphon = { core = Color3.fromRGB(236, 206, 255), glow = Color3.fromRGB(132, 58, 216) },
	tempest = { core = Color3.fromRGB(246, 250, 255), glow = Color3.fromRGB(128, 178, 255) },
}

local FALLBACK: Palette =
	{ core = Color3.fromRGB(240, 240, 240), glow = Color3.fromRGB(150, 170, 210) }

-- A miss still has to draw, or the button reads as broken. It draws in this
-- instead of the technique's own colour, which is the whole tell.
local MISS: Palette = { core = Color3.fromRGB(206, 210, 222), glow = Color3.fromRGB(120, 124, 138) }

-- ---------------------------------------------------------------- scene, budget

local scenery: Folder? = nil

--[[ Everything lives in one client-only folder. Client-created, so it never
	replicates and no server system can see it -- which is what makes it safe to
	put geometry in the middle of a fight. ]]
local function scene(): Folder
	local existing = scenery
	if existing and existing.Parent then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "ClientVfx"
	created.Parent = Workspace
	scenery = created
	return created
end

local function detailAt(position: Vector3): number
	local camera = Workspace.CurrentCamera
	if not camera then
		return DETAIL_NONE
	end

	local distance = (camera.CFrame.Position - position).Magnitude
	local level = DETAIL_NONE
	if distance < DETAIL_NEAR then
		level = DETAIL_FULL
	elseif distance < DETAIL_MEDIUM then
		level = DETAIL_MID
	elseif distance < DETAIL_FAR then
		level = DETAIL_LOW
	end

	local live = #scene():GetChildren()
	if live > PART_CEILING then
		return DETAIL_NONE
	elseif live > PART_BUDGET and level > DETAIL_LOW then
		level = DETAIL_LOW
	end
	return level
end

-- Pick a count per detail tier. Written out at every call site, so the cost of a
-- cast is legible where the cast is written.
local function tier(level: number, low: number, mid: number, full: number): number
	if level >= DETAIL_FULL then
		return full
	elseif level >= DETAIL_MID then
		return mid
	end
	return low
end

-- ------------------------------------------------------------------ primitives

--[[ The one place the non-negotiable flags are set. Every BasePart in this file
	goes through here, so there is exactly one line to audit. ]]
local function decorate(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = scene()
end

--[[ Law one, part one: the dark mass.

	SmoothPlastic rather than Neon, because this is supposed to take light and
	occlude what is behind it. Opaque geometry is also the cheapest thing the
	renderer does, which is why a pass built on dark volume costs less than the
	glowing one it replaced. ]]
local function volume(size: Vector3, cf: CFrame, transparency: number): Part
	local part = Instance.new("Part")
	part.Size = size
	part.CFrame = cf
	part.Color = VOID
	part.Material = Enum.Material.SmoothPlastic
	part.Reflectance = 0
	part.Transparency = transparency
	decorate(part)
	return part
end

-- Law one, part two: the white shell. Pure white neon, and the only thing in the
-- file allowed to be the brightest value on screen.
local function shell(size: Vector3, cf: CFrame, transparency: number): Part
	local part = Instance.new("Part")
	part.Size = size
	part.CFrame = cf
	part.Color = SHELL
	part.Material = Enum.Material.Neon
	part.Transparency = transparency
	decorate(part)
	return part
end

-- Flavour. Always thin, always very transparent, never a plane. If a rim is
-- doing readability work, the shell beside it is too small.
local function rim(size: Vector3, cf: CFrame, color: Color3, transparency: number): Part
	local part = Instance.new("Part")
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = Enum.Material.Neon
	part.Transparency = transparency
	decorate(part)
	return part
end

local function ball(position: Vector3, diameter: number, color: Color3, transparency: number): Part
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.one * diameter
	part.CFrame = CFrame.new(position)
	part.Color = color
	part.Material = if color == VOID then Enum.Material.SmoothPlastic else Enum.Material.Neon
	part.Transparency = transparency
	decorate(part)
	return part
end

--[[ A disc. `pivot` already carries the axis rotation (FLAT for a ground plate,
	look * ALONG for one that faces a direction), because callers know which way
	their disc should point and this should not have to guess. Size is given in
	cylinder convention: thickness first, then diameter. ]]
local function disc(
	pivot: CFrame,
	diameter: number,
	thickness: number,
	color: Color3,
	transparency: number
): Part
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(thickness, diameter, diameter)
	part.CFrame = pivot
	part.Color = color
	part.Material = if color == VOID then Enum.Material.SmoothPlastic else Enum.Material.Neon
	part.Transparency = transparency
	decorate(part)
	return part
end

-- A dark wedge, for anything that needs a point on it.
local function wedgeVolume(size: Vector3, cf: CFrame): WedgePart
	local part = Instance.new("WedgePart")
	part.Size = size
	part.CFrame = cf
	part.Color = VOID
	part.Material = Enum.Material.SmoothPlastic
	decorate(part)
	return part
end

local function tweenTo(
	instance: Instance,
	seconds: number,
	style: Enum.EasingStyle,
	goal: { [string]: any }
)
	TweenService:Create(instance, TweenInfo.new(seconds, style, Enum.EasingDirection.Out), goal)
		:Play()
end

local function bloom(part: BasePart, seconds: number, endSize: Vector3, style: Enum.EasingStyle)
	tweenTo(part, seconds, style, { Size = endSize, Transparency = 1 })
	Debris:AddItem(part, seconds + 0.05)
end

local function fadeOut(part: BasePart, seconds: number)
	tweenTo(part, seconds, Enum.EasingStyle.Sine, { Transparency = 1 })
	Debris:AddItem(part, seconds + 0.05)
end

--[[ A short-lived light. Used sparingly, because lights are the one thing here
	that costs more than its pixels: a handful is punch, a dozen is a stutter. ]]
local function flare(position: Vector3, color: Color3, brightness: number, range: number)
	local host = Instance.new("Part")
	host.Size = Vector3.one * 0.2
	host.CFrame = CFrame.new(position)
	host.Transparency = 1
	decorate(host)

	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = brightness
	light.Range = range
	light.Shadows = false
	light.Parent = host

	tweenTo(light, 0.24, Enum.EasingStyle.Quad, { Brightness = 0 })
	Debris:AddItem(host, 0.3)
end

-- ------------------------------------------------------------------- direction

local function aim(from: Vector3, to: Vector3): Vector3
	local delta = to - from
	if delta.Magnitude < 1e-3 then
		return Vector3.new(0, 0, -1)
	end
	return delta.Unit
end

local function sideways(direction: Vector3): Vector3
	local flat = Vector3.new(direction.Z, 0, -direction.X)
	if flat.Magnitude < 1e-3 then
		return Vector3.new(1, 0, 0)
	end
	return flat.Unit
end

--[[ `CFrame.lookAt` produces NaN when the direction it is given is parallel to
	its up vector, and a part assigned a NaN CFrame does not draw at all. Tempest
	drops bolts almost straight down, so every oriented part in this file is built
	through here and picks a different up when the direction is near vertical. ]]
local function look(from: Vector3, to: Vector3): CFrame
	local direction = aim(from, to)
	local up = if math.abs(direction.Y) > 0.995 then Vector3.new(0, 0, 1) else Vector3.new(0, 1, 0)
	return CFrame.lookAt(from, to, up)
end

-- ----------------------------------------------------------------------- rigs

--[[ A composite that moves as one piece.

	Parts are anchored -- rule one -- so a projectile is a set of parts each
	placed at `frame * offset`. Cheaper than welding, and nothing can knock it
	out of alignment. ]]
type Rig = {
	parts: { BasePart },
	offsets: { CFrame },
}

local function rigPlace(rig: Rig, frame: CFrame)
	for index, part in rig.parts do
		part.CFrame = frame * rig.offsets[index]
	end
end

local function rigFly(rig: Rig, destination: CFrame, seconds: number, style: Enum.EasingStyle)
	for index, part in rig.parts do
		tweenTo(part, seconds, style, { CFrame = destination * rig.offsets[index] })
	end
end

local function rigDismiss(rig: Rig, seconds: number)
	for _, part in rig.parts do
		tweenTo(part, seconds, Enum.EasingStyle.Quad, { Transparency = 1 })
		Debris:AddItem(part, seconds + 0.06)
	end
end

--[[ A dart: the striker silhouette shrunk to two parts.

	Anywhere a technique throws something small and fast -- Siphon's inrush,
	scuff off a miss -- it throws one of these rather than a bare white box. A
	flat untextured rectangle reads as a bug; a black body with a white nose
	reads as an object with a front and a back, and it carries its own value
	anchor with it. ]]
local function dartRig(nose: CFrame, length: number, girth: number): Rig
	local rig: Rig = { parts = {}, offsets = {} }

	local function segment(part: Part, offset: CFrame)
		part.Shape = Enum.PartType.Cylinder
		part.CFrame = nose * offset
		table.insert(rig.parts, part)
		table.insert(rig.offsets, offset)
	end

	segment(
		shell(Vector3.new(length * 0.26, girth * 0.78, girth * 0.78), nose, 0),
		CFrame.new(0, 0, length * 0.13) * ALONG
	)
	segment(
		volume(Vector3.new(length * 0.76, girth, girth), nose, 0),
		CFrame.new(0, 0, length * 0.62) * ALONG
	)
	return rig
end

-- --------------------------------------------------------------------- sprays

type SprayConfig = {
	core: Color3,
	glow: Color3,
	sizeFrom: number,
	sizeTo: number,
	speed: NumberRange?,
	life: NumberRange?,
	spread: number?,
	acceleration: Vector3?,
	drag: number?,
	rate: number?,
	direction: Enum.NormalId?,
	-- Dust and smoke: takes light instead of emitting it, so a big slow cloud
	-- adds mass to a frame instead of glare. This is what buys law four's screen
	-- time without breaking law one.
	dusty: boolean?,
}

local function configureSpray(emitter: ParticleEmitter, config: SprayConfig)
	local dusty = config.dusty == true
	emitter.Color = ColorSequence.new(config.core, config.glow)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, config.sizeFrom),
		NumberSequenceKeypoint.new(0.4, (config.sizeFrom + config.sizeTo) * 0.6),
		NumberSequenceKeypoint.new(1, config.sizeTo),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.09, if dusty then 0.45 else 0.05),
		NumberSequenceKeypoint.new(0.7, if dusty then 0.7 else 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Speed = config.speed or NumberRange.new(14, 30)
	emitter.Lifetime = config.life or NumberRange.new(0.22, 0.5)
	local spread = config.spread or 180
	emitter.SpreadAngle = Vector2.new(spread, spread)
	emitter.Acceleration = config.acceleration or Vector3.new(0, -26, 0)
	emitter.Drag = config.drag or 4
	emitter.EmissionDirection = config.direction or Enum.NormalId.Top
	emitter.Rate = config.rate or 0
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-260, 260)
	emitter.LightEmission = if dusty then 0 else 0.9
	emitter.LightInfluence = if dusty then 1 else 0
	emitter.Enabled = true
end

local function sprayLife(config: SprayConfig): number
	local life = config.life
	return if life then life.Max else 0.5
end

local function spray(position: Vector3, count: number, config: SprayConfig)
	if count <= 0 then
		return
	end
	local host = Instance.new("Part")
	host.Size = Vector3.one * 0.2
	host.CFrame = CFrame.new(position)
	host.Transparency = 1
	decorate(host)

	local emitter = Instance.new("ParticleEmitter")
	configureSpray(emitter, config)
	emitter.Parent = host
	emitter:Emit(count)
	Debris:AddItem(host, sprayLife(config) + 0.4)
end

--[[ A continuous emitter riding an existing part. Parented to an Attachment on
	the part, so the engine moves it for free -- no per-frame work for anything
	that only has to stay with a body. The Attachment is what comes back: it owns
	the emitter, so whoever holds it can dispose of the whole thing. ]]
local function stream(host: BasePart, offset: Vector3, config: SprayConfig): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Position = offset
	attachment.Parent = host

	local emitter = Instance.new("ParticleEmitter")
	configureSpray(emitter, config)
	emitter.Parent = attachment
	return attachment
end

-- ------------------------------------------------------------------- followers

--[[ Anchored geometry that has to move.

	Aura rings, orbiting plates and hovering cores are all anchored -- rule one is
	not negotiable -- so nothing welds and nothing is simulated. One Heartbeat
	drives every one of them from a table, and disconnects itself the moment the
	table empties, so an idle client pays nothing at all.

	`offsetTo` and `morph` let an offset travel over time: a ring can close on the
	caster while still tracking the caster, which a plain CFrame tween cannot do
	because the follower would overwrite it every frame. ]]
type Follower = {
	part: BasePart,
	anchor: BasePart?,
	position: Vector3,
	offset: CFrame,
	offsetTo: CFrame,
	morph: number,
	spin: number,
	bob: number,
	born: number,
	expiresAt: number,
}

--[[ A projectile in the air.

	Anchored parts cannot be thrown, and a CFrame tween can only travel in a
	straight line, so an arc has to be evaluated. A quadratic Bezier, sampled
	every Heartbeat, with the rig oriented along its own tangent -- which is what
	makes a bolt bank into its path instead of sliding sideways through it.

	The arc matters more than it sounds: a straight line between two points that
	are both roughly at chest height reads as a static rod in a frozen frame. A
	curve gives the eye a direction even with no motion blur to help it. ]]
type Flight = {
	rig: Rig,
	from: Vector3,
	control: Vector3,
	to: Vector3,
	born: number,
	seconds: number,
	onArrive: () -> (),
}

local followers: { Follower } = {}
local flights: { Flight } = {}
local heartbeat: RBXScriptConnection? = nil

local function bezier(from: Vector3, control: Vector3, to: Vector3, t: number): Vector3
	local inv = 1 - t
	return from * (inv * inv) + control * (2 * inv * t) + to * (t * t)
end

local function stepFlights(now: number)
	for index = #flights, 1, -1 do
		local flight = flights[index]
		local span = math.max(flight.seconds, 1e-3)
		local t = math.clamp((now - flight.born) / span, 0, 1)
		local point = bezier(flight.from, flight.control, flight.to, t)
		-- Sampled slightly ahead for the tangent; at the very end, sampled
		-- slightly behind and mirrored, so the last frame does not snap flat.
		local ahead = if t < 1
			then bezier(flight.from, flight.control, flight.to, math.min(t + 0.04, 1))
			else point + (point - bezier(flight.from, flight.control, flight.to, 0.96))
		rigPlace(flight.rig, look(point, ahead))

		if t >= 1 then
			table.remove(flights, index)
			flight.onArrive()
		end
	end
end

local function stepFollowers()
	local now = os.clock()
	for index = #followers, 1, -1 do
		local follower = followers[index]
		local anchor = follower.anchor
		local orphaned = anchor ~= nil and anchor.Parent == nil

		if not follower.part.Parent or now >= follower.expiresAt or orphaned then
			-- A character that despawned mid-buff takes its aura with it, rather
			-- than leaving rings hanging over an empty spawn pad.
			follower.part:Destroy()
			table.remove(followers, index)
			continue
		end

		local age = now - follower.born
		local seat = follower.offset
		if follower.morph > 0 then
			seat = follower.offset:Lerp(follower.offsetTo, math.clamp(age / follower.morph, 0, 1))
		end

		local base = if anchor then anchor.Position else follower.position
		local lift = if follower.bob ~= 0 then math.sin(age * 2.3) * follower.bob else 0
		follower.part.CFrame = CFrame.new(base + Vector3.new(0, lift, 0))
			* CFrame.Angles(0, age * follower.spin, 0)
			* seat
	end
end

--[[ One Heartbeat drives every anchored thing that has to move, and disconnects
	itself the moment nothing does, so an idle client pays nothing at all. ]]
local function stepDrivers()
	local now = os.clock()
	stepFlights(now)
	stepFollowers()
	if #followers == 0 and #flights == 0 and heartbeat then
		heartbeat:Disconnect()
		heartbeat = nil
	end
end

local function ensureDriver()
	if not heartbeat then
		heartbeat = RunService.Heartbeat:Connect(stepDrivers)
	end
end

--[[ Throw a rig along an arc.

	`lift` is how far the control point rises off the straight line, as a
	fraction of the distance covered, and `drift` the same sideways. Both are
	kept small on purpose: the server raycast a straight line, the endpoints here
	are the server's own, and a curve that bowed far off that line would be
	drawing a shot that was never taken. A few studs of bow at maximum range is
	enough for the eye to read direction and not enough to lie. ]]
local function launch(
	rig: Rig,
	from: Vector3,
	to: Vector3,
	lift: number,
	drift: number,
	seconds: number,
	onArrive: () -> ()
)
	local straight = to - from
	local across = sideways(aim(from, to))
	local control = from:Lerp(to, 0.5)
		+ Vector3.new(0, straight.Magnitude * lift, 0)
		+ across * (straight.Magnitude * drift)
	table.insert(flights, {
		rig = rig,
		from = from,
		control = control,
		to = to,
		born = os.clock(),
		seconds = seconds,
		onArrive = onArrive,
	})
	ensureDriver()
end

local function followMorph(
	part: BasePart,
	anchor: BasePart?,
	position: Vector3,
	offset: CFrame,
	offsetTo: CFrame,
	morph: number,
	spin: number,
	bob: number,
	duration: number
)
	table.insert(followers, {
		part = part,
		anchor = anchor,
		position = position,
		offset = offset,
		offsetTo = offsetTo,
		morph = morph,
		spin = spin,
		bob = bob,
		born = os.clock(),
		expiresAt = os.clock() + duration,
	})
	ensureDriver()
end

local function follow(
	part: BasePart,
	anchor: BasePart?,
	position: Vector3,
	offset: CFrame,
	spin: number,
	bob: number,
	duration: number
)
	followMorph(part, anchor, position, offset, offset, 0, spin, bob, duration)
end

-- ------------------------------------------------------------------ geometry aid

local function isLocalCaster(shot: Shot): boolean
	local player = Players.LocalPlayer
	return player ~= nil and player.UserId == shot.casterId
end

local function rootOf(userId: number): BasePart?
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return nil
	end
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

--[[ Where the floor is under a point. Ground effects that guess at the floor
	read as broken the first time anyone casts on a slope. Characters and this
	folder are excluded; every part here is CanQuery=false anyway, but excluding
	the folder keeps that true even if a future part is added carelessly. ]]
local function groundY(position: Vector3, fallback: number): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true

	local exclude: { Instance } = { scene() }
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			table.insert(exclude, character)
		end
	end
	params.FilterDescendantsInstances = exclude

	local result =
		Workspace:Raycast(position + Vector3.new(0, 8, 0), Vector3.new(0, -90, 0), params)
	return if result then result.Position.Y else fallback
end

-- --------------------------------------------------------------------- motifs

--[[ A ring of tangent bars.

	The engine has no torus and a filled disc is a wash, so every hard edge in
	this file is segments. The quarter turn is what makes each bar lie along the
	arc instead of pointing out of it: a ring of tangents reads as a circle, a
	ring of spokes reads as a starburst. ]]
local function ringSeat(angle: number, radius: number, lift: number): CFrame
	return CFrame.Angles(0, angle, 0) * CFrame.new(radius, lift, 0) * ALONG
end

--[[ How far under a white bar its black backing sits.

	This is law one's missing half. Pairing black and white *somewhere in the
	effect* is not enough -- a white bar on mid-grey stone is still mid-contrast
	at its own edge. The backing puts near-black immediately behind every white
	element, so the contrast is local to the silhouette and survives any ground,
	any light, any distance. It is also what keeps bloom from clipping: the
	downsample that produces the glow averages the white against the black beside
	it instead of against a bright neon floor. ]]
local BACKING = -0.09

--[[ A ring that travels: it lies in `frame`'s XZ plane, ends in `frameTo`'s, and
	scales its radius by `growTo` on the way. That covers opening, closing and
	rising, which is every ring in the file. ]]
local function edgeRing(
	frame: CFrame,
	frameTo: CFrame,
	radius: number,
	segments: number,
	thickness: number,
	color: Color3,
	seconds: number,
	growTo: number,
	backed: boolean
)
	if segments <= 0 or radius <= 0 then
		return
	end
	local span = (2 * math.pi * radius) / segments
	local backing = color ~= VOID and backed
	for index = 1, segments do
		local angle = (index / segments) * math.pi * 2
		local size = Vector3.new(span * 0.84, thickness, thickness * 1.6)
		local start = frame * ringSeat(angle, radius, 0)
		local part = if color == VOID then volume(size, start, 0) else shell(size, start, 0)
		-- Bars scale with the radius they travel to, so the ring stays closed
		-- whether it is opening outward or closing inward.
		tweenTo(part, seconds, Enum.EasingStyle.Quint, {
			CFrame = frameTo * ringSeat(angle, radius * growTo, 0),
			Size = Vector3.new(span * growTo, thickness * 0.35, thickness * 0.6),
			Transparency = 1,
		})
		Debris:AddItem(part, seconds + 0.05)

		if backing then
			local slab = volume(
				Vector3.new(span * 0.92, thickness * 1.9, thickness * 2.4),
				frame * ringSeat(angle, radius, BACKING),
				0
			)
			tweenTo(slab, seconds * 1.15, Enum.EasingStyle.Quint, {
				CFrame = frameTo * ringSeat(angle, radius * growTo, BACKING),
				Size = Vector3.new(span * growTo * 1.05, thickness * 0.7, thickness * 0.9),
				Transparency = 1,
			})
			Debris:AddItem(slab, seconds * 1.15 + 0.05)
		end
	end
end

-- A ring that stays put. The common case.
local function ringAt(
	centre: Vector3,
	radius: number,
	segments: number,
	thickness: number,
	color: Color3,
	seconds: number,
	growTo: number,
	backed: boolean
)
	local frame = CFrame.new(centre)
	edgeRing(frame, frame, radius, segments, thickness, color, seconds, growTo, backed)
end

--[[ A ring worn by a body, made of followers so it tracks the caster.

	Filled discs are forbidden by law one -- an eleven-stud white plate at chest
	height is the blob the first pass shipped -- so every ring on a character is
	bars with a hole in the middle. ]]
local function barRing(
	anchor: BasePart?,
	position: Vector3,
	radius: number,
	segments: number,
	thickness: number,
	seat: CFrame,
	spin: number,
	duration: number,
	backed: boolean
): { BasePart }
	local bars: { BasePart } = {}
	local span = (2 * math.pi * radius) / segments
	local base = if anchor then anchor.Position else position
	for index = 1, segments do
		local angle = (index / segments) * math.pi * 2
		local offset = seat * ringSeat(angle, radius, 0)
		local bar = shell(
			Vector3.new(span * 0.8, thickness, thickness * 1.5),
			CFrame.new(base) * offset,
			0.05
		)
		follow(bar, anchor, position, offset, spin, 0, duration)
		table.insert(bars, bar)

		if backed then
			local slab = volume(
				Vector3.new(span * 0.9, thickness * 1.9, thickness * 2.3),
				CFrame.new(base) * seat * ringSeat(angle, radius, BACKING),
				0
			)
			follow(
				slab,
				anchor,
				position,
				seat * ringSeat(angle, radius, BACKING),
				spin,
				0,
				duration
			)
			table.insert(bars, slab)
		end
	end
	return bars
end

--[[ The ground wave, rebuilt under law one.

	The first pass made this a low-transparency neon disc and it blew the frame
	out. It is now a *dark* plate -- which darkens rather than glares, keeps
	everything standing on it readable, and gives the white leading edge something
	to read against. This is the lava-field structure from the reference: black
	crust, bright boundary. ]]
local function shadowWave(
	centre: Vector3,
	fromDiameter: number,
	toDiameter: number,
	seconds: number,
	level: number
)
	local at = centre + Vector3.new(0, 0.25, 0)
	local plate = disc(CFrame.new(at) * FLAT, fromDiameter, 0.5, VOID, 0.62)
	tweenTo(plate, seconds, Enum.EasingStyle.Quint, {
		Size = Vector3.new(0.2, toDiameter, toDiameter),
		Transparency = 1,
	})
	Debris:AddItem(plate, seconds + 0.05)

	ringAt(
		at,
		fromDiameter * 0.5,
		tier(level, 6, 10, 16),
		0.6,
		SHELL,
		seconds,
		toDiameter / math.max(fromDiameter, 0.1),
		true
	)
end

--[[ Terrain that stays changed.

	Law four: a heavy move alters the world and both players then have to read it.
	Black crust with bright cracks through it, holding for several seconds before
	it fades. Dark, so a persistent zone never costs anybody visibility. ]]
local function scar(
	centre: Vector3,
	radius: number,
	palette: Palette,
	seconds: number,
	level: number
)
	local at = centre + Vector3.new(0, 0.12, 0)
	-- Held at better than half transparency: a scar has to darken the ground
	-- enough to be a fact, and not so much that anyone standing on it vanishes.
	local crust = disc(CFrame.new(at) * FLAT, radius * 2, 0.4, VOID, 0.55)
	tweenTo(crust, seconds, Enum.EasingStyle.Sine, { Transparency = 1 })
	Debris:AddItem(crust, seconds + 0.1)

	local cracks = tier(level, 3, 6, 10)
	for index = 1, cracks do
		local angle = (index / cracks) * math.pi * 2 + RNG:NextNumber(-0.3, 0.3)
		local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local length = radius * RNG:NextNumber(0.5, 0.95)
		local middle = at + direction * (length * 0.5) + Vector3.new(0, 0.08, 0)
		local crack = rim(
			Vector3.new(RNG:NextNumber(0.5, 1.1), 0.3, length),
			look(middle, middle + direction),
			palette.core,
			0.25
		)
		tweenTo(crack, seconds, Enum.EasingStyle.Sine, { Transparency = 1, Color = palette.glow })
		Debris:AddItem(crack, seconds + 0.1)
	end
end

--[[ Where a technique ends.

	Impact.luau draws the moment of contact -- warm flash, white shards, dark
	dust, number, marker, hitstop, shake -- from the server's applied-damage
	broadcast. So when a shot lands on a body, this stops at the projectile's own
	destruction and gets out of the way.

	When it does *not* land on a body, nothing else will draw here at all, and
	this becomes the whole event: three elements with three lifetimes, in grey.
	Collar ring at 0.24s, scuff at 0.4s, dust at 1.2s. That is what makes a miss
	read as a miss in one frame rather than as a button that did nothing. ]]
local function terminate(
	cast: Cast,
	position: Vector3,
	direction: Vector3,
	weight: number,
	bodyHit: boolean
)
	local level = cast.level
	local palette = if bodyHit then cast.palette else MISS
	local facing = look(position, position + direction)

	--[[ Two rings facing back down the path the shot travelled, and they are the
		part that matters: **they outlive the projectile.** A bolt that vanishes on
		contact leaves a frozen frame with nothing in it, which is exactly why the
		old 0.24s collar failed the test. The white ring runs 0.55s and the dark
		one behind it 0.8s, so for half a second after the bolt is gone the frame
		still says "something landed here, and it came from over there".

		Bars rather than a plate -- a thirty-stud white disc is a blob however
		briefly it exists -- and identical for a hit and a miss, because this is
		the projectile dying, not a statement about what it struck. ]]
	local plane = facing * CFrame.Angles(-math.pi / 2, 0, 0)
	local ringRadius = 1.3 + 1.9 * weight
	-- Segment count follows the weight as well as the detail tier, so the five
	-- small landings of a Volley cost about what one Lance does.
	local function fit(count: number): number
		return math.max(5, math.floor(count * math.clamp(weight * 1.1, 0.35, 1)))
	end
	edgeRing(
		plane,
		plane,
		ringRadius,
		fit(tier(level, 6, 9, 14)),
		0.55 * weight,
		SHELL,
		0.55,
		6,
		true
	)
	edgeRing(
		plane,
		plane,
		ringRadius * 0.55,
		fit(tier(level, 5, 7, 10)),
		0.9 * weight,
		VOID,
		0.8,
		9,
		false
	)

	spray(position, tier(level, 3, 6, 10), {
		core = SHELL,
		glow = palette.glow,
		sizeFrom = 0.4 * weight,
		sizeTo = 0,
		speed = NumberRange.new(20 * weight, 46 * weight),
		life = NumberRange.new(0.14, 0.34),
		spread = 180,
		acceleration = Vector3.new(0, -34, 0),
	})

	if bodyHit then
		return
	end

	-- Scuff: darts skidding off the surface it struck instead of a body.
	for _ = 1, tier(level, 0, 2, 4) do
		local scatter =
			Vector3.new(RNG:NextNumber(-1, 1), RNG:NextNumber(-0.2, 1), RNG:NextNumber(-1, 1))
		local away = -direction * 1.5 + scatter
		away = if away.Magnitude < 0.15 then -direction else away.Unit
		local length = RNG:NextNumber(2.4, 5) * weight
		local rig = dartRig(look(position, position + away), length, 0.34 * weight)
		local landing = position + away * RNG:NextNumber(6, 13) * weight
		rigFly(rig, look(landing, landing + away), 0.4, Enum.EasingStyle.Quad)
		rigDismiss(rig, 0.4)
	end

	-- Dust: dark, slow, and the element that outlives everything else, which is
	-- what turns a flicker into an event.
	for index = 1, tier(level, 1, 2, 3) do
		local drift = Vector3.new(
			RNG:NextNumber(-2, 2),
			RNG:NextNumber(-0.5, 2),
			RNG:NextNumber(-2, 2)
		) * weight
		local puff = ball(position + drift * 0.4, 2.5 * weight, VOID, 0.5)
		tweenTo(puff, 1.2 + index * 0.12, Enum.EasingStyle.Sine, {
			Size = Vector3.one * (10 + index * 2.5) * weight,
			CFrame = CFrame.new(position + drift + Vector3.new(0, 2.5 * weight, 0)),
			Transparency = 1,
		})
		Debris:AddItem(puff, 1.5 + index * 0.12)
	end

	spray(position, tier(level, 4, 8, 14), {
		core = ASH,
		glow = VOID,
		sizeFrom = 1.6 * weight,
		sizeTo = 5.5 * weight,
		speed = NumberRange.new(5, 16),
		life = NumberRange.new(0.7, 1.3),
		spread = 180,
		acceleration = Vector3.new(0, -3, 0),
		drag = 2.5,
		dusty = true,
	})
end

-- The discharge at the caster's end: a dark kick, not a white plate. The first
-- pass put a seven-stud white disc here, and that disc is the blob in the frame.
local function muzzle(position: Vector3, direction: Vector3, palette: Palette, weight: number)
	local kick = ball(position, 1.2 * weight, VOID, 0.3)
	bloom(kick, 0.24, Vector3.one * 5 * weight, Enum.EasingStyle.Quad)
	ringAt(position, 1.4 * weight, 8, 0.5 * weight, SHELL, 0.28, 3.8, true)

	spray(position, math.floor(7 * weight), {
		core = SHELL,
		glow = palette.glow,
		sizeFrom = 0.4 * weight,
		sizeTo = 0,
		speed = NumberRange.new(12, 30),
		life = NumberRange.new(0.12, 0.3),
		spread = 40,
		acceleration = direction * 34,
		drag = 6,
	})
end

--[[ The striker silhouette: a black shaft with a white head and white bands.

	This is law one made physical. The shaft is opaque and occludes what is behind
	it, so the thing has mass; the bands are pure white against it, so the eye
	catches its length and its speed; the hue is a barely-there sleeve. A frame of
	this is unmistakably a lance, which is exactly what the first pass's white
	blob was not. ]]
local function spearRig(nose: CFrame, length: number, girth: number, cast: Cast): Rig
	local rig: Rig = { parts = {}, offsets = {} }
	local palette = cast.palette

	-- Forward is -Z, so the body extends toward +Z behind the nose.
	local function seat(z: number): CFrame
		return CFrame.new(0, 0, z) * ALONG
	end

	-- Typed to Part rather than BasePart because the shaft pieces are cylinders,
	-- and Shape lives on Part.
	local function segment(part: Part, offset: CFrame): Part
		part.Shape = Enum.PartType.Cylinder
		part.CFrame = nose * offset
		table.insert(rig.parts, part)
		table.insert(rig.offsets, offset)
		return part
	end

	segment(
		shell(Vector3.new(length * 0.11, girth * 0.45, girth * 0.45), nose, 0),
		seat(length * 0.05)
	)
	segment(
		shell(Vector3.new(length * 0.05, girth * 0.95, girth * 0.95), nose, 0),
		seat(length * 0.14)
	)
	segment(volume(Vector3.new(length * 0.8, girth, girth), nose, 0), seat(length * 0.55))
	local tail = segment(
		shell(Vector3.new(length * 0.05, girth * 0.62, girth * 0.62), nose, 0),
		seat(length * 0.95)
	)

	if cast.level >= DETAIL_MID then
		local band = Vector3.new(length * 0.032, girth * 1.32, girth * 1.32)
		segment(shell(band, nose, 0), seat(length * 0.33))
		segment(shell(band, nose, 0), seat(length * 0.63))
		segment(
			rim(Vector3.new(length * 0.86, girth * 1.95, girth * 1.95), nose, palette.glow, 0.76),
			seat(length * 0.5)
		)

		-- The ribbon is what makes a fast object read as one streak rather than
		-- as a part teleporting once a frame.
		local back = Instance.new("Attachment")
		back.Position = Vector3.new(0, girth * 0.5, 0)
		back.Parent = tail

		local front = Instance.new("Attachment")
		front.Position = Vector3.new(0, -girth * 0.5, 0)
		front.Parent = tail

		local trail = Instance.new("Trail")
		trail.Attachment0 = back
		trail.Attachment1 = front
		-- Long enough to be a *streak* rather than a smear. At the reference bar
		-- the ribbon is half the read on a projectile: it is what tells a frozen
		-- frame which way the thing came from.
		trail.Lifetime = 0.38
		trail.MinLength = 0
		trail.FaceCamera = true
		trail.LightEmission = 1
		trail.LightInfluence = 0
		trail.Color = ColorSequence.new(SHELL, palette.glow)
		trail.Transparency = NumberSequence.new(0.08, 1)
		trail.WidthScale = NumberSequence.new(1, 0)
		trail.Parent = tail
	end

	return rig
end

-- ------------------------------------------------------------ windup / charge

--[[ The counterplay budget, rendered.

	`Config.Techniques[id].windup` runs from 0.05s to 1.8s and is the whole reason
	a Tempest can be walked out of. A dark mass gathers at the chest, a white ring
	closes on it, and the ring arriving *is* the release -- so the tell is also a
	timer that reads with no number attached.

	The server broadcasts only on resolve, so nothing here can show an opponent's
	windup yet. That needs one broadcast at cast time, and this function is what
	it should call. ]]
type Charge = {
	pieces: { Instance },
	token: number,
}

local charges: { [number]: Charge } = {}
local chargeToken = 0

local function clearCharge(casterId: number, released: boolean)
	local existing = charges[casterId]
	if not existing then
		return
	end
	charges[casterId] = nil
	for _, piece in existing.pieces do
		if piece:IsA("BasePart") then
			if released then
				-- Spent outward -- but a Ruler telegraph is already eighty studs
				-- across, and doubling that for a sixth of a second would black
				-- the frame out at the exact moment the technique lands.
				local spread = if piece.Size.Magnitude > 30 then 1.05 else 2.2
				tweenTo(piece, 0.16, Enum.EasingStyle.Quad, {
					Size = piece.Size * spread,
					Transparency = 1,
				})
			else
				-- Collapsed. A refused cast must not look like a cast that fired
				-- and did nothing.
				tweenTo(piece, 0.2, Enum.EasingStyle.Quad, {
					Size = piece.Size * 0.1,
					Transparency = 1,
				})
			end
			Debris:AddItem(piece, 0.3)
		else
			if piece:IsA("Attachment") then
				for _, child in piece:GetChildren() do
					if child:IsA("ParticleEmitter") then
						child.Enabled = false
					end
				end
			end
			Debris:AddItem(piece, 0.8)
		end
	end
end

--[[ Draw a windup at a caster. Public, so a server-side charge broadcast can
	drive it for every player; until that exists, only the local caster's own
	press reaches here. ]]
function Vfx.charge(techId: string, casterId: number)
	local tech = Config.Techniques[techId]
	if not tech or tech.windup <= 0 then
		return
	end

	local root = rootOf(casterId)
	if not root then
		return
	end

	local localPlayer = Players.LocalPlayer
	local level = if localPlayer and localPlayer.UserId == casterId
		then DETAIL_FULL
		else detailAt(root.Position)
	if level <= DETAIL_NONE then
		return
	end

	clearCharge(casterId, false)
	chargeToken += 1
	local palette = PALETTE[techId] or FALLBACK
	local charge: Charge = { pieces = {}, token = chargeToken }
	charges[casterId] = charge

	local seconds = tech.windup
	-- Heavier techniques gather more. Tempest at 1.8s should look like a
	-- decision; Swiftstep at 0.05s should barely register.
	local heft = math.clamp(tech.madraCost / 45, 0.55, 1.9)
	local hold = seconds + 0.45
	--[[ Held out in FRONT of the caster and off to one side -- never on the
		torso. A gathering orb centred on the root is a white disc over the
		caster's own head, which is the same failure the striker had: a frame that
		is less readable with the technique in it than without. The reach scales
		with heft, so a Tempest orb never grows back into the body. ]]
	local hand = CFrame.new(1.7, -0.5, -1.9 - heft * 1.2)

	local mass = ball(root.Position, 0.5 * heft, VOID, 0.15)
	tweenTo(mass, seconds, Enum.EasingStyle.Quad, { Size = Vector3.one * 3.4 * heft })
	follow(mass, root, root.Position, hand, 0, 0.18, hold)
	table.insert(charge.pieces, mass)

	-- The shell around the mass, held well back from opaque: this reads as a
	-- husk with something dark inside it, not as a white ball.
	local husk = ball(root.Position, 1.1 * heft, SHELL, 0.6)
	tweenTo(husk, seconds, Enum.EasingStyle.Quad, { Size = Vector3.one * 4.4 * heft })
	follow(husk, root, root.Position, hand, 0, 0.18, hold)
	table.insert(charge.pieces, husk)

	--[[ The closing ring: a timer readable from across the arena. Its offset
		morphs inward over the windup rather than being tweened, because the
		follower owns the CFrame and would overwrite a tween every frame. ]]
	local segments = tier(level, 5, 8, 12)
	local span = (2 * math.pi * 7 * heft) / segments
	local lift = CFrame.new(0, 0.4, 0)
	for index = 1, segments do
		local angle = (index / segments) * math.pi * 2
		local outer = lift * ringSeat(angle, 7 * heft, 0)
		local inner = lift * ringSeat(angle, 1.9 * heft, 0)
		local bar =
			shell(Vector3.new(span * 0.7, 0.45, 0.7), CFrame.new(root.Position) * outer, 0.1)
		followMorph(bar, root, root.Position, outer, inner, seconds, 0, 0, hold)
		tweenTo(bar, seconds, Enum.EasingStyle.Quad, { Size = Vector3.new(span * 0.3, 0.5, 0.8) })
		table.insert(charge.pieces, bar)
	end

	-- The floor commitment: a dark plate growing to the size of what is coming,
	-- which is the part an opponent reads to decide whether to leave.
	local floor = groundY(root.Position, root.Position.Y - 3)
	local reach = if tech.kind == "ruler"
		then RULER_RADIUS
		elseif tech.kind == "forger" then FORGER_RADIUS
		else 4 * heft
	local plate = disc(
		CFrame.new(Vector3.new(root.Position.X, floor + 0.2, root.Position.Z)) * FLAT,
		1,
		0.4,
		VOID,
		0.6
	)
	tweenTo(plate, seconds, Enum.EasingStyle.Quad, {
		Size = Vector3.new(0.35, reach * 2, reach * 2),
	})
	table.insert(charge.pieces, plate)

	table.insert(
		charge.pieces,
		stream(root, hand.Position, {
			core = SHELL,
			glow = palette.glow,
			sizeFrom = 1.2,
			sizeTo = 0,
			-- Negative speed draws particles inward: energy arriving, not
			-- leaving. The one place in the file where that reads correctly.
			speed = NumberRange.new(-16, -7),
			life = NumberRange.new(0.25, 0.45),
			spread = 180,
			acceleration = Vector3.zero,
			drag = 0,
			rate = tier(level, 6, 14, 26),
		})
	)

	local token = charge.token
	task.delay(seconds + 0.4, function()
		local current = charges[casterId]
		if current and current.token == token then
			clearCharge(casterId, false)
		end
	end)
end

-- ---------------------------------------------------------------- striker: 3

--[[ Lance.

	This is the button a player presses more often than every other input
	combined, so it gets the most craft in the file rather than the least. The
	earlier instinct -- cheap technique, cheap effect, "gone in a tenth of a
	second" -- had it exactly backwards: the cheap move is where the game's
	texture lives, precisely because it is the one being pressed.

	Five things, in the order the eye picks them up:

	  1. launched from in FRONT of the caster, never on them. The first pass put
	     the muzzle a stud to the side of the root, and the flash covered the
	     caster's own head -- which made the frame *less* readable with the
	     technique than without it. Nothing about a technique may occlude the
	     person casting it.
	  2. an arc, not a line. Two points at chest height joined by a straight rod
	     read as static furniture in a frozen frame; a curve carries direction
	     with no motion blur to help it.
	  3. a third to half a second of visible travel, so it is a thing that
	     *crossed* the distance rather than a thing that was already there.
	  4. a ribbon behind it long enough to be a streak.
	  5. rings at the far end that OUTLIVE the bolt by half a second, so the
	     frame still says "something landed, from over there" after the
	     projectile itself is gone. ]]
local function drawLance(cast: Cast)
	local shot = cast.shot
	local target = shot.target
	if not target then
		return
	end

	local direction = aim(shot.origin, target)
	local across = sideways(direction)
	local from = shot.origin + direction * 2.6 + across * 1.2 - Vector3.new(0, 0.5, 0)
	local distance = (target - from).Magnitude
	-- Capped against the distance as well as the floor: a spear longer than the
	-- gap it is crossing puts its own tail back through the caster, which is the
	-- exact occlusion this pass exists to remove.
	local length = math.min(math.clamp(distance * 0.42, 2.4 * CHAR, 5 * CHAR), distance * 0.85)
	local travel = math.clamp(distance / 190, 0.3, 0.55)

	muzzle(from, direction, cast.palette, 1.2)
	local rig = spearRig(look(from, target), length, 0.62 * CHAR, cast)
	launch(rig, from, target, 0.07, 0.03, travel, function()
		rigDismiss(rig, 0.14)
		terminate(cast, target, direction, cast.weight, shot.hit)
	end)
end

--[[ Volley. Five spears in a fan.

	The identity is the count: a frame of Volley has several black shafts in it
	where Lance has exactly one, and that difference survives being shrunk to a
	thumbnail. The stagger makes it a burst rather than one thick bolt. ]]
local function drawVolley(cast: Cast)
	local shot = cast.shot
	local target = shot.target
	if not target then
		return
	end

	local direction = aim(shot.origin, target)
	local right = sideways(direction)
	local up = right:Cross(direction)
	local from = shot.origin + direction * 2.4 + right * 1
	local count = tier(cast.level, 2, 3, 5)
	local distance = (target - from).Magnitude
	local length = math.min(math.clamp(distance * 0.3, 1.6 * CHAR, 3 * CHAR), distance * 0.8)
	local travel = math.clamp(distance / 230, 0.24, 0.45)

	muzzle(from, direction, cast.palette, 1.4)

	--[[ Spread at the launch, converged at the landing. The reference barrage is
		eight copies of one mesh all arriving at a single point, and convergence is
		what makes a group of projectiles read as one attack rather than as a
		shotgun spray -- every bolt in the frame points at the same place, so the
		eye is told where to look before the first one lands. ]]
	for index = 1, count do
		local lateral = ((index - 1) / math.max(1, count - 1)) * 2 - 1
		local start = from + right * (lateral * 4.4) + up * RNG:NextNumber(-1.4, 2.4)
		local weight = if index == count then cast.weight else cast.weight * 0.4

		task.delay((index - 1) * 0.07, function()
			local rig = spearRig(look(start, target), length, 0.38 * CHAR, cast)
			launch(rig, start, target, 0.1, lateral * -0.06, travel, function()
				rigDismiss(rig, 0.12)
				terminate(cast, target, direction, weight, shot.hit)
			end)
		end)
	end
end

--[[ Pierce. The one that gets the whole frame.

	Three times Lance's damage on a five second cooldown, so this is where the
	reference ratio gets spent: up to fourteen character-lengths of beam. The
	silhouette is the inverse of Lance -- a white core with black fins and black
	bands riding it -- so the two heaviest strikers can never be confused. ]]
local function drawPierce(cast: Cast)
	local shot = cast.shot
	local target = shot.target
	if not target then
		return
	end

	local level = cast.level
	local direction = aim(shot.origin, target)
	-- In front of the caster, for the same reason Lance is.
	local from = shot.origin + direction * 2.2 + sideways(direction) * 0.9 - Vector3.new(0, 0.4, 0)
	local length = (target - from).Magnitude
	local midpoint = from:Lerp(target, 0.5)
	local axis = look(midpoint, target)
	local girth = CHAR

	-- The white core, held long enough to be read.
	local core = disc(axis * ALONG, girth * 0.45, length, SHELL, 0)
	tweenTo(core, 0.45, Enum.EasingStyle.Quart, {
		Size = Vector3.new(length, 0.08, 0.08),
		Transparency = 1,
	})
	Debris:AddItem(core, 0.52)

	-- Black fins riding it. This is the mass, and it occludes -- the beam passes
	-- in front of the world rather than glowing on top of it.
	local fins = tier(level, 2, 3, 4)
	for index = 1, fins do
		local angle = (index / fins) * math.pi * 2
		local fin = volume(
			Vector3.new(girth * 0.22, girth * 0.95, length * 0.94),
			axis * CFrame.Angles(0, 0, angle) * CFrame.new(0, girth * 0.5, 0),
			0
		)
		tweenTo(fin, 0.4, Enum.EasingStyle.Quart, {
			Size = Vector3.new(girth * 0.05, girth * 0.2, length * 0.94),
			Transparency = 1,
		})
		Debris:AddItem(fin, 0.47)
	end

	-- Black bands along its length, which is what gives a static beam direction
	-- and scale.
	local bands = tier(level, 2, 4, 7)
	for index = 1, bands do
		local at = from:Lerp(target, index / (bands + 1))
		local band = disc(look(at, at + direction) * ALONG, girth * 1.5, 0.5, VOID, 0)
		tweenTo(band, 0.34, Enum.EasingStyle.Quint, {
			Size = Vector3.new(0.2, girth * 3.6, girth * 3.6),
			Transparency = 1,
		})
		Debris:AddItem(band, 0.4)
	end

	local sleeve = disc(axis * ALONG, girth * 2.1, length, cast.palette.glow, 0.78)
	bloom(sleeve, 0.5, Vector3.new(length, girth * 4, girth * 4), Enum.EasingStyle.Quint)

	muzzle(from, direction, cast.palette, 2.4)
	terminate(cast, target, direction, cast.weight, shot.hit)

	-- It went *through*: the spray keeps going past the target.
	if shot.hit then
		spray(target + direction * 3, tier(level, 4, 9, 16), {
			core = SHELL,
			glow = cast.palette.glow,
			sizeFrom = 0.8,
			sizeTo = 0,
			speed = NumberRange.new(26, 64),
			life = NumberRange.new(0.2, 0.5),
			spread = 26,
			acceleration = direction * 20,
		})
	end
end

-- --------------------------------------------------------------- enforcer: 3

--[[ Enforcer auras.

	A self-buff nobody else can see is a stat change, not a technique. Each of
	these has to answer, from across the arena and for its whole duration, "that
	player is dangerous right now" -- and answer *which* buff, so an opponent can
	decide whether to trade or wait it out.

	One aura per caster: recasting replaces rather than stacks, so a buff window
	is never ambiguous. Emitters and lights hang off the root and ride it for
	free; only rings and plates need the follower loop. ]]
type Aura = {
	pieces: { Instance },
	token: number,
}

local auras: { [number]: Aura } = {}
local auraToken = 0

local function dropAura(userId: number)
	local existing = auras[userId]
	if not existing then
		return
	end
	auras[userId] = nil
	for _, piece in existing.pieces do
		piece:Destroy()
	end
end

-- Wind the aura down rather than snapping it off, so the end of the buff window
-- is as visible as the start of it.
local function retireAura(userId: number, token: number)
	local existing = auras[userId]
	if not existing or existing.token ~= token then
		return
	end
	auras[userId] = nil

	for _, piece in existing.pieces do
		if piece:IsA("BasePart") then
			tweenTo(piece, 0.35, Enum.EasingStyle.Quad, { Transparency = 1 })
		elseif piece:IsA("Highlight") then
			tweenTo(
				piece,
				0.35,
				Enum.EasingStyle.Quad,
				{ FillTransparency = 1, OutlineTransparency = 1 }
			)
		elseif piece:IsA("Attachment") then
			for _, child in piece:GetChildren() do
				if child:IsA("ParticleEmitter") then
					child.Enabled = false
				end
			end
		elseif piece:IsA("Trail") then
			piece.Enabled = false
		elseif piece:IsA("PointLight") then
			tweenTo(piece, 0.35, Enum.EasingStyle.Quad, { Brightness = 0 })
		end
		Debris:AddItem(piece, 1.2)
	end
end

local function openAura(userId: number, duration: number): Aura
	dropAura(userId)
	auraToken += 1
	local aura: Aura = { pieces = {}, token = auraToken }
	auras[userId] = aura
	task.delay(duration, function()
		retireAura(userId, aura.token)
	end)
	return aura
end

--[[ The body read every enforcer buff shares.

	The outline is pure white and the fill is the technique's hue held far back,
	which is law one applied to a character: value says "buffed", hue says which
	one. Occluded, so it does not shine through walls and give away a position. ]]
local function auraBody(aura: Aura, root: BasePart, palette: Palette, fill: number)
	local character = root.Parent
	if character then
		local highlight = Instance.new("Highlight")
		highlight.Adornee = character
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.FillColor = palette.glow
		highlight.FillTransparency = fill
		highlight.OutlineColor = SHELL
		highlight.OutlineTransparency = 0
		highlight.Parent = scene()
		table.insert(aura.pieces, highlight)
	end

	local light = Instance.new("PointLight")
	light.Color = palette.glow
	light.Brightness = 2
	light.Range = 15
	light.Shadows = false
	light.Parent = root
	-- Repeating and reversing, so the pulse costs nothing per frame and stops on
	-- its own when the instance goes away.
	TweenService:Create(
		light,
		TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Brightness = 4.5 }
	):Play()
	table.insert(aura.pieces, light)
end

-- The moment of activation, shared by all three: a dark plate off the feet, a
-- white ring off that, and a column of mass up the body.
local function auraOnset(centre: Vector3, palette: Palette, level: number, tall: number)
	local floor = groundY(centre, centre.Y - 3)
	local base = Vector3.new(centre.X, floor + 0.2, centre.Z)

	shadowWave(base, 6, 46, 0.5, level)

	local column =
		volume(Vector3.new(4.6, tall, 4.6), CFrame.new(base + Vector3.new(0, tall * 0.5, 0)), 0.25)
	bloom(column, 0.42, Vector3.new(0.7, tall * 1.4, 0.7), Enum.EasingStyle.Quint)

	-- Four white staves up the dark column rather than a white slab around it.
	-- Same read, a twentieth of the lit area.
	for index = 1, 4 do
		local angle = (index / 4) * math.pi * 2
		local stave = shell(
			Vector3.new(0.4, tall * 0.9, 0.4),
			CFrame.new(base + Vector3.new(0, tall * 0.45, 0))
				* CFrame.Angles(0, angle, 0)
				* CFrame.new(2.6, 0, 0),
			0.05
		)
		tweenTo(stave, 0.38, Enum.EasingStyle.Quint, {
			CFrame = CFrame.new(base + Vector3.new(0, tall * 0.62, 0))
				* CFrame.Angles(0, angle, 0)
				* CFrame.new(5, 0, 0),
			Size = Vector3.new(0.15, tall * 1.2, 0.15),
			Transparency = 1,
		})
		Debris:AddItem(stave, 0.4)
	end

	spray(base + Vector3.new(0, 1.5, 0), tier(level, 6, 14, 24), {
		core = SHELL,
		glow = palette.glow,
		sizeFrom = 0.9,
		sizeTo = 0,
		speed = NumberRange.new(10, 26),
		life = NumberRange.new(0.3, 0.6),
		spread = 28,
		acceleration = Vector3.new(0, 14, 0),
		drag = 2,
	})
	flare(base + Vector3.new(0, 3, 0), palette.core, 6, 26)
end

--[[ Surge. Damage up, so it burns.

	A dark smoke column climbing off the body with white-hot rings turning inside
	it. The smoke is the mass -- without it a fire aura is a bright smear, and a
	bright smear is what the first pass shipped. ]]
local function drawSurge(cast: Cast)
	local shot = cast.shot
	local palette = cast.palette
	auraOnset(shot.origin, palette, cast.level, 2.9 * CHAR)

	local root = rootOf(shot.casterId)
	if not root then
		return
	end
	local aura = openAura(shot.casterId, cast.duration)
	auraBody(aura, root, palette, 0.8)

	table.insert(
		aura.pieces,
		stream(root, Vector3.new(0, -1.6, 0), {
			core = palette.core,
			glow = palette.glow,
			sizeFrom = 0.2,
			sizeTo = 1.8,
			speed = NumberRange.new(6, 13),
			life = NumberRange.new(0.35, 0.7),
			spread = 22,
			acceleration = Vector3.new(0, 16, 0),
			drag = 1.5,
			rate = tier(cast.level, 6, 16, 34),
		})
	)

	-- Dark smoke over the flame, so the aura has a silhouette against a bright
	-- sky as well as against dark stone.
	table.insert(
		aura.pieces,
		stream(root, Vector3.new(0, 1.2, 0), {
			core = ASH,
			glow = VOID,
			sizeFrom = 2,
			sizeTo = 7,
			speed = NumberRange.new(4, 9),
			life = NumberRange.new(0.8, 1.4),
			spread = 30,
			acceleration = Vector3.new(0, 6, 0),
			drag = 1.5,
			rate = tier(cast.level, 3, 7, 14),
			dusty = true,
		})
	)

	if cast.level < DETAIL_MID then
		return
	end

	-- Two rings turning against each other. Counter-rotation is the tell that
	-- separates Surge from Swiftstep's single fast ring at a glance.
	for index = 1, 2 do
		local bars = barRing(
			root,
			root.Position,
			1.6 * CHAR - index * 0.5 * CHAR,
			tier(cast.level, 5, 7, 9),
			0.45,
			CFrame.new(0, -2.7 + index * 2.6, 0),
			if index == 1 then 5.5 else -4.2,
			cast.duration + 0.4,
			index == 1
		)
		for _, bar in bars do
			table.insert(aura.pieces, bar)
		end
	end
end

--[[ Bulwark. Mitigation up, so it armours.

	Black plates with white edges orbiting the body -- deliberately *not* a dome,
	because Barrier is a dome and these two must never be confused: 40% for six
	seconds and 55% for eight are different decisions to fight into. ]]
local function drawBulwark(cast: Cast)
	local shot = cast.shot
	local palette = cast.palette
	auraOnset(shot.origin, palette, cast.level, 2.3 * CHAR)

	local root = rootOf(shot.casterId)
	if not root then
		return
	end
	local aura = openAura(shot.casterId, cast.duration)
	auraBody(aura, root, palette, 0.86)

	local plates = tier(cast.level, 2, 3, 4)
	for index = 1, plates do
		local angle = (index / plates) * math.pi * 2
		local seat = CFrame.Angles(0, angle, 0) * CFrame.new(0, 0.2, -5.3)

		local plate = volume(Vector3.new(8.4, 10.2, 0.5), root.CFrame * seat, 0)
		-- Slammed in from outside, so the guard *closes* rather than appearing.
		tweenTo(plate, 0.28, Enum.EasingStyle.Back, { Size = Vector3.new(5.6, 6.8, 0.5) })
		follow(plate, root, root.Position, seat, 1.5, 0.25, cast.duration + 0.4)
		table.insert(aura.pieces, plate)

		-- The white edge. One thin strip is all the value contrast a black plate
		-- needs to be legible against dark stone.
		local edge = shell(Vector3.new(5.8, 0.4, 0.6), root.CFrame * seat, 0)
		follow(
			edge,
			root,
			root.Position,
			seat * CFrame.new(0, 3.5, -0.1),
			1.5,
			0.25,
			cast.duration + 0.4
		)
		table.insert(aura.pieces, edge)
	end

	for _, bar in
		barRing(
			root,
			root.Position,
			1.55 * CHAR,
			tier(cast.level, 6, 8, 11),
			0.5,
			CFrame.new(0, -2.9, 0),
			1.1,
			cast.duration + 0.4,
			true
		)
	do
		table.insert(aura.pieces, bar)
	end
end

--[[ Swiftstep. The cheap one, so it stays light.

	No shell, no plates: a low fast ring, a ribbon off the hips, and dark
	afterimages that exist only because the player is moving. The only aura whose
	intensity depends on what the player does with it. ]]
local function drawSwiftstep(cast: Cast)
	local shot = cast.shot
	local palette = cast.palette
	auraOnset(shot.origin, palette, cast.level, 1.9 * CHAR)

	local root = rootOf(shot.casterId)
	if not root then
		return
	end
	local aura = openAura(shot.casterId, cast.duration)
	auraBody(aura, root, palette, 0.9)

	local back = Instance.new("Attachment")
	back.Position = Vector3.new(-1.1, -0.6, 0.4)
	back.Parent = root
	table.insert(aura.pieces, back)

	local front = Instance.new("Attachment")
	front.Position = Vector3.new(1.1, -0.6, 0.4)
	front.Parent = root
	table.insert(aura.pieces, front)

	local trail = Instance.new("Trail")
	trail.Attachment0 = back
	trail.Attachment1 = front
	trail.Lifetime = 0.45
	trail.MinLength = 0.2
	trail.FaceCamera = true
	trail.LightEmission = 1
	trail.LightInfluence = 0
	trail.Color = ColorSequence.new(SHELL, palette.glow)
	trail.Transparency = NumberSequence.new(0.2, 1)
	trail.WidthScale = NumberSequence.new(1, 0)
	trail.Parent = root
	table.insert(aura.pieces, trail)

	for _, bar in
		barRing(
			root,
			root.Position,
			1.3 * CHAR,
			tier(cast.level, 5, 7, 10),
			0.4,
			CFrame.new(0, -3, 0),
			9,
			cast.duration + 0.4,
			true
		)
	do
		table.insert(aura.pieces, bar)
	end

	if cast.level < DETAIL_MID then
		return
	end

	--[[ Afterimages: a dark slab dropped where the body just was, fading over
		half a second. Invisible while standing still and unmistakable at a
		sprint, which is exactly what the buff does. ]]
	local finish = os.clock() + cast.duration
	task.spawn(function()
		local previous = root.Position
		while os.clock() < finish do
			task.wait(0.09)
			if not root.Parent then
				break
			end
			local moved = (root.Position - previous).Magnitude
			previous = root.Position
			if moved < 1.2 then
				continue
			end
			local ghost = volume(Vector3.new(2.6, 5, 1.4), root.CFrame, 0.4)
			tweenTo(ghost, 0.45, Enum.EasingStyle.Quad, {
				Size = Vector3.new(2, 4.4, 1),
				Transparency = 1,
			})
			Debris:AddItem(ghost, 0.5)

			local spark = rim(Vector3.new(0.35, 5.2, 0.35), root.CFrame, palette.glow, 0.25)
			fadeOut(spark, 0.35)
		end
	end)
end

-- ----------------------------------------------------------------- forger: 3

--[[ Barrier. A wall driven into the ground around you.

	The first pass made this a translucent dome and the dome was the brightest
	thing in the frame. It is now a low black wall with white caps: opaque, so it
	actually occludes; kept under head height, so it never blinds the caster it is
	protecting; with the hue reduced to a film you can read the world through. ]]
local function drawBarrier(cast: Cast)
	local shot = cast.shot
	local palette = cast.palette
	local level = cast.level
	local floor = groundY(shot.origin, shot.origin.Y - 3)
	local base = Vector3.new(shot.origin.X, floor + 0.1, shot.origin.Z)

	shadowWave(base, 7, 36, 0.5, level)
	flare(base + Vector3.new(0, 4, 0), palette.core, 8, 34)

	local root = rootOf(shot.casterId)
	local seat = if root then root.Position else shot.origin
	local duration = cast.duration
	local radius = 1.35 * CHAR
	local slabs = tier(level, 5, 8, 12)

	for index = 1, slabs do
		local angle = (index / slabs) * math.pi * 2
		local span = (2 * math.pi * radius) / slabs
		local stand = CFrame.Angles(0, angle, 0) * CFrame.new(0, -1, -radius) * ALONG

		-- Dropped in from above rather than faded in: a placement should land.
		local high = CFrame.new(seat + Vector3.new(0, 11, 0)) * stand
		local slab = volume(Vector3.new(0.55, 3.6, span * 0.92), high, 0)
		followMorph(
			slab,
			root,
			seat,
			stand * CFrame.new(0, 11, 0),
			stand,
			0.22,
			0.25,
			0,
			duration + 0.4
		)

		local cap = shell(Vector3.new(0.68, 0.34, span * 0.92), high, 0)
		followMorph(
			cap,
			root,
			seat,
			stand * CFrame.new(0, 12.9, 0),
			stand * CFrame.new(0, 1.9, 0),
			0.22,
			0.25,
			0,
			duration + 0.4
		)

		task.delay(0.22 + index * 0.01, function()
			if slab.Parent then
				spray(slab.Position, tier(level, 2, 3, 5), {
					core = ASH,
					glow = VOID,
					sizeFrom = 1,
					sizeTo = 3,
					speed = NumberRange.new(3, 9),
					life = NumberRange.new(0.3, 0.6),
					spread = 90,
					dusty = true,
				})
			end
		end)

		task.delay(duration, function()
			fadeOut(slab, 0.35)
			fadeOut(cap, 0.35)
		end)
	end

	-- The hue lives here and nowhere else in this technique: a film thin enough
	-- to read the world straight through.
	if level >= DETAIL_MID then
		local film = ball(seat, 2.95 * CHAR, palette.glow, 0.9)
		film.Material = Enum.Material.ForceField
		follow(film, root, seat, CFrame.new(0, 0.6, 0), 0.35, 0, duration + 0.4)
		task.delay(duration, function()
			fadeOut(film, 0.35)
		end)
	end
end

--[[ Caltrops. Spikes thrown out and planted.

	The server drops one flat cylinder for the damage volume; this is what makes
	that volume mean something. Black spikes with white tips, scattered evenly by
	area across the whole radius so the hazard's *edge* is visible -- a zoning
	tool whose boundary you cannot see is just unfair damage. ]]
local function drawCaltrops(cast: Cast)
	local shot = cast.shot
	local palette = cast.palette
	local level = cast.level
	local duration = cast.duration
	local floor = groundY(shot.origin, shot.origin.Y - 3)
	local centre = Vector3.new(shot.origin.X, floor, shot.origin.Z)

	shadowWave(centre, 5, FORGER_RADIUS * 2, 0.45, level)
	scar(centre, FORGER_RADIUS, palette, duration, level)

	local count = tier(level, 4, 8, 13)
	for index = 1, count do
		local angle = RNG:NextNumber(0, math.pi * 2)
		-- Square-rooted radius, so the scatter is even by area instead of
		-- clustering at the middle.
		local radius = math.sqrt(RNG:NextNumber(0.08, 1)) * (FORGER_RADIUS - 1.5)
		local at = centre + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		local height = RNG:NextNumber(4.6, 7.2)
		local tilt = CFrame.Angles(
			RNG:NextNumber(-0.22, 0.22),
			RNG:NextNumber(0, math.pi * 2),
			RNG:NextNumber(-0.22, 0.22)
		)

		local high = CFrame.new(at + Vector3.new(0, height * 1.8, 0)) * tilt
		local planted = CFrame.new(at + Vector3.new(0, height * 0.44, 0)) * tilt
		local spike = wedgeVolume(Vector3.new(1.15, height, 2.1), high)
		local tip = shell(Vector3.new(0.45, 1.3, 0.45), high, 0)
		local tipSeat = planted * CFrame.new(0, height * 0.44, 0.35)

		task.delay(index * 0.024, function()
			if not spike.Parent then
				return
			end
			-- Thrown, not grown: they arrive fast and stop dead.
			tweenTo(spike, 0.13, Enum.EasingStyle.Quart, { CFrame = planted })
			tweenTo(tip, 0.13, Enum.EasingStyle.Quart, { CFrame = tipSeat })
			task.delay(0.13, function()
				spray(at, tier(level, 2, 4, 7), {
					core = ASH,
					glow = VOID,
					sizeFrom = 0.9,
					sizeTo = 2.6,
					speed = NumberRange.new(4, 12),
					life = NumberRange.new(0.3, 0.7),
					spread = 90,
					dusty = true,
				})
			end)
		end)

		task.delay(duration, function()
			if spike.Parent then
				tweenTo(spike, 0.4, Enum.EasingStyle.Quad, {
					CFrame = CFrame.new(at - Vector3.new(0, height, 0)) * tilt,
					Transparency = 1,
				})
			end
			fadeOut(tip, 0.4)
		end)
		Debris:AddItem(spike, duration + 0.5)
		Debris:AddItem(tip, duration + 0.5)
	end

	--[[ A wave on the damage interval. Constructs tick rather than damaging
		continuously, so the field announces each tick before it lands and standing
		in it becomes a choice instead of a surprise. ]]
	task.spawn(function()
		local finish = os.clock() + duration - 0.1
		while os.clock() < finish do
			task.wait(PULSE_SECONDS)
			if os.clock() >= finish then
				break
			end
			shadowWave(centre, 3, FORGER_RADIUS * 2, 0.55, level)
		end
	end)
end

--[[ Sentry. A core assembled in the air.

	The most expensive Forger technique and the only one with a silhouette above
	knee height, which is what makes it worth walking around: you can see a Sentry
	from outside its radius. Plates converge, the core snaps on, and a scan sweeps
	the ground on every damage tick. ]]
local function drawSentry(cast: Cast)
	local shot = cast.shot
	local palette = cast.palette
	local level = cast.level
	local duration = cast.duration
	local floor = groundY(shot.origin, shot.origin.Y - 3)
	local centre = Vector3.new(shot.origin.X, floor, shot.origin.Z)
	local eye = centre + Vector3.new(0, 2 * CHAR, 0)

	shadowWave(centre, 4, FORGER_RADIUS * 1.7, 0.5, level)
	scar(centre, FORGER_RADIUS, palette, duration, level)

	-- Plates fly in and converge: it is being built, not switched on.
	local plates = tier(level, 3, 4, 6)
	for index = 1, plates do
		local angle = (index / plates) * math.pi * 2
		local away = Vector3.new(math.cos(angle) * 16, RNG:NextNumber(1, 7), math.sin(angle) * 16)
		local plate = volume(
			Vector3.new(3.6, 0.55, 3.6),
			CFrame.new(eye + away) * CFrame.Angles(RNG:NextNumber(0, 3), angle, 0),
			0
		)
		tweenTo(plate, 0.3, Enum.EasingStyle.Quint, {
			CFrame = CFrame.new(eye) * CFrame.Angles(0, angle, 0),
			Size = Vector3.new(0.7, 0.25, 0.7),
			Transparency = 1,
		})
		Debris:AddItem(plate, 0.38)
	end

	task.delay(0.3, function()
		flare(eye, palette.core, 9, 30)
		spray(eye, tier(level, 5, 12, 20), {
			core = SHELL,
			glow = palette.glow,
			sizeFrom = 0.8,
			sizeTo = 0,
			speed = NumberRange.new(12, 30),
			life = NumberRange.new(0.2, 0.45),
			spread = 180,
			acceleration = Vector3.new(0, -10, 0),
		})

		-- Black body, white equator: the device reads at any distance and in any
		-- light without depending on its colour.
		local body = ball(eye, 0.6, VOID, 0)
		tweenTo(body, 0.18, Enum.EasingStyle.Back, { Size = Vector3.one * 4.8 })
		follow(body, nil, eye, CFrame.identity, 2.4, 0.5, duration - 0.3)

		local equator = barRing(
			nil,
			eye,
			3.6,
			tier(level, 6, 8, 10),
			0.42,
			CFrame.identity,
			2.4,
			duration - 0.3,
			false
		)
		local orbit = barRing(
			nil,
			eye,
			6.2,
			tier(level, 6, 9, 12),
			0.38,
			CFrame.Angles(0.5, 0, 0),
			3.2,
			duration - 0.3,
			false
		)

		local light = Instance.new("PointLight")
		light.Color = palette.glow
		light.Brightness = 3
		light.Range = 24
		light.Shadows = false
		light.Parent = body

		-- The mast ties the floating core to the ground it is guarding.
		local mast = volume(
			Vector3.new(1.3, 2 * CHAR, 1.3),
			CFrame.new(centre + Vector3.new(0, CHAR, 0)),
			0.25
		)

		task.delay(duration - 0.3, function()
			fadeOut(body, 0.3)
			fadeOut(mast, 0.3)
			for _, bar in equator do
				fadeOut(bar, 0.3)
			end
			for _, bar in orbit do
				fadeOut(bar, 0.3)
			end
		end)
		Debris:AddItem(mast, duration)
	end)

	task.spawn(function()
		local finish = os.clock() + duration - 0.2
		while os.clock() < finish do
			task.wait(PULSE_SECONDS)
			if os.clock() >= finish then
				break
			end
			shadowWave(centre, 3, FORGER_RADIUS * 2, 0.5, level)
			local drop = shell(
				Vector3.new(1, 1, 1.7 * CHAR),
				CFrame.new(eye - Vector3.new(0, 4, 0)) * CFrame.Angles(math.pi / 2, 0, 0),
				0.1
			)
			bloom(drop, 0.26, Vector3.new(0.12, 0.12, 2 * CHAR), Enum.EasingStyle.Quad)
		end
	end)
end

-- ------------------------------------------------------------------ ruler: 3

--[[ Ruler techniques command terrain across a 42 stud radius -- fifteen
	character-heights -- and are the most expensive things a player can spend
	madra on. They are the only casts that throw real geometry and leave the
	ground altered for seconds afterwards. All three fill the same circle, so they
	are told apart by direction of motion: out, in, up. ]]

--[[ Upheaval. The ground comes up.

	Slate slabs punched out of the floor with white rims along their broken top
	edges, and dust that outlives all of it. Reads as *outward and upward* in one
	frame. ]]
local function drawUpheaval(cast: Cast)
	local shot = cast.shot
	local palette = cast.palette
	local level = cast.level
	local floor = groundY(shot.origin, shot.origin.Y - 3)
	local centre = Vector3.new(shot.origin.X, floor, shot.origin.Z)

	flare(centre + Vector3.new(0, 2, 0), palette.core, 8, 50)
	shadowWave(centre, 7, RULER_RADIUS * 2, 0.6, level)
	scar(centre, RULER_RADIUS, palette, 4.5, level)

	local slabs = tier(level, 5, 9, 15)
	for _ = 1, slabs do
		local angle = RNG:NextNumber(0, math.pi * 2)
		local radius = math.sqrt(RNG:NextNumber(0.05, 1)) * (RULER_RADIUS - 3)
		local at = centre + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		local width = RNG:NextNumber(4, 9)
		local height = RNG:NextNumber(1.4 * CHAR, 2.9 * CHAR)
		local tilt = CFrame.Angles(
			RNG:NextNumber(-0.3, 0.3),
			RNG:NextNumber(0, math.pi * 2),
			RNG:NextNumber(-0.3, 0.3)
		)

		local buried = CFrame.new(at - Vector3.new(0, height, 0)) * tilt
		local slab = Instance.new("Part")
		slab.Size = Vector3.new(width, height, width * 0.8)
		slab.CFrame = buried
		slab.Color = ROCK
		slab.Material = Enum.Material.Slate
		decorate(slab)

		local risen = CFrame.new(at + Vector3.new(0, height * RNG:NextNumber(0.16, 0.4), 0)) * tilt
		local lip = shell(Vector3.new(width * 0.9, 0.35, width * 0.7), buried, 0)

		-- Farther slabs erupt later, so the wave visibly travels outward instead
		-- of the whole field popping at once.
		local delay = (radius / RULER_RADIUS) * 0.24

		task.delay(delay, function()
			if not slab.Parent then
				return
			end
			tweenTo(slab, 0.14, Enum.EasingStyle.Back, { CFrame = risen })
			tweenTo(lip, 0.14, Enum.EasingStyle.Back, {
				CFrame = risen * CFrame.new(0, height * 0.5, 0),
			})
			spray(at, tier(level, 4, 8, 14), {
				core = ASH,
				glow = VOID,
				sizeFrom = 2,
				sizeTo = 7,
				speed = NumberRange.new(8, 24),
				life = NumberRange.new(0.6, 1.3),
				spread = 60,
				acceleration = Vector3.new(0, -10, 0),
				drag = 2.5,
				dusty = true,
			})
		end)

		-- Held, then sunk. The settle gives the cast weight on the way out as
		-- well as on the way in.
		task.delay(delay + 0.8, function()
			if slab.Parent then
				tweenTo(slab, 0.9, Enum.EasingStyle.Quad, {
					CFrame = buried,
					Transparency = 1,
				})
			end
			fadeOut(lip, 0.6)
		end)
		Debris:AddItem(slab, delay + 1.8)
		Debris:AddItem(lip, delay + 1.8)
	end

	-- One dust column over the middle, on top of the per-slab dust. Dark, so a
	-- second and a half of lingering mass costs nothing in readability.
	spray(centre + Vector3.new(0, 2, 0), tier(level, 10, 22, 40), {
		core = ASH,
		glow = VOID,
		sizeFrom = 4,
		sizeTo = 13,
		speed = NumberRange.new(12, 34),
		life = NumberRange.new(0.9, 1.7),
		spread = 180,
		acceleration = Vector3.new(0, -5, 0),
		drag = 2,
		dusty = true,
	})
end

--[[ Siphon. Everything comes in.

	The first pass painted the whole radius emissive purple and you could not see
	the person you were fighting. The field is now a dark plate with a white
	boundary and black furrows pointing inward; the hue survives only in the
	streaks. Reads as *inward* -- the exact inverse of Upheaval, which is how the
	two stay distinguishable at the same radius. ]]
local function drawSiphon(cast: Cast)
	local shot = cast.shot
	local palette = cast.palette
	local level = cast.level
	local floor = groundY(shot.origin, shot.origin.Y - 3)
	local centre = Vector3.new(shot.origin.X, floor, shot.origin.Z)
	local heart = shot.origin

	scar(centre, RULER_RADIUS, palette, 2.6, level)

	-- Furrows: black bars pointing at the middle. They state the radius without
	-- covering a single thing standing inside it.
	local furrows = tier(level, 5, 9, 14)
	for index = 1, furrows do
		local angle = (index / furrows) * math.pi * 2
		local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local outer = centre + direction * (RULER_RADIUS * 0.62) + Vector3.new(0, 0.3, 0)
		local inner = centre + direction * 4 + Vector3.new(0, 0.3, 0)
		local furrow = volume(Vector3.new(1.6, 0.4, RULER_RADIUS * 0.75), look(outer, centre), 0.15)
		tweenTo(furrow, 0.5, Enum.EasingStyle.Quart, {
			CFrame = look(inner, centre),
			Size = Vector3.new(0.4, 0.4, 6),
			Transparency = 1,
		})
		Debris:AddItem(furrow, 0.58)
	end

	-- The closing ring: the one motion in the game that runs inward.
	ringAt(
		centre + Vector3.new(0, 0.3, 0),
		RULER_RADIUS,
		tier(level, 8, 14, 22),
		1,
		SHELL,
		0.45,
		0.1,
		true
	)

	--[[ The inrush. Darts rather than bare bars: a flat untextured rectangle
		flying at an arbitrary angle reads as a bug, while a black body with a
		white nose reads as an object with a front, and brings its own value
		anchor with it instead of relying on the hue to be seen. ]]
	local streaks = tier(level, 5, 10, 16)
	for index = 1, streaks do
		local angle = (index / streaks) * math.pi * 2 + RNG:NextNumber(-0.25, 0.25)
		local edge = centre
			+ Vector3.new(math.cos(angle), 0, math.sin(angle)) * RULER_RADIUS
			+ Vector3.new(0, RNG:NextNumber(0.5, 2.4 * CHAR), 0)
		local rig = dartRig(look(edge, heart), RNG:NextNumber(1.4 * CHAR, 2.4 * CHAR), 0.75)

		task.delay(index * 0.014, function()
			rigFly(rig, look(heart, heart + aim(edge, heart)), 0.36, Enum.EasingStyle.Quart)
			rigDismiss(rig, 0.36)
		end)
	end

	--[[ The column. Vertical mass is what stops a Ruler cast from being a rug --
		the frame is landscape and a ground disc is squashed flat by perspective,
		so the technique needs something standing up in it. ]]
	local column = volume(
		Vector3.new(1.6 * CHAR, 5.5 * CHAR, 1.6 * CHAR),
		CFrame.new(centre + Vector3.new(0, 2.75 * CHAR, 0)),
		0.5
	)
	tweenTo(column, 0.55, Enum.EasingStyle.Quart, {
		Size = Vector3.new(1, 6 * CHAR, 1),
		Transparency = 1,
	})
	Debris:AddItem(column, 0.62)

	-- Bands riding up the column and closing as they climb.
	for index = 1, tier(level, 1, 2, 4) do
		edgeRing(
			CFrame.new(centre + Vector3.new(0, index * 2.2, 0)),
			CFrame.new(centre + Vector3.new(0, index * 5 + 6, 0)) * CFrame.Angles(0, index * 2.2, 0),
			1.5 * CHAR,
			tier(level, 5, 7, 10),
			0.55,
			SHELL,
			0.6,
			0.15,
			false
		)
	end

	-- Drawn up the column rather than thrown out of it, which is the only way a
	-- particle burst reads as absorption instead of as an explosion.
	spray(centre + Vector3.new(0, 1, 0), tier(level, 8, 16, 28), {
		core = SHELL,
		glow = palette.glow,
		sizeFrom = 1.6,
		sizeTo = 0,
		speed = NumberRange.new(5, 14),
		life = NumberRange.new(0.4, 0.8),
		spread = 35,
		acceleration = Vector3.new(0, 30, 0),
		drag = 1,
	})

	--[[ The swallow, timed to when the streaks arrive. Terminated as a *ground*
		event, not a body one: the technique is closing on the caster's own feet,
		and whether it took anybody with it is Impact's broadcast to answer, once
		per victim, wherever those victims are standing. ]]
	task.delay(0.36, function()
		terminate(cast, heart, Vector3.new(0, 1, 0), cast.weight, false)
	end)
end

--[[ Tempest. The sky comes down.

	The most expensive technique in the game and the only one that draws from
	above the play space: a black storm ceiling, bolts landing in a stagger across
	the whole radius, and a shock ring off the last one. If any single cast should
	stop a fight to be looked at, it is this one. ]]
local function drawTempest(cast: Cast)
	local shot = cast.shot
	local palette = cast.palette
	local level = cast.level
	local floor = groundY(shot.origin, shot.origin.Y - 3)
	local centre = Vector3.new(shot.origin.X, floor, shot.origin.Z)

	shadowWave(centre, 5, RULER_RADIUS * 2, 0.7, level)
	scar(centre, RULER_RADIUS, palette, 5, level)

	--[[ The ceiling. A black slab overhead is what makes this read as weather
		rather than as fireworks, and being dark it can cover the top of the frame
		without costing any visibility at ground level. ]]
	local ceiling =
		disc(CFrame.new(centre + Vector3.new(0, 7 * CHAR, 0)) * FLAT, RULER_RADIUS, 2.5, VOID, 0.5)
	tweenTo(ceiling, 1.5, Enum.EasingStyle.Quint, {
		Size = Vector3.new(1, RULER_RADIUS * 2.3, RULER_RADIUS * 2.3),
		Transparency = 1,
	})
	Debris:AddItem(ceiling, 1.6)

	-- Bands rising into it, each turned further than the last so the column reads
	-- as one rotation.
	local bands = tier(level, 2, 3, 5)
	for index = 1, bands do
		edgeRing(
			CFrame.new(centre + Vector3.new(0, index * 1.5, 0)),
			CFrame.new(centre + Vector3.new(0, 6 + index * 5.5, 0))
				* CFrame.Angles(0, index * 1.4, 0),
			RULER_RADIUS * 0.5,
			tier(level, 8, 12, 18),
			0.8,
			SHELL,
			1,
			1.9,
			false
		)
	end

	spray(centre + Vector3.new(0, 3, 0), tier(level, 10, 22, 40), {
		core = ASH,
		glow = VOID,
		sizeFrom = 3,
		sizeTo = 10,
		speed = NumberRange.new(18, 48),
		life = NumberRange.new(0.7, 1.5),
		spread = 180,
		acceleration = Vector3.new(0, 8, 0),
		drag = 1.5,
		dusty = true,
	})

	local strikes = tier(level, 2, 3, 5)
	local last = 0
	for index = 1, strikes do
		local angle = RNG:NextNumber(0, math.pi * 2)
		local radius = math.sqrt(RNG:NextNumber(0.02, 1)) * (RULER_RADIUS - 2)
		local at = centre + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		local delay = 0.18 + (index - 1) * (0.85 / strikes)
		last = math.max(last, delay)

		task.delay(delay, function()
			-- A jagged polyline, because a straight line is a pole and a bent one
			-- is lightning. White spine in a black sheath, so a bolt is readable
			-- against a bright sky as well as against dark stone.
			local top = at + Vector3.new(RNG:NextNumber(-8, 8), 7 * CHAR, RNG:NextNumber(-8, 8))
			local segments = tier(level, 3, 5, 7)
			local previous = top
			for step = 1, segments do
				local along = step / segments
				local spreadOut = (1 - along) * 5
				local point = if step == segments
					then at
					else top:Lerp(at, along) + Vector3.new(
						RNG:NextNumber(-spreadOut, spreadOut),
						0,
						RNG:NextNumber(-spreadOut, spreadOut)
					)
				local length = (point - previous).Magnitude
				local frame = look(previous:Lerp(point, 0.5), point)

				local sheath = volume(Vector3.new(2.4, 2.4, length), frame, 0.25)
				tweenTo(sheath, 0.2, Enum.EasingStyle.Quad, {
					Size = Vector3.new(0.4, 0.4, length),
					Transparency = 1,
				})
				Debris:AddItem(sheath, 0.26)

				local spine = shell(Vector3.new(1, 1, length), frame, 0)
				tweenTo(spine, 0.16, Enum.EasingStyle.Quad, {
					Size = Vector3.new(0.1, 0.1, length),
					Transparency = 1,
				})
				Debris:AddItem(spine, 0.22)
				previous = point
			end

			-- A bolt lands on the ground; whether it also landed on somebody is
			-- Impact's event to draw, at that person, not at this crater.
			terminate(
				cast,
				at + Vector3.new(0, 1, 0),
				Vector3.new(0, 1, 0),
				cast.weight * 0.7,
				false
			)
			flare(at + Vector3.new(0, 2, 0), palette.core, 9, 38)
		end)
	end

	-- The last bolt lands and the storm blows outward: the cast has an ending,
	-- not just a stop.
	task.delay(last + 0.18, function()
		ringAt(
			centre + Vector3.new(0, 0.4, 0),
			RULER_RADIUS * 0.25,
			tier(level, 8, 14, 24),
			1.4,
			SHELL,
			0.55,
			4,
			true
		)
		shadowWave(centre, 10, RULER_RADIUS * 2.2, 0.5, level)
	end)
end

-- ------------------------------------------------------------------- dispatch

local DRAW: { [string]: Draw } = {
	lance = drawLance,
	volley = drawVolley,
	pierce = drawPierce,
	surge = drawSurge,
	bulwark = drawBulwark,
	swiftstep = drawSwiftstep,
	barrier = drawBarrier,
	caltrops = drawCaltrops,
	sentry = drawSentry,
	upheaval = drawUpheaval,
	siphon = drawSiphon,
	tempest = drawTempest,
}

--[[ Anything the table does not know still draws something. A technique added to
	Config without a drawing here would otherwise be silent, and a silent button
	is indistinguishable from a broken one. ]]
local function drawFallback(cast: Cast)
	local shot = cast.shot
	local target = shot.target
	if target then
		local direction = aim(shot.origin, target)
		local rig = spearRig(look(shot.origin, target), 3 * CHAR, 0.5 * CHAR, cast)
		rigFly(rig, look(target, target + direction), 0.18, Enum.EasingStyle.Linear)
		task.delay(0.18, function()
			rigDismiss(rig, 0.1)
			terminate(cast, target, direction, cast.weight, shot.hit)
		end)
		return
	end
	local floor = groundY(shot.origin, shot.origin.Y - 3)
	shadowWave(Vector3.new(shot.origin.X, floor, shot.origin.Z), 5, 24, 0.45, cast.level)
end

--[[ Local cooldown mirror, seeded only from *confirmed* casts.

	This exists so the windup telegraph below does not fire on a press the server
	is going to throw away. It follows the same rule the slot bar does: a refused
	press never puts anything on a cooldown it did not pay for. ]]
local confirmedUntil: { [string]: number } = {}
local gcdUntil = 0

function Vfx.play(shot: Shot)
	-- Remote payloads are untyped at runtime, so the two fields every path below
	-- dereferences are checked before anything is drawn.
	if typeof(shot.techId) ~= "string" or typeof(shot.origin) ~= "Vector3" then
		return
	end

	-- The windup is over the moment the server says the technique resolved.
	clearCharge(shot.casterId, true)

	local tech = Config.Techniques[shot.techId]
	if tech and isLocalCaster(shot) then
		local now = os.clock()
		confirmedUntil[shot.techId] = now + tech.cooldown
		gcdUntil = now + Config.Combat.globalCooldown
	end

	--[[ Detail is judged at whichever end of the technique is closer to the
		camera. A shot fired from across the arena still lands next to you, and the
		frame where you are the one being hit is the last frame that should be
		economised. Your own casts are always full: a technique that degrades in
		your own hands reads as broken rather than as optimised. ]]
	local level: number
	if isLocalCaster(shot) then
		level = DETAIL_FULL
	else
		level = detailAt(shot.origin)
		local landing = shot.target
		if landing then
			level = math.max(level, detailAt(landing))
		end
	end
	if level <= DETAIL_NONE then
		return
	end

	local cast: Cast = {
		shot = shot,
		palette = PALETTE[shot.techId] or FALLBACK,
		duration = if tech then tech.buffDuration else 0,
		-- Heft from configured damage, so retuning a technique retunes how hard
		-- it looks without anybody editing this file.
		weight = if tech then math.clamp(tech.damage / 70, 0.5, 2) else 1,
		level = level,
	}

	local draw = DRAW[shot.techId] or drawFallback
	draw(cast)
end

--[[ The local caster's own windup.

	The server broadcasts on resolve, never on cast, so this is the only windup
	the client can currently know about. It starts from the keypress, is gated on
	the same Config the server charges from, and if no broadcast confirms within
	the windup then `clearCharge` collapses it inward instead of releasing it --
	so a refused press reads as a refused press rather than as a technique that
	fired and did nothing.

	This listener sends nothing and decides nothing. Input authority stays exactly
	where it was. ]]
local function localWindup(slot: string)
	local player = Players.LocalPlayer
	if not player then
		return
	end
	local techId = player:GetAttribute("Slot_" .. slot)
	if typeof(techId) ~= "string" then
		return
	end
	local tech = Config.Techniques[techId]
	if not tech then
		return
	end

	local now = os.clock()
	if now < gcdUntil or now < (confirmedUntil[techId] or 0) then
		return
	end
	local madra = player:GetAttribute("Madra")
	if typeof(madra) == "number" and madra < tech.madraCost then
		return
	end

	Vfx.charge(techId, player.UserId)
end

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
		localWindup(slot)
	end
end)

return Vfx
