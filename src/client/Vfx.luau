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

	Three rules hold everywhere below.

	1. **Never obstruct the server.** Every BasePart is Anchored, CanCollide=false,
	   CanQuery=false, CanTouch=false. The striker raycast and both Ruler/construct
	   overlap queries run on the server against instances that do not exist there
	   at all -- but the same code runs in a listen-server Studio session, so the
	   query flags are what actually guarantee a beam cannot eat a shot.

	2. **Each of the twelve reads in one frame.** A blind frame of Volley must not
	   be confusable with Lance, and Upheaval must not be confusable with Tempest.
	   Silhouette does that work, not colour: spear, fan, beam; column, plates,
	   ribbons; dome, spikes, floating core; slabs, inward streaks, vortex.

	3. **Cost scales with what you can see.** Detail is chosen per cast from camera
	   distance and a live part budget, so a six-way brawl degrades to fewer
	   segments rather than to a frame-rate cliff.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
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

--[[ Two colours per technique and nothing else. `core` is the near-white hot
	centre, `glow` the saturated identity colour. Anything that wants a third
	tone darkens `glow` rather than inventing one, so a technique can never drift
	away from its own palette. ]]
type Palette = {
	core: Color3,
	glow: Color3,
}

type Draw = (Shot, Palette, number, number) -> ()

local RNG = Random.new()

-- Cylinder parts run along their local X, so a flat ground disc is a cylinder
-- rotated a quarter turn about Z. Every ground ring in this file uses this.
local FLAT = CFrame.Angles(0, 0, math.pi / 2)

-- Cylinder X aligned with the frame's look direction, for impact rings that face
-- back down the path a shot travelled.
local FACING = CFrame.Angles(0, math.pi / 2, 0)

local DETAIL_NONE = 0
local DETAIL_LOW = 1
local DETAIL_MID = 2
local DETAIL_FULL = 3

-- Distances, in studs, at which a cast drops a detail tier. The far cut is well
-- past Ruler's radius so a fight is still legible from across the arena.
local DETAIL_NEAR = 110
local DETAIL_MEDIUM = 260
local DETAIL_FAR = 520

--[[ Above this many live instances in the scene folder, every new cast is forced
	down to DETAIL_LOW. A ceiling rather than a queue: dropping segments off a
	cast nobody can follow anyway is always better than dropping frames. ]]
local PART_BUDGET = 300

local RULER_RADIUS = Config.Combat.ranges.ruler
local FORGER_RADIUS = Config.Combat.ranges.forger

-- Constructs damage on this interval, so they pulse on it. The tell and the tick
-- are the same number on purpose: stepping out during the pulse is the counter.
local PULSE_SECONDS = Config.Combat.constructTickSeconds

local PALETTE: { [string]: Palette } = {
	-- Striker: cold, fast, single-target.
	lance = { core = Color3.fromRGB(220, 246, 255), glow = Color3.fromRGB(60, 170, 255) },
	volley = { core = Color3.fromRGB(255, 240, 200), glow = Color3.fromRGB(255, 165, 50) },
	pierce = { core = Color3.fromRGB(255, 255, 255), glow = Color3.fromRGB(190, 90, 255) },

	-- Enforcer: worn on the body, so these read against skin and shirts.
	surge = { core = Color3.fromRGB(255, 226, 170), glow = Color3.fromRGB(255, 92, 40) },
	bulwark = { core = Color3.fromRGB(222, 240, 255), glow = Color3.fromRGB(70, 130, 255) },
	swiftstep = { core = Color3.fromRGB(226, 255, 232), glow = Color3.fromRGB(70, 235, 140) },

	-- Forger: placed, and has to stay readable for its whole duration.
	barrier = { core = Color3.fromRGB(228, 248, 255), glow = Color3.fromRGB(90, 185, 255) },
	caltrops = { core = Color3.fromRGB(255, 214, 160), glow = Color3.fromRGB(226, 88, 46) },
	sentry = { core = Color3.fromRGB(255, 246, 214), glow = Color3.fromRGB(255, 188, 66) },

	-- Ruler: terrain colours, because the terrain is what these command.
	upheaval = { core = Color3.fromRGB(255, 186, 112), glow = Color3.fromRGB(158, 92, 52) },
	siphon = { core = Color3.fromRGB(236, 206, 255), glow = Color3.fromRGB(132, 58, 216) },
	tempest = { core = Color3.fromRGB(246, 250, 255), glow = Color3.fromRGB(128, 178, 255) },
}

local FALLBACK: Palette =
	{ core = Color3.fromRGB(240, 240, 240), glow = Color3.fromRGB(150, 170, 210) }

-- A miss still has to draw, or the button reads as broken. It draws in this
-- instead of the technique's own colour, which is the whole tell.
local MISS: Palette = { core = Color3.fromRGB(206, 210, 222), glow = Color3.fromRGB(120, 124, 138) }

local ROCK = Color3.fromRGB(74, 63, 55)

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

	if level > DETAIL_LOW and #scene():GetChildren() > PART_BUDGET then
		level = DETAIL_LOW
	end
	return level
end

-- Pick a count per detail tier. Written out at every call site so the cost of a
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

local function block(size: Vector3, cf: CFrame, color: Color3, transparency: number): Part
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
	part.Material = Enum.Material.Neon
	part.Transparency = transparency
	decorate(part)
	return part
end

--[[ A disc. `pivot` already carries the axis rotation (FLAT for a ground ring,
	lookAt * FACING for one that faces a direction), because callers know which
	way their disc should point and this should not have to guess. ]]
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
	part.Material = Enum.Material.Neon
	part.Transparency = transparency
	decorate(part)
	return part
end

local function wedge(size: Vector3, cf: CFrame, color: Color3, material: Enum.Material): WedgePart
	local part = Instance.new("WedgePart")
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material
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

-- Grow and fade in one gesture, then clean up. The single most used motion in
-- the file: every shockwave, halo and bloom is this.
local function bloom(part: BasePart, seconds: number, endSize: Vector3, style: Enum.EasingStyle)
	tweenTo(part, seconds, style, { Size = endSize, Transparency = 1 })
	Debris:AddItem(part, seconds + 0.05)
end

local function fadeOut(part: BasePart, seconds: number)
	tweenTo(part, seconds, Enum.EasingStyle.Sine, { Transparency = 1 })
	Debris:AddItem(part, seconds + 0.05)
end

--[[ A short-lived light. Capped hard, because lights are the one thing here that
	costs more than its pixels: a handful is punch, a dozen is a stutter. ]]
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
	square: boolean?,
}

local function configureSpray(emitter: ParticleEmitter, config: SprayConfig)
	emitter.Color = ColorSequence.new(config.core, config.glow)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, config.sizeFrom),
		NumberSequenceKeypoint.new(0.4, (config.sizeFrom + config.sizeTo) * 0.6),
		NumberSequenceKeypoint.new(1, config.sizeTo),
	})
	-- Fading in over the first frames rather than popping is most of why a burst
	-- reads as energy instead of as a texture.
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.09, 0.05),
		NumberSequenceKeypoint.new(0.7, 0.35),
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
	emitter.LightEmission = 0.9
	emitter.LightInfluence = 0
	emitter.Enabled = true
end

local function sprayLife(config: SprayConfig): number
	local life = config.life
	return if life then life.Max else 0.5
end

-- A one-shot burst at a point in the world.
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
	the part, which means the engine moves it for free -- no per-frame work for
	anything that only has to stay with a body. ]]
local function stream(host: BasePart, offset: Vector3, config: SprayConfig): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Position = offset
	attachment.Parent = host

	local emitter = Instance.new("ParticleEmitter")
	configureSpray(emitter, config)
	emitter.Parent = attachment
	-- The Attachment is returned, not the emitter: it is the owner of everything
	-- created here, so whoever holds it can dispose of the whole thing.
	return attachment
end

-- ------------------------------------------------------------------- followers

--[[ Anchored geometry that has to move.

	Aura rings, orbiting plates and hovering cores are all anchored -- rule one is
	not negotiable -- so nothing welds and nothing is simulated. One Heartbeat
	drives every one of them from a table, and disconnects itself the moment the
	table empties, so an idle client pays nothing at all. ]]
type Follower = {
	part: BasePart,
	anchor: BasePart?,
	position: Vector3,
	offset: CFrame,
	spin: number,
	bob: number,
	born: number,
	expiresAt: number,
}

local followers: { Follower } = {}
local heartbeat: RBXScriptConnection? = nil

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
		local base = if anchor then anchor.Position else follower.position
		local lift = if follower.bob ~= 0 then math.sin(age * 2.3) * follower.bob else 0
		follower.part.CFrame = CFrame.new(base + Vector3.new(0, lift, 0))
			* CFrame.Angles(0, age * follower.spin, 0)
			* follower.offset
	end

	if #followers == 0 and heartbeat then
		heartbeat:Disconnect()
		heartbeat = nil
	end
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
	table.insert(followers, {
		part = part,
		anchor = anchor,
		position = position,
		offset = offset,
		spin = spin,
		bob = bob,
		born = os.clock(),
		expiresAt = os.clock() + duration,
	})
	if not heartbeat then
		heartbeat = RunService.Heartbeat:Connect(stepFollowers)
	end
end

-- ----------------------------------------------------------------------- shake

--[[ Camera shake, applied as an offset after the default camera has already
	written its CFrame for the frame. Never stored, so it cannot leave the camera
	somewhere strange if this errors -- next frame the camera scripts overwrite it
	and the offset simply stops being added. ]]
local SHAKE_BIND = "ClientVfxShake"
local SHAKE_CEILING = 0.75

local shakePower = 0
local shakeBound = false

local function stepShake(deltaSeconds: number)
	local camera = Workspace.CurrentCamera
	if not camera or shakePower <= 0.002 then
		shakePower = 0
		if shakeBound then
			RunService:UnbindFromRenderStep(SHAKE_BIND)
			shakeBound = false
		end
		return
	end

	local power = shakePower
	camera.CFrame = camera.CFrame
		* CFrame.new(
			RNG:NextNumber(-power, power),
			RNG:NextNumber(-power, power),
			RNG:NextNumber(-power, power) * 0.35
		)
		* CFrame.Angles(
			RNG:NextNumber(-power, power) * 0.014,
			RNG:NextNumber(-power, power) * 0.014,
			RNG:NextNumber(-power, power) * 0.03
		)

	shakePower = power * math.exp(-deltaSeconds * 7.5)
end

local function shake(amount: number)
	if amount <= 0 then
		return
	end
	shakePower = math.min(SHAKE_CEILING, math.max(shakePower, amount))
	if not shakeBound then
		shakeBound = true
		RunService:BindToRenderStep(SHAKE_BIND, Enum.RenderPriority.Camera.Value + 1, stepShake)
	end
end

--[[ Shake falls off with distance, so a Tempest across the arena is felt and a
	Tempest at your feet is felt properly. Nothing shakes for something the camera
	is too far away to see. ]]
local function shakeAt(position: Vector3, amount: number, radius: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local distance = (camera.CFrame.Position - position).Magnitude
	if distance >= radius then
		return
	end
	shake(amount * (1 - distance / radius))
end

-- ------------------------------------------------------------------- hit marker

--[[ Four ticks at screen centre when *your* shot connects.

	The world already shows an impact, but in third person the impact is where the
	enemy is, not where the eye is. This is the one piece of feedback aimed at the
	caster rather than at the scene, and it is drawn only on `hit` -- which the
	server decided, so it can never lie about a miss. ]]
local hitTicks: { Frame } = {}
local hitScale: UIScale? = nil

local function buildHitMarker()
	local player = Players.LocalPlayer
	if not player then
		return
	end
	local gui = player:FindFirstChildOfClass("PlayerGui")
	if not gui then
		return
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = "TechniqueFeedback"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 4
	screen.Parent = gui

	local holder = Instance.new("Frame")
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromOffset(48, 48)
	holder.BackgroundTransparency = 1
	holder.Parent = screen

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = holder
	hitScale = scale

	-- Four diagonal ticks, corner outward, so the shape is unmistakably a hit
	-- confirmation and not a crosshair the game does not otherwise have.
	local corners: { { at: UDim2, turn: number } } = {
		{ at = UDim2.fromScale(0.16, 0.16), turn = 45 },
		{ at = UDim2.fromScale(0.84, 0.16), turn = -45 },
		{ at = UDim2.fromScale(0.16, 0.84), turn = -45 },
		{ at = UDim2.fromScale(0.84, 0.84), turn = 45 },
	}
	for _, corner in corners do
		local tick = Instance.new("Frame")
		tick.AnchorPoint = Vector2.new(0.5, 0.5)
		tick.Position = corner.at
		tick.Size = UDim2.fromOffset(3, 13)
		tick.Rotation = corner.turn
		tick.BorderSizePixel = 0
		tick.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		tick.BackgroundTransparency = 1
		tick.Parent = holder
		table.insert(hitTicks, tick)
	end
end

local function markHit(palette: Palette)
	if #hitTicks == 0 then
		buildHitMarker()
	end
	local scale = hitScale
	if scale then
		scale.Scale = 0.62
		tweenTo(scale, 0.22, Enum.EasingStyle.Back, { Scale = 1.15 })
	end
	for _, tick in hitTicks do
		tick.BackgroundColor3 = palette.core
		tick.BackgroundTransparency = 0
		tweenTo(tick, 0.26, Enum.EasingStyle.Quad, { BackgroundTransparency = 1 })
	end
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

--[[ Where the floor is under a point.

	Ground effects that guess at the floor read as broken the first time anyone
	casts on a slope, and node spawn heights are already a known open question, so
	this asks. Characters and this folder are excluded; every part here is
	CanQuery=false anyway, but excluding the folder keeps that true even if a
	future part is added carelessly. ]]
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

-- A direction, guaranteed unit and never zero.
local function aim(from: Vector3, to: Vector3): Vector3
	local delta = to - from
	if delta.Magnitude < 1e-3 then
		return Vector3.new(0, 0, -1)
	end
	return delta.Unit
end

-- Horizontal right-hand vector for a direction, so muzzles can sit beside the
-- body instead of inside the chest.
local function sideways(direction: Vector3): Vector3
	local flat = Vector3.new(direction.Z, 0, -direction.X)
	if flat.Magnitude < 1e-3 then
		return Vector3.new(1, 0, 0)
	end
	return flat.Unit
end

--[[ A frame looking from one point at another.

	`CFrame.lookAt` produces NaN when the direction it is given is parallel to its
	up vector, and a part assigned a NaN CFrame does not draw at all. Tempest's
	bolts fall almost straight down, so every oriented part in this file is built
	through here and picks a different up when the direction is near vertical. ]]
local function look(from: Vector3, to: Vector3): CFrame
	local direction = aim(from, to)
	local up = if math.abs(direction.Y) > 0.995 then Vector3.new(0, 0, 1) else Vector3.new(0, 1, 0)
	return CFrame.lookAt(from, to, up)
end

-- ------------------------------------------------------------- shared motifs

--[[ A crisp ring, built from segments because the engine has no torus and an
	expanding filled disc reads as a wash rather than as an edge. Reserved for the
	moments that want a hard edge: placements, activations, ground waves. ]]
local function segmentRing(
	centre: Vector3,
	radius: number,
	segments: number,
	thickness: number,
	palette: Palette,
	seconds: number,
	growTo: number
)
	if segments <= 0 then
		return
	end
	local span = (2 * math.pi * radius) / segments
	for index = 1, segments do
		local angle = (index / segments) * math.pi * 2
		local offset = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		local part = block(
			Vector3.new(span * 0.82, thickness, thickness),
			CFrame.new(centre + offset) * CFrame.Angles(0, -angle, 0),
			palette.core,
			0.1
		)
		local target = centre + offset.Unit * (radius * growTo)
		tweenTo(part, seconds, Enum.EasingStyle.Quint, {
			CFrame = CFrame.new(target) * CFrame.Angles(0, -angle, 0),
			Size = Vector3.new(span * growTo, thickness * 0.4, thickness * 0.4),
			Transparency = 1,
			Color = palette.glow,
		})
		Debris:AddItem(part, seconds + 0.05)
	end
end

-- The flat expanding wash. One part, so this is what carries scale when the
-- budget is tight.
local function groundWave(
	centre: Vector3,
	fromDiameter: number,
	toDiameter: number,
	palette: Palette,
	seconds: number
)
	-- Lifted clear of the floor here rather than at every call site, because a
	-- disc centred exactly on the ground z-fights with it along its whole radius.
	local at = centre + Vector3.new(0, 0.25, 0)
	local part = disc(CFrame.new(at) * FLAT, fromDiameter, 0.6, palette.core, 0.35)
	tweenTo(part, seconds, Enum.EasingStyle.Quint, {
		Size = Vector3.new(0.2, toDiameter, toDiameter),
		Transparency = 1,
		Color = palette.glow,
	})
	Debris:AddItem(part, seconds + 0.05)
end

--[[ Where a striker shot ends.

	`connected` is the whole point of this function. A hit blooms white, throws
	shards back along the surface and kicks the camera; a miss puffs grey and does
	none of it. Told apart at a glance, in a single frame, at any distance. ]]
local function impact(
	position: Vector3,
	direction: Vector3,
	palette: Palette,
	scale: number,
	connected: boolean,
	level: number
)
	local shown = if connected then palette else MISS
	local facing = look(position, position + direction)

	-- The ring faces back down the path, which is what makes an impact read as an
	-- impact rather than as a puff that happened to be there.
	local ring = disc(facing * FACING, 2 * scale, 0.5, shown.core, 0.2)
	bloom(
		ring,
		if connected then 0.28 else 0.2,
		Vector3.new(0.15, 13 * scale, 13 * scale),
		Enum.EasingStyle.Quint
	)

	if connected then
		local flash = ball(position, 1.5 * scale, palette.core, 0.05)
		bloom(flash, 0.18, Vector3.one * 8 * scale, Enum.EasingStyle.Quad)
	end

	spray(position, tier(level, 8, 16, 26) * scale, {
		core = shown.core,
		glow = shown.glow,
		sizeFrom = 0.5 * scale,
		sizeTo = 0,
		speed = NumberRange.new(18 * scale, 46 * scale),
		life = NumberRange.new(0.18, 0.42),
		spread = 180,
		acceleration = Vector3.new(0, if connected then -30 else -60, 0),
	})

	if connected and level >= DETAIL_MID then
		flare(position, palette.glow, 7, 22 * scale)
	end

	-- Shards fly back along the surface -- the readable difference between "it
	-- hit something" and "it stopped somewhere".
	if connected and level >= DETAIL_FULL then
		for _ = 1, 5 do
			local scatter =
				Vector3.new(RNG:NextNumber(-1, 1), RNG:NextNumber(-0.2, 1), RNG:NextNumber(-1, 1))
			local away = (-direction * 1.6 + scatter).Unit
			local shard = block(
				Vector3.new(0.28, 0.28, RNG:NextNumber(1.6, 3.4) * scale),
				look(position, position + away),
				palette.core,
				0.1
			)
			local landing = position + away * RNG:NextNumber(6, 12) * scale
			tweenTo(shard, 0.3, Enum.EasingStyle.Quad, {
				CFrame = look(landing, landing + away) * CFrame.Angles(0, 0, 3),
				Size = Vector3.new(0.05, 0.05, 0.6),
				Transparency = 1,
			})
			Debris:AddItem(shard, 0.36)
		end
	end

	if connected then
		shakeAt(position, 0.16 * scale, 90)
	end
end

-- The discharge at the caster's end. Cheap, and it is what stops a bolt from
-- looking like it teleported into existence.
local function muzzle(position: Vector3, direction: Vector3, palette: Palette, scale: number)
	local cone = disc(look(position, position + direction) * FACING, 1, 0.4, palette.core, 0.2)
	bloom(cone, 0.16, Vector3.new(0.1, 7 * scale, 7 * scale), Enum.EasingStyle.Quad)

	spray(position, math.floor(10 * scale), {
		core = palette.core,
		glow = palette.glow,
		sizeFrom = 0.45 * scale,
		sizeTo = 0,
		speed = NumberRange.new(10, 26),
		life = NumberRange.new(0.12, 0.28),
		spread = 45,
		acceleration = direction * 30,
		drag = 6,
	})
end

--[[ A travelling bolt: hot core, soft shell, ribbon behind.

	The Trail is the important part. Roblox draws a bolt at a discrete position
	each frame, and at these speeds that is a dotted line; the ribbon is what
	makes the eye read one continuous streak. ]]
local function bolt(
	from: Vector3,
	to: Vector3,
	palette: Palette,
	width: number,
	length: number,
	seconds: number,
	level: number
)
	local direction = aim(from, to)
	local start = look(from, to)
	local finish = look(to, to + direction)

	local core = block(Vector3.new(width, width, length), start, palette.core, 0)
	tweenTo(core, seconds, Enum.EasingStyle.Linear, { CFrame = finish })
	Debris:AddItem(core, seconds + 0.08)

	local shell =
		block(Vector3.new(width * 2.8, width * 2.8, length * 1.4), start, palette.glow, 0.5)
	tweenTo(shell, seconds, Enum.EasingStyle.Linear, { CFrame = finish, Transparency = 0.9 })
	Debris:AddItem(shell, seconds + 0.08)

	if level >= DETAIL_MID then
		local back = Instance.new("Attachment")
		back.Position = Vector3.new(-width * 1.6, 0, length * 0.4)
		back.Parent = core

		local front = Instance.new("Attachment")
		front.Position = Vector3.new(width * 1.6, 0, length * 0.4)
		front.Parent = core

		local trail = Instance.new("Trail")
		trail.Attachment0 = back
		trail.Attachment1 = front
		trail.Lifetime = 0.16
		trail.MinLength = 0
		trail.FaceCamera = true
		trail.LightEmission = 1
		trail.LightInfluence = 0
		trail.Color = ColorSequence.new(palette.core, palette.glow)
		trail.Transparency = NumberSequence.new(0.15, 1)
		trail.WidthScale = NumberSequence.new(1, 0)
		trail.Parent = core
	end
end

-- ---------------------------------------------------------------- striker: 3

--[[ Lance. One spear, one target, gone in a tenth of a second.

	The cheapest technique in the game costs the least to draw, which is not a
	coincidence -- at 1.2s cooldown this is the button that will be pressed most,
	so it has to stay clean at six casters on screen. ]]
local function drawLance(shot: Shot, palette: Palette, _duration: number, level: number)
	local target = shot.target
	if not target then
		return
	end

	local direction = aim(shot.origin, target)
	local from = shot.origin + sideways(direction) * 1.3 - Vector3.new(0, 0.2, 0)
	local travel = math.clamp((target - from).Magnitude / 640, 0.04, 0.16)

	muzzle(from, direction, palette, 1)
	bolt(from, target, palette, 0.55, 7, travel, level)

	task.delay(travel, function()
		impact(target, direction, palette, 1, shot.hit, level)
		if shot.hit and isLocalCaster(shot) then
			markHit(palette)
		end
	end)
end

--[[ Volley. Five bolts in a fan, staggered, converging.

	The identity is the *count*: a frame of Volley has several bright streaks in
	it where Lance has exactly one, and that difference survives being shrunk to a
	thumbnail. The stagger is what makes it read as a burst rather than as one
	thick bolt. ]]
local function drawVolley(shot: Shot, palette: Palette, _duration: number, level: number)
	local target = shot.target
	if not target then
		return
	end

	local direction = aim(shot.origin, target)
	local right = sideways(direction)
	local up = right:Cross(direction)
	local from = shot.origin + right * 1.1
	local count = tier(level, 2, 3, 5)
	local travel = math.clamp((target - from).Magnitude / 700, 0.04, 0.14)

	muzzle(from, direction, palette, 1.3)

	for index = 1, count do
		-- Spread evenly about the centre line so the fan is symmetric no matter
		-- how many bolts the detail tier allows.
		local lateral = ((index - 1) / math.max(1, count - 1)) * 2 - 1
		local launch = from + right * (lateral * 3.2) + up * (RNG:NextNumber(-1.2, 1.6))
		local landing = target + right * (lateral * 1.6) + up * RNG:NextNumber(-1.4, 1.4)
		local delay = (index - 1) * 0.045

		task.delay(delay, function()
			bolt(launch, landing, palette, 0.34, 4.5, travel, level)
			task.delay(travel, function()
				impact(landing, direction, palette, 0.55, shot.hit, level - 1)
			end)
		end)
	end

	-- One full-weight impact under the scatter, so the burst still lands as a
	-- single event rather than as five small ones.
	task.delay(travel + (count - 1) * 0.045, function()
		impact(target, direction, palette, 1.1, shot.hit, level)
		if shot.hit and isLocalCaster(shot) then
			markHit(palette)
		end
	end)
end

--[[ Pierce. A beam, instant, the length of the arena.

	Three times Lance's damage on a five second cooldown, so it gets the frame to
	itself: the beam snaps to full length in one frame and holds, halos peel off
	along its length, and the caster's camera takes the recoil. Nothing else in
	the striker set spans the whole screen. ]]
local function drawPierce(shot: Shot, palette: Palette, _duration: number, level: number)
	local target = shot.target
	if not target then
		return
	end

	local direction = aim(shot.origin, target)
	local from = shot.origin + sideways(direction) * 0.9
	local length = (target - from).Magnitude
	local midpoint = from:Lerp(target, 0.5)
	local axis = look(midpoint, target)

	local core = block(Vector3.new(1.1, 1.1, length), axis, palette.core, 0)
	tweenTo(core, 0.3, Enum.EasingStyle.Quart, {
		Size = Vector3.new(0.05, 0.05, length),
		Transparency = 1,
	})
	Debris:AddItem(core, 0.36)

	local shell = block(Vector3.new(3.2, 3.2, length), axis, palette.glow, 0.45)
	tweenTo(shell, 0.42, Enum.EasingStyle.Quint, {
		Size = Vector3.new(7, 7, length),
		Transparency = 1,
	})
	Debris:AddItem(shell, 0.48)

	-- Halos peel off along the path, which is what gives a static beam direction.
	local halos = tier(level, 1, 2, 4)
	for index = 1, halos do
		local at = from:Lerp(target, index / (halos + 1))
		local halo = disc(look(at, at + direction) * FACING, 3, 0.4, palette.core, 0.25)
		bloom(halo, 0.34, Vector3.new(0.1, 15, 15), Enum.EasingStyle.Quint)
	end

	muzzle(from, direction, palette, 2.2)
	spray(from, tier(level, 6, 14, 22), {
		core = palette.core,
		glow = palette.glow,
		sizeFrom = 0.8,
		sizeTo = 0,
		speed = NumberRange.new(6, 20),
		life = NumberRange.new(0.2, 0.45),
		spread = 120,
		acceleration = -direction * 24,
	})

	impact(target, direction, palette, 1.8, shot.hit, level)
	-- The spray keeps going past the target, so it reads as having gone through.
	if shot.hit then
		spray(target + direction * 3, tier(level, 4, 10, 18), {
			core = palette.core,
			glow = palette.glow,
			sizeFrom = 0.7,
			sizeTo = 0,
			speed = NumberRange.new(24, 60),
			life = NumberRange.new(0.2, 0.5),
			spread = 28,
			acceleration = direction * 20,
		})
	end

	if isLocalCaster(shot) then
		shake(0.32)
		if shot.hit then
			markHit(palette)
		end
	end
end

-- --------------------------------------------------------------- enforcer: 3

--[[ Enforcer auras.

	A self-buff that nobody else can see is a stat change, not a technique. Every
	one of these three has to answer, from across the arena and for its whole
	duration, "that player is currently dangerous" -- and answer *which* buff, so
	an opponent can decide whether to trade or to wait it out.

	One aura per caster: recasting replaces rather than stacks, so a buff window
	is never ambiguous. Emitters and lights hang off the root and ride it for
	free; only the rings and plates need the follower loop. ]]
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
			-- Stop emitting but let the particles already in the air live out
			-- their lifetime; Debris takes the attachment afterwards.
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

-- The body glow every enforcer buff shares, coloured per technique. Occluded so
-- it does not shine through walls and give away a position it should not.
local function auraBody(aura: Aura, root: BasePart, palette: Palette, fill: number)
	local character = root.Parent
	if character then
		local highlight = Instance.new("Highlight")
		highlight.Adornee = character
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.FillColor = palette.glow
		highlight.FillTransparency = fill
		highlight.OutlineColor = palette.core
		highlight.OutlineTransparency = 0.1
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

-- The moment of activation, shared by all three: a ring off the feet and a
-- column up the body. Colour and speed are what tell them apart.
local function auraOnset(centre: Vector3, palette: Palette, level: number, tall: number)
	local floor = groundY(centre, centre.Y - 3)
	local base = Vector3.new(centre.X, floor + 0.2, centre.Z)

	groundWave(base, 4, 26, palette, 0.4)
	segmentRing(base, 3, tier(level, 0, 8, 14), 0.7, palette, 0.45, 4.5)

	local column = block(
		Vector3.new(3.4, tall, 3.4),
		CFrame.new(base + Vector3.new(0, tall * 0.5, 0)),
		palette.core,
		0.35
	)
	bloom(column, 0.32, Vector3.new(0.4, tall * 1.3, 0.4), Enum.EasingStyle.Quint)

	spray(base + Vector3.new(0, 1.5, 0), tier(level, 8, 18, 30), {
		core = palette.core,
		glow = palette.glow,
		sizeFrom = 0.9,
		sizeTo = 0,
		speed = NumberRange.new(10, 26),
		life = NumberRange.new(0.3, 0.6),
		spread = 30,
		acceleration = Vector3.new(0, 14, 0),
		drag = 2,
	})
	flare(base + Vector3.new(0, 3, 0), palette.glow, 6, 26)
end

--[[ Surge. Damage up, so it burns.

	Fire climbing the body, two fast counter-rotating rings, an orange cast over
	the character. The aggressive one, and it looks it. ]]
local function drawSurge(shot: Shot, palette: Palette, duration: number, level: number)
	auraOnset(shot.origin, palette, level, 9)
	shakeAt(shot.origin, 0.12, 40)

	local root = rootOf(shot.casterId)
	if not root then
		return
	end
	local aura = openAura(shot.casterId, duration)
	auraBody(aura, root, palette, 0.78)

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
			rate = tier(level, 8, 22, 46),
		})
	)

	if level < DETAIL_MID then
		return
	end

	-- Two rings turning against each other. Counter-rotation is the tell that
	-- separates Surge from Swiftstep's single fast ring at a glance.
	for index = 1, 2 do
		local ring =
			disc(CFrame.new(root.Position) * FLAT, 7 - index * 1.6, 0.35, palette.glow, 0.4)
		follow(
			ring,
			root,
			root.Position,
			CFrame.new(0, -2.4 + index * 2.1, 0) * FLAT,
			if index == 1 then 5.5 else -4.2,
			0,
			duration + 0.4
		)
		table.insert(aura.pieces, ring)
	end
end

--[[ Bulwark. Mitigation up, so it armours.

	Four plates orbiting the body -- deliberately *not* a dome, because Barrier is
	a dome and these two must never be confused: 40% mitigation for six seconds
	and 55% for eight are different decisions to fight into. ]]
local function drawBulwark(shot: Shot, palette: Palette, duration: number, level: number)
	auraOnset(shot.origin, palette, level, 7)

	local root = rootOf(shot.casterId)
	if not root then
		return
	end
	local aura = openAura(shot.casterId, duration)
	auraBody(aura, root, palette, 0.84)

	local plates = tier(level, 2, 3, 4)
	for index = 1, plates do
		local angle = (index / plates) * math.pi * 2
		local plate =
			block(Vector3.new(3.6, 4.4, 0.32), CFrame.new(root.Position), palette.glow, 0.35)
		plate.Material = Enum.Material.ForceField
		-- Slammed in from outside, so the guard *closes* rather than appearing.
		plate.Size = Vector3.new(5.4, 6.6, 0.32)
		tweenTo(plate, 0.28, Enum.EasingStyle.Back, { Size = Vector3.new(3.6, 4.4, 0.32) })
		follow(
			plate,
			root,
			root.Position,
			CFrame.Angles(0, angle, 0) * CFrame.new(0, 0.2, -3.6),
			1.5,
			0.25,
			duration + 0.4
		)
		table.insert(aura.pieces, plate)
	end

	local ring = disc(CFrame.new(root.Position) * FLAT, 8, 0.4, palette.core, 0.45)
	follow(ring, root, root.Position, CFrame.new(0, -2.7, 0) * FLAT, 1.1, 0, duration + 0.4)
	table.insert(aura.pieces, ring)
end

--[[ Swiftstep. The cheap one, so it stays light.

	No shell, no plates: a low fast ring and a ribbon off the hips, which only
	shows while the player is actually moving. Cheapest to cast and cheapest to
	draw, and the only aura whose visual intensity depends on what the player
	does with it. ]]
local function drawSwiftstep(shot: Shot, palette: Palette, duration: number, level: number)
	auraOnset(shot.origin, palette, level, 6)

	local root = rootOf(shot.casterId)
	if not root then
		return
	end
	local aura = openAura(shot.casterId, duration)
	auraBody(aura, root, palette, 0.88)

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
	trail.Lifetime = 0.42
	trail.MinLength = 0.2
	trail.FaceCamera = true
	trail.LightEmission = 1
	trail.LightInfluence = 0
	trail.Color = ColorSequence.new(palette.core, palette.glow)
	trail.Transparency = NumberSequence.new(0.25, 1)
	trail.WidthScale = NumberSequence.new(1, 0)
	trail.Parent = root
	table.insert(aura.pieces, trail)

	table.insert(
		aura.pieces,
		stream(root, Vector3.new(0, -2.4, 0), {
			core = palette.core,
			glow = palette.glow,
			sizeFrom = 0.5,
			sizeTo = 0,
			speed = NumberRange.new(3, 9),
			life = NumberRange.new(0.2, 0.4),
			spread = 180,
			acceleration = Vector3.new(0, -6, 0),
			rate = tier(level, 5, 12, 22),
		})
	)

	local ring = disc(CFrame.new(root.Position) * FLAT, 6.4, 0.3, palette.glow, 0.35)
	follow(ring, root, root.Position, CFrame.new(0, -2.8, 0) * FLAT, 9, 0, duration + 0.4)
	table.insert(aura.pieces, ring)
end

-- ----------------------------------------------------------------- forger: 3

--[[ Barrier. A dome, slammed down.

	The placement moment is the point: 40 madra on a 12 second cooldown for 55%
	mitigation is a commitment, so it arrives from above and lands hard rather
	than fading in. ForceField material carries the hex read for free, and it is
	the only dome in the game. ]]
local function drawBarrier(shot: Shot, palette: Palette, duration: number, level: number)
	local floor = groundY(shot.origin, shot.origin.Y - 3)
	local base = Vector3.new(shot.origin.X, floor + 0.1, shot.origin.Z)

	groundWave(base, 6, 34, palette, 0.45)
	segmentRing(base, 6, tier(level, 6, 10, 18), 0.8, palette, 0.5, 1.9)
	flare(base + Vector3.new(0, 4, 0), palette.glow, 8, 34)
	shakeAt(base, 0.2, 60)

	local root = rootOf(shot.casterId)
	local anchorPosition = if root then root.Position else shot.origin

	local dome = ball(anchorPosition, 26, palette.glow, 0.55)
	dome.Material = Enum.Material.ForceField
	tweenTo(dome, 0.26, Enum.EasingStyle.Back, { Size = Vector3.one * 13, Transparency = 0.72 })
	follow(dome, root, anchorPosition, CFrame.new(0, 0.6, 0), 0.35, 0, duration + 0.4)

	-- A second, tighter shell shimmering out of phase with the first reads as a
	-- surface with depth rather than as a tinted balloon.
	if level >= DETAIL_MID then
		local inner = ball(anchorPosition, 10.4, palette.core, 0.88)
		inner.Material = Enum.Material.ForceField
		TweenService:Create(
			inner,
			TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Transparency = 0.7 }
		):Play()
		follow(inner, root, anchorPosition, CFrame.new(0, 0.6, 0), -0.6, 0, duration + 0.4)
		task.delay(duration, function()
			fadeOut(inner, 0.35)
		end)
	end

	local skirt = disc(CFrame.new(base) * FLAT, 14, 0.5, palette.core, 0.4)
	follow(skirt, root, anchorPosition, CFrame.new(0, -2.9, 0) * FLAT, 1.4, 0, duration + 0.4)

	task.delay(duration, function()
		fadeOut(dome, 0.35)
		fadeOut(skirt, 0.35)
	end)
end

--[[ Caltrops. Spikes thrown out and planted.

	The server drops one flat translucent cylinder for the damage volume; this is
	what makes that volume mean something. Spikes land in a scatter across the
	whole radius so the hazard's *edge* is visible -- a zoning tool you cannot see
	the boundary of is just unfair damage. ]]
local function drawCaltrops(shot: Shot, palette: Palette, duration: number, level: number)
	local floor = groundY(shot.origin, shot.origin.Y - 3)
	local centre = Vector3.new(shot.origin.X, floor, shot.origin.Z)

	groundWave(centre, 4, FORGER_RADIUS * 2, palette, 0.4)
	shakeAt(centre, 0.14, 50)

	local count = tier(level, 4, 8, 13)
	for index = 1, count do
		local angle = RNG:NextNumber(0, math.pi * 2)
		-- Square-rooted radius, so the scatter is even by area instead of
		-- clustering at the middle.
		local radius = math.sqrt(RNG:NextNumber(0.08, 1)) * (FORGER_RADIUS - 1.5)
		local at = centre + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		local height = RNG:NextNumber(2.6, 4.2)
		local tilt = CFrame.Angles(
			RNG:NextNumber(-0.24, 0.24),
			RNG:NextNumber(0, math.pi * 2),
			RNG:NextNumber(-0.24, 0.24)
		)

		local spike = wedge(
			Vector3.new(0.55, height, 1.1),
			CFrame.new(at + Vector3.new(0, height * 1.6, 0)) * tilt,
			palette.glow,
			Enum.Material.Neon
		)
		spike.Transparency = 0.15

		local planted = CFrame.new(at + Vector3.new(0, height * 0.44, 0)) * tilt
		task.delay(index * 0.022, function()
			if not spike.Parent then
				return
			end
			-- Thrown, not grown: they arrive fast and stop dead.
			tweenTo(spike, 0.14, Enum.EasingStyle.Quart, { CFrame = planted })
			task.delay(0.14, function()
				if not spike.Parent then
					return
				end
				spray(at, tier(level, 3, 5, 8), {
					core = palette.core,
					glow = palette.glow,
					sizeFrom = 0.7,
					sizeTo = 0,
					speed = NumberRange.new(4, 12),
					life = NumberRange.new(0.16, 0.34),
					spread = 90,
					acceleration = Vector3.new(0, -20, 0),
				})
			end)
		end)

		tweenTo(spike, duration, Enum.EasingStyle.Linear, { Color = palette.core })
		task.delay(duration, function()
			if spike.Parent then
				tweenTo(spike, 0.4, Enum.EasingStyle.Quad, {
					CFrame = CFrame.new(at - Vector3.new(0, height, 0)) * tilt,
					Transparency = 1,
				})
			end
		end)
		Debris:AddItem(spike, duration + 0.5)
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
			groundWave(centre, 2, FORGER_RADIUS * 2, palette, 0.55)
		end
	end)
end

--[[ Sentry. A core assembled in the air.

	The most expensive Forger technique (55 madra, 16s cooldown) and the only one
	with a silhouette above knee height, which is what makes it worth walking
	around: you can see a Sentry from outside its radius. Plates converge, the
	core snaps on, and a scan sweeps the ground on every damage tick. ]]
local function drawSentry(shot: Shot, palette: Palette, duration: number, level: number)
	local floor = groundY(shot.origin, shot.origin.Y - 3)
	local centre = Vector3.new(shot.origin.X, floor, shot.origin.Z)
	local eye = centre + Vector3.new(0, 7, 0)

	groundWave(centre, 3, FORGER_RADIUS * 1.6, palette, 0.45)
	segmentRing(centre, FORGER_RADIUS * 0.5, tier(level, 0, 10, 16), 0.6, palette, 0.5, 2)

	-- Plates fly in and converge, which is the placement moment: it is being
	-- built, not switched on.
	local plates = tier(level, 3, 4, 6)
	for index = 1, plates do
		local angle = (index / plates) * math.pi * 2
		local away = Vector3.new(math.cos(angle) * 11, RNG:NextNumber(1, 5), math.sin(angle) * 11)
		local plate = block(
			Vector3.new(2.2, 0.35, 2.2),
			CFrame.new(eye + away) * CFrame.Angles(RNG:NextNumber(0, 3), angle, 0),
			palette.glow,
			0.3
		)
		tweenTo(plate, 0.3, Enum.EasingStyle.Quint, {
			CFrame = CFrame.new(eye) * CFrame.Angles(0, angle, 0),
			Size = Vector3.new(0.6, 0.2, 0.6),
			Transparency = 1,
		})
		Debris:AddItem(plate, 0.38)
	end

	task.delay(0.3, function()
		flare(eye, palette.glow, 9, 30)
		spray(eye, tier(level, 6, 14, 24), {
			core = palette.core,
			glow = palette.glow,
			sizeFrom = 0.8,
			sizeTo = 0,
			speed = NumberRange.new(12, 30),
			life = NumberRange.new(0.2, 0.45),
			spread = 180,
			acceleration = Vector3.new(0, -10, 0),
		})

		local core = ball(eye, 0.4, palette.core, 0)
		tweenTo(core, 0.18, Enum.EasingStyle.Back, { Size = Vector3.one * 2.6 })
		follow(core, nil, eye, CFrame.identity, 2.4, 0.5, duration - 0.3)

		local shell = ball(eye, 4.6, palette.glow, 0.6)
		shell.Material = Enum.Material.ForceField
		follow(shell, nil, eye, CFrame.identity, -1.6, 0.5, duration - 0.3)

		-- Ring on its side, orbiting: the silhouette that says "this is a device".
		local orbit = disc(CFrame.new(eye), 8, 0.3, palette.core, 0.4)
		follow(orbit, nil, eye, CFrame.Angles(0.5, 0, 0), 3.2, 0.5, duration - 0.3)

		local light = Instance.new("PointLight")
		light.Color = palette.glow
		light.Brightness = 3
		light.Range = 24
		light.Shadows = false
		light.Parent = core

		-- The shaft ties the floating core to the ground it is guarding.
		local shaft = block(
			Vector3.new(1.6, 7, 1.6),
			CFrame.new(centre + Vector3.new(0, 3.5, 0)),
			palette.glow,
			0.86
		)

		task.delay(duration - 0.3, function()
			fadeOut(core, 0.3)
			fadeOut(shell, 0.3)
			fadeOut(orbit, 0.3)
			fadeOut(shaft, 0.3)
		end)
		Debris:AddItem(shaft, duration)
	end)

	task.spawn(function()
		local finish = os.clock() + duration - 0.2
		while os.clock() < finish do
			task.wait(PULSE_SECONDS)
			if os.clock() >= finish then
				break
			end
			groundWave(centre, 2, FORGER_RADIUS * 2, palette, 0.5)
			local drop = block(
				Vector3.new(0.7, 0.7, 6),
				CFrame.new(eye - Vector3.new(0, 3, 0)) * CFrame.Angles(math.pi / 2, 0, 0),
				palette.core,
				0.2
			)
			bloom(drop, 0.22, Vector3.new(0.1, 0.1, 7), Enum.EasingStyle.Quad)
		end
	end)
end

-- ------------------------------------------------------------------ ruler: 3

--[[ Ruler techniques command terrain across a 42 stud radius and are the most
	expensive things a player can spend madra on. They are supposed to be the
	heaviest thing in the game, and the budget for them is spent accordingly:
	they are the only casts that move the ground, throw real geometry, or shake
	the camera hard. All three fill the same circle, so they are told apart by
	direction of motion -- out, in, up. ]]

--[[ Upheaval. The ground comes up.

	Slabs punched out of the floor in a ring, fissures racing out from the
	caster, dust. Reads as *outward and upward* in one frame. ]]
local function drawUpheaval(shot: Shot, palette: Palette, _duration: number, level: number)
	local floor = groundY(shot.origin, shot.origin.Y - 3)
	local centre = Vector3.new(shot.origin.X, floor, shot.origin.Z)

	shakeAt(centre, 0.62, 190)
	flare(centre + Vector3.new(0, 2, 0), palette.core, 8, 50)

	-- Fissures first, so the eye is already at the edge of the radius when the
	-- slabs arrive.
	local cracks = tier(level, 3, 5, 8)
	for index = 1, cracks do
		local angle = (index / cracks) * math.pi * 2 + RNG:NextNumber(-0.2, 0.2)
		local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local crack = block(
			Vector3.new(1.6, 0.4, 4),
			look(centre + Vector3.new(0, 0.15, 0), centre + direction),
			palette.core,
			0.1
		)
		local reach = centre + direction * (RULER_RADIUS * 0.5) + Vector3.new(0, 0.15, 0)
		tweenTo(crack, 0.5, Enum.EasingStyle.Quint, {
			CFrame = look(reach, reach + direction),
			Size = Vector3.new(0.5, 0.4, RULER_RADIUS),
			Transparency = 1,
			Color = palette.glow,
		})
		Debris:AddItem(crack, 0.56)
	end

	groundWave(centre, 6, RULER_RADIUS * 2, palette, 0.6)
	segmentRing(centre, RULER_RADIUS * 0.35, tier(level, 0, 12, 20), 1.2, palette, 0.6, 2.7)

	local slabs = tier(level, 5, 9, 15)
	for _ = 1, slabs do
		local angle = RNG:NextNumber(0, math.pi * 2)
		local radius = math.sqrt(RNG:NextNumber(0.05, 1)) * (RULER_RADIUS - 3)
		local at = centre + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		local width = RNG:NextNumber(4, 9)
		local height = RNG:NextNumber(7, 15)
		local tilt = CFrame.Angles(
			RNG:NextNumber(-0.3, 0.3),
			RNG:NextNumber(0, math.pi * 2),
			RNG:NextNumber(-0.3, 0.3)
		)

		local slab = block(
			Vector3.new(width, height, width * 0.8),
			CFrame.new(at - Vector3.new(0, height, 0)) * tilt,
			ROCK,
			0
		)
		slab.Material = Enum.Material.Slate

		-- Farther slabs erupt later, so the wave visibly travels outward instead
		-- of the whole field popping at once.
		local delay = (radius / RULER_RADIUS) * 0.22
		local risen = CFrame.new(at + Vector3.new(0, height * RNG:NextNumber(0.16, 0.4), 0)) * tilt

		task.delay(delay, function()
			if not slab.Parent then
				return
			end
			tweenTo(slab, 0.14, Enum.EasingStyle.Back, { CFrame = risen })
			spray(at, tier(level, 4, 8, 14), {
				core = palette.core,
				glow = palette.glow,
				sizeFrom = 1.6,
				sizeTo = 4.5,
				speed = NumberRange.new(8, 22),
				life = NumberRange.new(0.35, 0.8),
				spread = 60,
				acceleration = Vector3.new(0, -14, 0),
				drag = 2.5,
			})
			-- Magma in the seam it tore open.
			if level >= DETAIL_MID then
				local seam = disc(
					CFrame.new(at + Vector3.new(0, 0.2, 0)) * FLAT,
					width * 1.5,
					0.4,
					palette.core,
					0.3
				)
				bloom(seam, 0.9, Vector3.new(0.2, width * 2.2, width * 2.2), Enum.EasingStyle.Sine)
			end
		end)

		-- Held, then sunk. The settle is what gives the cast weight on the way
		-- out as well as on the way in.
		task.delay(delay + 0.7, function()
			if slab.Parent then
				tweenTo(slab, 0.8, Enum.EasingStyle.Quad, {
					CFrame = CFrame.new(at - Vector3.new(0, height, 0)) * tilt,
					Transparency = 1,
				})
			end
		end)
		Debris:AddItem(slab, delay + 1.6)
	end

	-- One big dust column over the middle, on top of the per-slab dust.
	spray(centre + Vector3.new(0, 2, 0), tier(level, 12, 26, 46), {
		core = palette.core,
		glow = palette.glow,
		sizeFrom = 3,
		sizeTo = 9,
		speed = NumberRange.new(14, 40),
		life = NumberRange.new(0.5, 1.1),
		spread = 180,
		acceleration = Vector3.new(0, -8, 0),
		drag = 2,
	})
end

--[[ Siphon. Everything comes in.

	Streaks from the rim converging on the caster, a ring closing rather than
	opening, and a bright swallow at the centre. Reads as *inward* -- the exact
	inverse of Upheaval, which is how the two stay distinguishable at the same
	radius and the same duration. ]]
local function drawSiphon(shot: Shot, palette: Palette, _duration: number, level: number)
	local floor = groundY(shot.origin, shot.origin.Y - 3)
	local centre = Vector3.new(shot.origin.X, floor, shot.origin.Z)
	local heart = shot.origin

	-- A stain over the whole radius, so the area of effect is stated even though
	-- the motion is all in the middle.
	local stain =
		disc(CFrame.new(centre + Vector3.new(0, 0.1, 0)) * FLAT, 4, 0.4, palette.glow, 0.55)
	tweenTo(stain, 0.28, Enum.EasingStyle.Quart, {
		Size = Vector3.new(0.4, RULER_RADIUS * 2, RULER_RADIUS * 2),
	})
	fadeOut(stain, 0.9)

	local streaks = tier(level, 6, 12, 20)
	for index = 1, streaks do
		local angle = (index / streaks) * math.pi * 2 + RNG:NextNumber(-0.25, 0.25)
		local rim = centre
			+ Vector3.new(math.cos(angle), 0, math.sin(angle)) * RULER_RADIUS
			+ Vector3.new(0, RNG:NextNumber(0.5, 13), 0)
		local streak =
			block(Vector3.new(0.4, 0.4, RNG:NextNumber(5, 11)), look(rim, heart), palette.core, 0.1)
		task.delay(index * 0.012, function()
			if not streak.Parent then
				return
			end
			tweenTo(streak, 0.34, Enum.EasingStyle.Quart, {
				CFrame = look(heart, heart + aim(rim, heart)),
				Size = Vector3.new(0.15, 0.15, 2),
				Transparency = 0.6,
				Color = palette.glow,
			})
		end)
		Debris:AddItem(streak, 0.5)
	end

	-- The closing ring: the one motion in the game that runs inward.
	segmentRing(centre, RULER_RADIUS, tier(level, 8, 14, 22), 1, palette, 0.42, 0.12)

	-- A short vortex column, three discs shrinking as they climb.
	for index = 1, tier(level, 1, 2, 3) do
		local column = disc(
			CFrame.new(centre + Vector3.new(0, index * 2.4, 0)) * FLAT,
			14 - index * 2.5,
			0.4,
			palette.glow,
			0.4
		)
		tweenTo(column, 0.5, Enum.EasingStyle.Quart, {
			CFrame = CFrame.new(centre + Vector3.new(0, index * 4.5 + 3, 0))
				* CFrame.Angles(0, index * 2.2, 0)
				* FLAT,
			Size = Vector3.new(0.2, 2, 2),
			Transparency = 1,
		})
		Debris:AddItem(column, 0.56)
	end

	-- Drawn up the column rather than thrown out of it, which is the only way a
	-- particle burst can read as absorption instead of as an explosion.
	spray(centre + Vector3.new(0, 1, 0), tier(level, 8, 18, 32), {
		core = palette.core,
		glow = palette.glow,
		sizeFrom = 1.6,
		sizeTo = 0,
		speed = NumberRange.new(5, 14),
		life = NumberRange.new(0.4, 0.8),
		spread = 35,
		acceleration = Vector3.new(0, 30, 0),
		drag = 1,
	})

	-- The swallow, timed to when the streaks arrive.
	task.delay(0.34, function()
		local swallow = ball(heart, 1, palette.core, 0)
		bloom(swallow, 0.3, Vector3.one * 11, Enum.EasingStyle.Quint)
		flare(heart, palette.glow, 9, 40)
		shakeAt(heart, 0.3, 140)
		spray(heart, tier(level, 6, 14, 24), {
			core = palette.core,
			glow = palette.glow,
			sizeFrom = 1.2,
			sizeTo = 0,
			speed = NumberRange.new(16, 44),
			life = NumberRange.new(0.25, 0.55),
			spread = 40,
			acceleration = Vector3.new(0, 30, 0),
		})
	end)
end

--[[ Tempest. The sky comes down.

	The single most expensive technique in the game (85 madra, 20 second cooldown,
	1.8 second windup) and the only one that draws from above the play space:
	rising vortex bands, bolts landing in a stagger across the whole radius, and a
	shock ring off the last one. If any one cast in this game should stop a fight
	to be looked at, it is this one. ]]
local function drawTempest(shot: Shot, palette: Palette, _duration: number, level: number)
	local floor = groundY(shot.origin, shot.origin.Y - 3)
	local centre = Vector3.new(shot.origin.X, floor, shot.origin.Z)

	shakeAt(centre, 0.34, 200)
	groundWave(centre, 4, RULER_RADIUS * 2, palette, 0.7)

	-- Vortex bands: rising and widening, each turned further than the last, so
	-- the whole column reads as one rotation.
	local bands = tier(level, 2, 3, 5)
	for index = 1, bands do
		local band = disc(
			CFrame.new(centre + Vector3.new(0, index * 1.5, 0)) * FLAT,
			RULER_RADIUS * 0.5,
			0.5,
			palette.glow,
			0.4
		)
		tweenTo(band, 0.95, Enum.EasingStyle.Quart, {
			CFrame = CFrame.new(centre + Vector3.new(0, 6 + index * 5.5, 0))
				* CFrame.Angles(0, index * 1.4, 0)
				* FLAT,
			Size = Vector3.new(0.2, RULER_RADIUS * 1.9, RULER_RADIUS * 1.9),
			Transparency = 1,
			Color = palette.core,
		})
		Debris:AddItem(band, 1.02)
	end

	spray(centre + Vector3.new(0, 3, 0), tier(level, 14, 28, 50), {
		core = palette.core,
		glow = palette.glow,
		sizeFrom = 1.4,
		sizeTo = 5,
		speed = NumberRange.new(20, 52),
		life = NumberRange.new(0.5, 1),
		spread = 180,
		acceleration = Vector3.new(0, 10, 0),
		drag = 1.5,
	})

	local strikes = tier(level, 2, 3, 5)
	local last = 0
	for index = 1, strikes do
		local angle = RNG:NextNumber(0, math.pi * 2)
		local radius = math.sqrt(RNG:NextNumber(0.02, 1)) * (RULER_RADIUS - 2)
		local at = centre + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		local delay = 0.1 + (index - 1) * (0.75 / strikes)
		last = math.max(last, delay)

		task.delay(delay, function()
			-- A jagged polyline, because a straight line is a pole and a bent one
			-- is lightning.
			local top = at + Vector3.new(RNG:NextNumber(-8, 8), 62, RNG:NextNumber(-8, 8))
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
				local shard = block(
					Vector3.new(1.1, 1.1, length),
					look(previous:Lerp(point, 0.5), point),
					palette.core,
					0
				)
				tweenTo(shard, 0.16, Enum.EasingStyle.Quad, {
					Size = Vector3.new(0.1, 0.1, length),
					Transparency = 1,
					Color = palette.glow,
				})
				Debris:AddItem(shard, 0.22)
				previous = point
			end

			local strike = ball(at + Vector3.new(0, 1, 0), 2, palette.core, 0)
			bloom(strike, 0.24, Vector3.one * 12, Enum.EasingStyle.Quint)
			groundWave(at, 2, 24, palette, 0.35)
			flare(at + Vector3.new(0, 2, 0), palette.glow, 9, 38)
			spray(at, tier(level, 5, 12, 20), {
				core = palette.core,
				glow = palette.glow,
				sizeFrom = 1,
				sizeTo = 0,
				speed = NumberRange.new(20, 50),
				life = NumberRange.new(0.2, 0.5),
				spread = 100,
				acceleration = Vector3.new(0, -20, 0),
			})
			shakeAt(at, 0.26, 130)
		end)
	end

	-- The last bolt lands and the storm blows outward: the cast has an ending,
	-- not just a stop.
	task.delay(last + 0.16, function()
		segmentRing(centre, RULER_RADIUS * 0.25, tier(level, 8, 14, 24), 1.4, palette, 0.55, 4)
		groundWave(centre, 8, RULER_RADIUS * 2.2, palette, 0.5)
		shakeAt(centre, 0.5, 200)
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

--[[ Anything the table does not know still draws something.

	A technique added to Config without a drawing here would otherwise be silent,
	and a silent button is indistinguishable from a broken one. This keeps the
	old placeholder behaviour as the floor: strikers get a bolt, everything else
	gets a ring at the caster's feet. ]]
local function drawFallback(shot: Shot, palette: Palette, _duration: number, level: number)
	local target = shot.target
	if target then
		local direction = aim(shot.origin, target)
		bolt(shot.origin, target, palette, 0.5, 6, 0.1, level)
		task.delay(0.1, function()
			impact(target, direction, palette, 1, shot.hit, level)
		end)
		return
	end
	local floor = groundY(shot.origin, shot.origin.Y - 3)
	groundWave(Vector3.new(shot.origin.X, floor + 0.2, shot.origin.Z), 4, 20, palette, 0.4)
end

function Vfx.play(shot: Shot)
	-- Remote payloads are untyped at runtime, so the two fields every path below
	-- dereferences are checked before anything is drawn.
	if typeof(shot.techId) ~= "string" or typeof(shot.origin) ~= "Vector3" then
		return
	end

	--[[ Detail is judged at the caster, not at the impact, because that is where
		every kind but striker happens -- and your own casts are always drawn in
		full, since a technique that degrades in your own hands feels broken
		rather than optimised. ]]
	local level = if isLocalCaster(shot) then DETAIL_FULL else detailAt(shot.origin)
	if level <= DETAIL_NONE then
		return
	end

	local tech = Config.Techniques[shot.techId]
	local palette = PALETTE[shot.techId] or FALLBACK
	local duration = if tech then tech.buffDuration else 0
	local draw = DRAW[shot.techId] or drawFallback

	draw(shot, palette, duration, level)
end

return Vfx
