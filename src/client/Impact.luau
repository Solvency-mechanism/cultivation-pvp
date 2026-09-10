--!strict
--[[
	The impact grammar.

	One function -- `Impact.play` -- and every hit in the game goes through it,
	because the server calls it from exactly one place: the moment damage is
	actually applied. Not the moment a technique is cast, not the moment a
	raycast finds a body. A striker bolt, a Ruler sweep catching four people at
	once and a Forger construct ticking on somebody standing in it all produce
	the same channels at the same weight for the same fraction of a health bar.

	That seam is the point. Before this, landing a Pierce for 128 and whiffing
	it produced identical screens, so there was no moment of contact, so there
	was no skill signal, so there was no reason to aim.

	Seven channels, in the order the eye reads them:

	  1. a warm flash core at the point of contact, gone in ~0.14 s
	  2. white spark shards thrown outward from it, gone in ~0.26 s
	  3. a near-black dust puff that outlives both, ~0.85 s
	  4. a damage number rising out of the body over 0.6 s
	  5. a hitmarker at screen centre, for whoever landed it
	  6. 60-90 ms of hitstop
	  7. camera shake scaled to how much of a bar just vanished

	Three staggered lifetimes on the first three is most of the trick. A single
	element that appears and disappears reads as a flicker; three that arrive
	together and leave separately read as an event.

	Three rules this file does not break.

	1. **Presentation only.** Damage is applied and final on the server before
	   the broadcast that arrives here is even sent. Nothing below decides an
	   outcome, and a client that drops every one of these packets changes
	   nothing but its own screen.

	2. **Nothing obstructs the server.** Every BasePart created here is
	   Anchored, with CanCollide, CanQuery and CanTouch all false. The striker
	   raycast and both overlap queries run against a world that, in a
	   listen-server Studio session, contains these parts -- so those flags are
	   the only thing stopping a dust puff from eating somebody's shot.

	3. **Hitstop is a held camera, not dilated time.** No DeltaTime is touched,
	   no Humanoid is slowed, nothing is told to the server. The local camera
	   stops writing new CFrames for four or five frames and then resumes.
	   Everything else in the simulation, on both machines, keeps running.

	All tuning lives in ImpactSpec. This file is the mechanism.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local ImpactSpec = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ImpactSpec"))

local Impact = {}

--[[ What the server sends on every applied hit.

	Deliberately six fields and no technique id: this fires from inside
	`damagePlayer`, which is reached by three different paths that do not all
	know what was cast. Impact colour is hue-neutral by design anyway -- the
	technique already spent its colour on the way in, and contact is white. ]]
export type Event = {
	attackerId: number,
	targetId: number,
	position: Vector3,
	damage: number,
	stageIndex: number,
	died: boolean,
}

local RNG = Random.new()

local function color(rgb: { r: number, g: number, b: number }): Color3
	return Color3.fromRGB(rgb.r, rgb.g, rgb.b)
end

local FLASH_CORE = color(ImpactSpec.Palette.flashCore)
local SPARK_CORE = color(ImpactSpec.Palette.sparkCore)
local DUST = color(ImpactSpec.Palette.dust)
local DEALT_TEXT = color(ImpactSpec.Palette.dealtText)
local TAKEN_TEXT = color(ImpactSpec.Palette.takenText)
local KILL_TEXT = color(ImpactSpec.Palette.killText)
local MARKER_DEALT = color(ImpactSpec.Palette.markerDealt)
local MARKER_KILL = color(ImpactSpec.Palette.markerKill)
local VIGNETTE = color(ImpactSpec.Palette.vignette)

local BLACK = Color3.new(0, 0, 0)

-- ---------------------------------------------------------------- scene, parts

local scenery: Folder? = nil

--[[ Everything spawned here lives in one client-only folder. Client-created, so
	it never replicates and no server system can see it -- which is what makes it
	safe to put geometry in the middle of a fight at all. Separate from
	ClientVfx's folder on purpose, so the two part budgets stay independent. ]]
local function scene(): Folder
	local existing = scenery
	if existing and existing.Parent then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "ClientImpact"
	created.Parent = Workspace
	scenery = created
	return created
end

-- The one place the non-negotiable flags are set, so there is exactly one line
-- to audit when somebody asks whether this can break a raycast.
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

local function tweenTo(instance: Instance, seconds: number, goal: { [string]: any })
	local info = TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(instance, info, goal):Play()
end

local function ball(position: Vector3, diameter: number, tint: Color3, transparency: number): Part
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.one * diameter
	part.CFrame = CFrame.new(position)
	part.Color = tint
	part.Material = Enum.Material.Neon
	part.Transparency = transparency
	decorate(part)
	return part
end

local function look(from: Vector3, to: Vector3): CFrame
	if (to - from).Magnitude < 1e-4 then
		return CFrame.new(from)
	end
	return CFrame.lookAt(from, to)
end

-- Outward and slightly up, so shards leave the body rather than sinking through
-- the floor they were spawned next to.
local function scatter(): Vector3
	local raw = Vector3.new(RNG:NextNumber(-1, 1), RNG:NextNumber(-0.35, 1), RNG:NextNumber(-1, 1))
	if raw.Magnitude < 1e-3 then
		return Vector3.yAxis
	end
	return raw.Unit
end

-- ---------------------------------------------------------------- camera

--[[ Hitstop and shake share one render-step binding, because they are the same
	resource: the camera's CFrame after the camera scripts have written it.

	Bound one priority above ClientVfx's cast shake, so a hitstop freeze
	overrides a cast rumble for the frames it lasts instead of fighting it, and
	so the shake below composes on top of whatever ClientVfx already added. ]]
local CAMERA_BIND = "ClientImpactCamera"

local cameraBound = false
local heldCFrame: CFrame? = nil
local holdUntil = 0
local trauma = 0
local lastHitstopAt = 0

local function releaseCamera()
	if cameraBound then
		RunService:UnbindFromRenderStep(CAMERA_BIND)
		cameraBound = false
	end
end

local function stepCamera(deltaSeconds: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		heldCFrame = nil
		trauma = 0
		releaseCamera()
		return
	end

	local held = heldCFrame
	if held then
		if os.clock() < holdUntil then
			-- The freeze. Trauma is deliberately not decayed while it holds:
			-- during hitstop, no time has passed.
			camera.CFrame = held
			return
		end
		heldCFrame = nil
	end

	if trauma <= 0.004 then
		trauma = 0
		releaseCamera()
		return
	end

	-- Squared, so a light hit is a nudge and a heavy one is a hit. Linear
	-- trauma makes every impact in the game feel like the same impact.
	local power = trauma * trauma
	local offset = power * ImpactSpec.Shake.offsetStuds
	local roll = power * ImpactSpec.Shake.rollRadians
	camera.CFrame = camera.CFrame
		* CFrame.new(RNG:NextNumber(-offset, offset), RNG:NextNumber(-offset, offset), 0)
		* CFrame.Angles(
			RNG:NextNumber(-roll, roll),
			RNG:NextNumber(-roll, roll),
			RNG:NextNumber(-roll, roll)
		)

	trauma = math.max(0, trauma - deltaSeconds * ImpactSpec.Shake.decayPerSecond)
end

local function bindCamera()
	if cameraBound then
		return
	end
	cameraBound = true
	RunService:BindToRenderStep(CAMERA_BIND, Enum.RenderPriority.Camera.Value + 2, stepCamera)
end

local function shake(amount: number)
	if amount <= 0 then
		return
	end
	trauma = math.min(1, math.max(trauma, amount))
	bindCamera()
end

local function hitstop(seconds: number)
	local now = os.clock()
	if now - lastHitstopAt < ImpactSpec.Hitstop.refractorySeconds then
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	lastHitstopAt = now
	heldCFrame = camera.CFrame
	holdUntil = now + seconds
	bindCamera()
end

-- ---------------------------------------------------------------- screen

local screenBuilt = false
local markerScale: UIScale? = nil
local markerArms: { Frame } = {}
local vignetteEdges: { Frame } = {}

--[[ A tight X at screen centre. Two bars rather than four corner ticks, and
	scaled by severity, so a heavy hit is visibly heavier without needing a
	number read. ]]
local function buildMarker(parent: ScreenGui)
	local spec = ImpactSpec.Marker

	local holder = Instance.new("Frame")
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromOffset(spec.pixels, spec.pixels)
	holder.BackgroundTransparency = 1
	holder.ZIndex = 2
	holder.Parent = parent

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = holder
	markerScale = scale

	for _, turn in { 45, -45 } do
		local arm = Instance.new("Frame")
		arm.AnchorPoint = Vector2.new(0.5, 0.5)
		arm.Position = UDim2.fromScale(0.5, 0.5)
		arm.Size = UDim2.fromOffset(spec.thickness, spec.armPixels)
		arm.Rotation = turn
		arm.BorderSizePixel = 0
		arm.BackgroundColor3 = MARKER_DEALT
		arm.BackgroundTransparency = 1
		arm.ZIndex = 2
		arm.Parent = holder
		table.insert(markerArms, arm)
	end
end

--[[ The damage vignette, as four gradient bands rather than a radial image.

	No asset id is guessed anywhere in this feature, and a radial vignette needs
	one. Four edge bands fading inward gets the same read -- colour crowding the
	frame from outside -- out of four Frames and no upload. ]]
local function buildVignette(parent: ScreenGui)
	local band = ImpactSpec.Vignette.bandFraction
	-- `inward` says which end of the gradient is the screen edge: false means
	-- the band is solid at its first keypoint, true at its last.
	local edges = {
		{ size = UDim2.fromScale(1, band), at = UDim2.fromScale(0, 0), turn = 90, inward = false },
		{
			size = UDim2.fromScale(1, band),
			at = UDim2.fromScale(0, 1 - band),
			turn = 90,
			inward = true,
		},
		{ size = UDim2.fromScale(band, 1), at = UDim2.fromScale(0, 0), turn = 0, inward = false },
		{
			size = UDim2.fromScale(band, 1),
			at = UDim2.fromScale(1 - band, 0),
			turn = 0,
			inward = true,
		},
	}

	for _, edge in edges do
		local frame = Instance.new("Frame")
		frame.Size = edge.size
		frame.Position = edge.at
		frame.BackgroundColor3 = VIGNETTE
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.ZIndex = 1
		frame.Parent = parent

		local gradient = Instance.new("UIGradient")
		gradient.Rotation = edge.turn
		gradient.Transparency = if edge.inward
			then NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(1, 0),
			})
			else NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(1, 1),
			})
		gradient.Parent = frame

		table.insert(vignetteEdges, frame)
	end
end

--[[ Built on first use rather than at load, because PlayerGui may not exist
	yet when this module is required. A hit that arrives before it does costs
	its marker and nothing else. ]]
local function ensureScreen()
	if screenBuilt then
		return
	end
	local player = Players.LocalPlayer
	if not player then
		return
	end
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = "ImpactFeedback"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 5
	screen.Parent = playerGui

	buildVignette(screen)
	buildMarker(screen)
	screenBuilt = true
end

local function markHit(severity: number, killing: boolean)
	ensureScreen()
	local spec = ImpactSpec.Marker

	local scale = markerScale
	if scale then
		scale.Scale = spec.punchFrom
		local info = TweenInfo.new(spec.seconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		TweenService:Create(scale, info, { Scale = ImpactSpec.markerScale(severity) }):Play()
	end

	local tint = if killing then MARKER_KILL else MARKER_DEALT
	for _, arm in markerArms do
		arm.BackgroundColor3 = tint
		arm.BackgroundTransparency = 0
		tweenTo(arm, spec.seconds, { BackgroundTransparency = 1 })
	end
end

local function flashVignette(strength: number)
	ensureScreen()
	for _, frame in vignetteEdges do
		frame.BackgroundTransparency = 1 - strength
		tweenTo(frame, ImpactSpec.Vignette.seconds, { BackgroundTransparency = 1 })
	end
end

-- ---------------------------------------------------------------- damage number

--[[ World-space, pixel-sized, and readable before it is pretty.

	BillboardGui offsets are pixels regardless of distance, so 36-56 px stays 36
	-56 px whether the hit landed at your feet or across a Ruler radius. That is
	the whole reason this is not a stud-sized part with a decal on it. ]]
local function damageNumber(event: Event, severity: number, taken: boolean)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local spec = ImpactSpec.Number

	local host = Instance.new("Part")
	host.Size = Vector3.one * 0.2
	host.Transparency = 1
	host.CFrame = CFrame.new(event.position + Vector3.new(0, 3, 0))
	decorate(host)

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(280, 76)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = spec.maxDistance
	gui.Parent = host

	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamBlack
	text.TextSize = ImpactSpec.textSize(severity, event.died)
	text.TextColor3 = if event.died then KILL_TEXT elseif taken then TAKEN_TEXT else DEALT_TEXT
	-- Floored to at least 1: a hit the server bothered to apply should never
	-- render as a zero.
	text.Text = tostring(math.max(1, math.round(event.damage)))
	text.Parent = gui

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = spec.strokeThickness
	stroke.Color = BLACK
	stroke.Parent = text

	--[[ Rise, with a lateral tilt of up to +/-15 degrees taken along the
		camera's own right vector. Drifting in world space would let two numbers
		separate in depth and still stack on screen, which is the one thing the
		drift exists to prevent. ]]
	local right = camera.CFrame.RightVector
	local flat = Vector3.new(right.X, 0, right.Z)
	local lateral = if flat.Magnitude > 1e-4 then flat.Unit else Vector3.xAxis
	local tilt = math.tan(math.rad(RNG:NextNumber(-spec.driftDegrees, spec.driftDegrees)))
	local travel = Vector3.new(0, spec.riseStuds, 0) + lateral * tilt * spec.riseStuds

	tweenTo(host, spec.seconds, { Position = host.Position + travel })

	local hold = spec.seconds * spec.holdFraction
	local fade = spec.seconds - hold
	task.delay(hold, function()
		if not text.Parent then
			return
		end
		tweenTo(text, fade, { TextTransparency = 1 })
		tweenTo(stroke, fade, { Transparency = 1 })
	end)

	Debris:AddItem(host, spec.seconds + 0.1)
end

-- ---------------------------------------------------------------- world burst

--[[ The impact sound.

	Skipped entirely while the asset ids in ImpactSpec.Audio are empty, which
	they are, because no id in this feature is guessed. See the comment there
	for what filling them in takes. ]]
local function playSound(host: BasePart, killing: boolean)
	local audio = ImpactSpec.Audio
	local assetId = if killing and audio.killAssetId ~= ""
		then audio.killAssetId
		else audio.impactAssetId
	if assetId == "" then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = assetId
	sound.Volume = audio.volume
	sound.PlaybackSpeed = RNG:NextNumber(audio.minPitch, audio.maxPitch)
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMaxDistance = audio.rollOffMaxStuds
	sound.Parent = host
	sound:Play()
	Debris:AddItem(sound, 4)
end

local function sparks(position: Vector3, severity: number, count: number)
	local spec = ImpactSpec.Sparks
	for _ = 1, count do
		local away = scatter()
		local length = RNG:NextNumber(spec.minLength, spec.maxLength)
		local shard = Instance.new("Part")
		shard.Size = Vector3.new(spec.thickness, spec.thickness, length)
		shard.CFrame = look(position, position + away)
		shard.Color = SPARK_CORE
		shard.Material = Enum.Material.Neon
		shard.Transparency = 0.05
		decorate(shard)

		local travel = RNG:NextNumber(spec.minTravel, spec.maxTravel) * (0.6 + severity * 0.6)
		local landing = position + away * travel
		tweenTo(shard, spec.seconds, {
			CFrame = look(landing, landing + away),
			Size = Vector3.new(0.04, 0.04, length * 0.35),
			Transparency = 1,
		})
		Debris:AddItem(shard, spec.seconds + 0.05)
	end
end

local function dust(position: Vector3, severity: number, puffs: number)
	local spec = ImpactSpec.Dust
	local diameter = ImpactSpec.dustDiameter(severity)
	for _ = 1, puffs do
		local at = position
			+ Vector3.new(
				RNG:NextNumber(-spec.spreadStuds, spec.spreadStuds),
				RNG:NextNumber(-spec.spreadStuds * 0.4, spec.spreadStuds),
				RNG:NextNumber(-spec.spreadStuds, spec.spreadStuds)
			)
		local puff = Instance.new("Part")
		puff.Shape = Enum.PartType.Ball
		puff.Size = Vector3.one * diameter * RNG:NextNumber(0.7, 1.1)
		puff.CFrame = CFrame.new(at)
		puff.Color = DUST
		-- Not Neon. The dark volume is the half of the contrast pair that the
		-- white shards are legible against, and a glowing one is neither.
		puff.Material = Enum.Material.SmoothPlastic
		puff.Transparency = spec.transparency
		decorate(puff)

		tweenTo(puff, spec.seconds, {
			Size = puff.Size * spec.growth,
			Position = at + Vector3.new(0, spec.riseStuds, 0),
			Transparency = 1,
		})
		Debris:AddItem(puff, spec.seconds + 0.05)
	end
end

--[[ Flash, shards, dust -- three elements, three lifetimes, one point in space.
	`reduced` halves the two countable ones for a hit that is far away or that
	arrived while the scene was already crowded. ]]
local function burst(event: Event, severity: number, reduced: boolean)
	local position = event.position + Vector3.new(0, 2, 0)

	local diameter = ImpactSpec.flashDiameter(severity)
	local flash = ball(position, diameter, FLASH_CORE, 0.05)
	tweenTo(flash, ImpactSpec.Flash.seconds, {
		Size = Vector3.one * diameter * ImpactSpec.Flash.growth,
		Transparency = 1,
	})
	Debris:AddItem(flash, ImpactSpec.Flash.seconds + 0.05)
	playSound(flash, event.died)

	local count = ImpactSpec.sparkCount(severity)
	sparks(position, severity, if reduced then math.max(3, count // 2) else count)
	dust(position, severity, if reduced then 1 else ImpactSpec.Dust.puffs)
end

-- ---------------------------------------------------------------- entry point

--[[ Every hit in the game, from one place.

	Who sees what: the world burst is part of the scene and everyone in range
	gets it. The number, the hitstop and the shake are for the two people in the
	exchange -- a six-way brawl that showed every combatant's numbers would be
	unreadable, and a camera that shook for somebody else's fight would be a
	bug. The hitmarker is the attacker's alone; the vignette is the target's. ]]
function Impact.play(event: Event)
	-- Remote payloads are untyped at runtime, so every field dereferenced below
	-- is checked before anything is drawn.
	if typeof(event) ~= "table" or typeof(event.position) ~= "Vector3" then
		return
	end
	if type(event.damage) ~= "number" or type(event.stageIndex) ~= "number" then
		return
	end
	if type(event.attackerId) ~= "number" or type(event.targetId) ~= "number" then
		return
	end
	if event.damage ~= event.damage or event.damage <= 0 then
		return
	end

	local player = Players.LocalPlayer
	local localId = if player then player.UserId else 0
	local taken = event.targetId == localId
	local dealt = event.attackerId == localId and not taken

	local severity = ImpactSpec.severity(Config, event.stageIndex, event.damage)

	local camera = Workspace.CurrentCamera
	local distance = if camera
		then (camera.CFrame.Position - event.position).Magnitude
		else math.huge

	if distance < ImpactSpec.Budget.cullStuds then
		local crowded = #scene():GetChildren() > ImpactSpec.Budget.maxLiveParts
		burst(event, severity, crowded or distance > ImpactSpec.Budget.reducedStuds)
	end

	if taken or dealt then
		damageNumber(event, severity, taken)
		hitstop(ImpactSpec.hitstopSeconds(severity))
		shake(ImpactSpec.shakeTrauma(severity, taken))
	end
	if dealt then
		markHit(severity, event.died)
	end
	if taken then
		flashVignette(ImpactSpec.vignetteStrength(severity))
	end
end

local started = false

--[[ Bind to the Impact remote. Idempotent, so calling it twice is a no-op
	rather than two impacts per hit. ]]
function Impact.start()
	if started then
		return
	end
	started = true

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local remote = remotes:WaitForChild("Impact")
	if not remote:IsA("RemoteEvent") then
		return
	end
	remote.OnClientEvent:Connect(function(event: Event)
		Impact.play(event)
	end)
end

return Impact
