--!strict
--[[
	Worldcraft -- the structures people look at and want to walk toward.

	The first of them is the volcano on the Barrens spine: a hollow cone of
	tangent basalt facets with lava as neon slivers, a ledge winding up to a
	crater a prime can crown, an archway into the side, a chamber of magma
	pools, and the head of a red dragon rising out of the largest of them.
	Chosen over a Terrain cone by measured prototype (worldcraft.md): the same
	world as the crags and the spire -- stacks of flat-shaded primitives, dark
	mass with neon as the bright half -- cheaper in parts and frame time, its
	crown on placeable ground, and nothing about it asynchronous. Terrain was
	invisible to raycasts in the frame it was written and sixty percent steep.

	REQUIRES NOTHING. ArenaService references these builders as data, so this
	file may not reach back into it: every builder takes a `Kit` -- an rng
	source and the two folders it may parent into -- and its own primitives
	live here (forty lines duplicated; a table of borrowed functions would
	couple the files harder than the duplication does).

	The two folders are the whole seam. `groundYAt` treats anything under
	ArenaDecor as not-floor, so every surface a node may stand on -- the ramp,
	the tunnel floor, the crater floor, the crater lake's rim bed, the stair --
	goes under `kit.ground`, and everything only looked at -- facets, rivers,
	arch, pools, dragon -- under `kit.decor`. Two facts from the prototype that
	this layout exists to respect: CanQuery=false is IGNORED while CanCollide
	is true, so a collidable bed with CanQuery off still stops the placer; and
	a prime crowns the crater only because the lake bed is floor.

	Every builder draws from `kit.rngFor(name)` and never from a shared
	stream, so nothing here can reshuffle a height that already existed and
	nothing added later can reshuffle these.

	Positions are deterministic; only tilts, jitter and colours roll. The
	mountain is one profile (foot 80, rim 100 high, rim 26 wide, crater 12
	deep, concave flank) and everything is arithmetic on its centre and the
	bearing of its mouth.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Worldcraft = {}

export type Kit = {
	rngFor: (name: string) -> Random,
	decor: Folder,
	ground: Folder,
}

--[[ The shape of a REGIONS entry as this file needs it. Structural, so
	ArenaService's own Region type satisfies it without an import. ]]
export type RegionLike = {
	id: string,
	blobs: { { center: Vector3, radius: number } },
}

-- The mountain in numbers ---------------------------------------------------

--[[ Foot radius, rim height, rim radius, crater depth. The flank is concave --
	gentle at the foot, 67 degrees at the rim -- which is the Mount Doom
	silhouette; a straight cone reads as a pyramid. ]]
local FOOT_RADIUS = 80
local RIM_HEIGHT = 100
local RIM_RADIUS = 26
local CRATER_DEPTH = 12
local FLANK_POWER = 1.5

--[[ The arch stands on the flank where it is already fifteen studs tall, not
	out on the skirt in front of a hole; the doorway is two bands of facets
	left out above it. ]]
local ARCH_RADIUS = 64
local ARCH_SPAN = 16
local APPROACH_RADIUS = ARCH_RADIUS + 24

--[[ The mouth faces the crossroads, turned this far north of that line so the
	doorway clears the Barrens' fallen arch at lobe 3 and opens toward the
	corridor the road arrives by. ]]
local MOUTH_TURN = -0.6

local BASALT_LOW = Color3.fromRGB(64, 48, 46)
local BASALT_HIGH = Color3.fromRGB(122, 74, 58)
local LAVA = Color3.fromRGB(255, 122, 46)
local LAVA_DEEP = Color3.fromRGB(255, 92, 30)
local ROAD = Color3.fromRGB(120, 96, 78)
local DARK_STONE = Color3.fromRGB(58, 48, 46)
local BONE = Color3.fromRGB(222, 204, 172)

--[[ The flank, as the radius at which the surface reaches height h: the
	inverse of h = RIM_HEIGHT * t^FLANK_POWER, t running from the foot to the
	rim. Bands, ramp and rivers are all laid against this one curve. ]]
local function flankRadius(h: number): number
	local t = math.clamp(h / RIM_HEIGHT, 0, 1) ^ (1 / FLANK_POWER)
	return FOOT_RADIUS - (FOOT_RADIUS - RIM_RADIUS) * t
end

-- Primitives ----------------------------------------------------------------

local function newBlock(size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

--[[ A flat disc. Part.Shape = Cylinder runs its axis along local X, so the
	quarter turn about Z is what lays it down. `center` is the middle of the
	slab, not its top face. ]]
local function newDisc(
	radius: number,
	thickness: number,
	center: Vector3,
	color: Color3,
	material: Enum.Material
): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(thickness, radius * 2, radius * 2)
	part.CFrame = CFrame.new(center) * CFrame.Angles(0, 0, math.pi / 2)
	part.Color = color
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

local function newBall(
	diameter: number,
	position: Vector3,
	color: Color3,
	material: Enum.Material
): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(diameter, diameter, diameter)
	part.Position = position
	part.Color = color
	part.Material = material
	return part
end

-- Inlaid neon carries no physics: it would otherwise catch Striker rays.
local function makeInert(part: BasePart)
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
end

local function onBearing(angle: number, distance: number): Vector3
	return Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
end

local function tangent(angle: number): Vector3
	return Vector3.new(-math.sin(angle), 0, math.cos(angle))
end

local function light(parent: BasePart, color: Color3, range: number, brightness: number)
	local point = Instance.new("PointLight")
	point.Color = color
	point.Range = range
	point.Brightness = brightness
	point.Parent = parent
end

local function wrapAngle(a: number): number
	return math.atan2(math.sin(a), math.cos(a))
end

-- Where things are, for whoever lays roads and anchors ----------------------

--[[ The bearing the doorway faces, from the mountain's centre. ]]
function Worldcraft.volcanoMouth(centre: Vector3): number
	return math.atan2(-centre.Z, -centre.X) + MOUTH_TURN
end

--[[ Where a road should end: on the mouth bearing, a slab's length short of
	the arch, so the last slab does not sit in the jambs. ]]
function Worldcraft.volcanoApproach(centre: Vector3): Vector3
	return centre + onBearing(Worldcraft.volcanoMouth(centre), APPROACH_RADIUS)
end

--[[ The crown: the crater floor. A prime placed within this radius of the
	centre stands in the lava lake under its own shaft. ]]
Worldcraft.VOLCANO_CROWN_RADIUS = 9
Worldcraft.VOLCANO_FOOT_RADIUS = FOOT_RADIUS
Worldcraft.VOLCANO_RIM_HEIGHT = RIM_HEIGHT

-- Shared structures ---------------------------------------------------------

--[[ The way up: a ledge that winds 1.6 turns around the flank from beside
	the arch to the rim. Slabs, not a slope -- the house style is a road that
	curves, and a road is what a prime at the crown is reached by. Stood on. ]]
local function buildRamp(kit: Kit, centre: Vector3, mouth: number, name: string): number
	local rng = kit.rngFor(`{name} ramp`)
	local steps = 64
	local turns = 1.6
	local startAngle = mouth + 0.9
	local previous: Vector3? = nil
	local arrival = startAngle
	for step = 0, steps do
		local t = step / steps
		local h = t * (RIM_HEIGHT - 2)
		local angle = startAngle + t * turns * math.pi * 2
		arrival = angle
		local r = flankRadius(h) + 3.5
		local point = centre + onBearing(angle, r) + Vector3.new(0, h, 0)
		if previous then
			local along = point - previous
			local slab = newBlock(
				Vector3.new(10, 1.6, along.Magnitude + 2.5),
				CFrame.lookAt((point + previous) / 2, point, Vector3.yAxis),
				ROAD:Lerp(DARK_STONE, rng:NextNumber(0, 0.5)),
				Enum.Material.Cobblestone
			)
			slab.Name = `{name}Ramp{step}`
			slab.Parent = kit.ground

			if step % 8 == 4 then
				local base = point + onBearing(angle, 4.5)
				local post = newBlock(
					Vector3.new(2, 9, 2),
					CFrame.new(base + Vector3.new(0, 4.5, 0)),
					DARK_STONE,
					Enum.Material.Rock
				)
				post.Name = `{name}RampPost{step}`
				post.Parent = kit.decor
				local flame = newBlock(
					Vector3.new(2.8, 2.8, 2.8),
					CFrame.new(base + Vector3.new(0, 10, 0)) * CFrame.Angles(0.6, 0.6, 0),
					LAVA,
					Enum.Material.Neon
				)
				flame.Name = `{name}RampFlame{step}`
				flame.CastShadow = false
				light(flame, LAVA, 18, 1.4)
				flame.Parent = kit.decor
			end
		end
		previous = point
	end
	return arrival
end

--[[ The archway into the side: two jambs and ten voussoirs turned around the
	opening with a neon keystone -- the torii's rotated-beam idiom bent into an
	arc -- and a cobbled tunnel floor running in to the chamber. ]]
local function buildArchway(kit: Kit, centre: Vector3, mouth: number, name: string)
	local foot = centre + onBearing(mouth, ARCH_RADIUS)
	local facing = CFrame.lookAt(foot, foot + onBearing(mouth, 1))
	for leg = -1, 1, 2 do
		local jamb = newBlock(
			Vector3.new(6, 14, 9),
			facing * CFrame.new(ARCH_SPAN * leg, 7, 0),
			DARK_STONE,
			Enum.Material.Basalt
		)
		jamb.Name = `{name}ArchJamb{if leg < 0 then "L" else "R"}`
		jamb.Parent = kit.decor
	end
	local count = 9
	for index = 0, count do
		local a = (index / count) * math.pi
		local keystone = index == math.floor(count / 2)
		local offset = Vector3.new(-math.cos(a) * ARCH_SPAN, 14 + math.sin(a) * ARCH_SPAN, 0)
		local block = newBlock(
			Vector3.new(7, 5.5, 9),
			facing * CFrame.new(offset) * CFrame.Angles(0, 0, a - math.pi / 2),
			if keystone then LAVA else DARK_STONE:Lerp(BASALT_HIGH, index / count * 0.5),
			if keystone then Enum.Material.Neon else Enum.Material.Basalt
		)
		block.Name = `{name}ArchStone{index}`
		if keystone then
			block.CastShadow = false
			light(block, LAVA, 24, 1.6)
		end
		block.Parent = kit.decor
	end

	-- The tunnel floor, in from the arch. Inward is +Z: the frame looks out.
	for index = 0, 2 do
		local slab = newBlock(
			Vector3.new(24, 1.2, 14),
			facing * CFrame.new(0, 0.6, 6 + index * 13),
			ROAD:Lerp(DARK_STONE, 0.3),
			Enum.Material.Cobblestone
		)
		slab.Name = `{name}TunnelFloor{index}`
		slab.Parent = kit.ground
	end
end

--[[ A magma pool: a dark rim bed with a neon disc inlaid in it -- the node
	ring's own dark-and-bright idiom. `stoodOn` puts the bed under ground, for
	the one pool a prime has to be able to crown. ]]
local function buildMagmaPool(
	kit: Kit,
	at: Vector3,
	radius: number,
	name: string,
	stoodOn: boolean?
)
	local bed =
		newDisc(radius + 2.2, 1.4, at + Vector3.new(0, 0.5, 0), DARK_STONE, Enum.Material.Slate)
	bed.Name = `{name}Bed`
	bed.Parent = if stoodOn then kit.ground else kit.decor

	local pool = newDisc(radius, 1, at + Vector3.new(0, 1.05, 0), LAVA_DEEP, Enum.Material.Neon)
	pool.Name = name
	pool.Transparency = 0.1
	makeInert(pool)
	light(pool, LAVA, radius * 4, 2.2)
	pool.Parent = kit.decor
end

-- The dragon --------------------------------------------------------------

--[[ The head of what must be a massive red dragon, primitives only: forty-one
	parts, blocky, stylised. Presence, not realism -- the first mesh would be
	the first asset dependency in a repo that has shipped none.

	Its forward is +Z of `at`. The skull is named "Head" so a nameplate that
	looks for one finds it (the seam interface found the hard way on dummies).
	The Model carries `Vendor = "dragon"` and a ProximityPrompt on the snout;
	the prompt sends one line through the Notice remote until an entity owner
	replaces that with something better. Combat owns the entity kind; this is
	the body it hangs off. ]]
function Worldcraft.buildDragonHead(kit: Kit, at: CFrame, name: string, scale: number?): Model
	local s = scale or 1
	local red = Color3.fromRGB(172, 44, 38)
	local belly = Color3.fromRGB(128, 34, 32)
	local eye = Color3.fromRGB(255, 176, 60)
	local model = Instance.new("Model")
	model.Name = name
	model:SetAttribute("Vendor", "dragon")

	local function piece(
		size: Vector3,
		offset: CFrame,
		color: Color3,
		material: Enum.Material,
		label: string
	): Part
		local grown = CFrame.new(offset.Position * s) * offset.Rotation
		local part = newBlock(size * s, at * grown, color, material)
		part.Name = label
		part.Parent = model
		return part
	end

	-- Skull, brow, snout, jaw, tongue, nostrils.
	local head =
		piece(Vector3.new(14, 10, 16), CFrame.new(0, 12, 0), red, Enum.Material.Slate, "Head")
	piece(
		Vector3.new(15, 3, 6),
		CFrame.new(0, 17.5, 4) * CFrame.Angles(-0.25, 0, 0),
		red,
		Enum.Material.Slate,
		"Brow"
	)
	local snout =
		piece(Vector3.new(10, 6, 14), CFrame.new(0, 11, 14), red, Enum.Material.Slate, "Snout")
	piece(
		Vector3.new(9, 3, 13),
		CFrame.new(0, 6.2, 13.5) * CFrame.Angles(0.32, 0, 0),
		belly,
		Enum.Material.Slate,
		"Jaw"
	)
	piece(
		Vector3.new(4, 1, 8),
		CFrame.new(0, 7.4, 13) * CFrame.Angles(0.32, 0, 0),
		LAVA,
		Enum.Material.Neon,
		"Tongue"
	)
	for side = -1, 1, 2 do
		piece(
			Vector3.new(2, 2, 2),
			CFrame.new(3 * side, 12.5, 21),
			Color3.fromRGB(40, 20, 20),
			Enum.Material.Slate,
			if side < 0 then "NostrilL" else "NostrilR"
		)
	end

	-- Eyes: neon balls with a slit.
	for side = -1, 1, 2 do
		local ball = newBall(
			3 * s,
			(at * CFrame.new(5.2 * side * s, 15 * s, 7 * s)).Position,
			eye,
			Enum.Material.Neon
		)
		ball.Name = if side < 0 then "EyeL" else "EyeR"
		ball.CastShadow = false
		light(ball, eye, 14 * s, 1.2)
		ball.Parent = model
		piece(
			Vector3.new(0.6, 2.4, 1),
			CFrame.new(5.2 * side + 1.3 * side, 15, 7.6),
			Color3.fromRGB(20, 10, 10),
			Enum.Material.Slate,
			if side < 0 then "SlitL" else "SlitR"
		)
	end

	-- Horns, back-swept, and a frill of four spikes.
	for side = -1, 1, 2 do
		piece(
			Vector3.new(3, 15, 3),
			CFrame.new(5.5 * side, 22, -5) * CFrame.Angles(-0.7, 0, 0.25 * side),
			BONE,
			Enum.Material.Marble,
			if side < 0 then "HornL" else "HornR"
		)
		piece(
			Vector3.new(2, 7, 2),
			CFrame.new(3 * side, 19, -8) * CFrame.Angles(-1.0, 0, 0.35 * side),
			BONE,
			Enum.Material.Marble,
			if side < 0 then "SpikeAL" else "SpikeAR"
		)
		piece(
			Vector3.new(2, 6, 2),
			CFrame.new(7.5 * side, 14, -7) * CFrame.Angles(-1.1, 0, 0.9 * side),
			BONE,
			Enum.Material.Marble,
			if side < 0 then "SpikeBL" else "SpikeBR"
		)
	end

	-- Teeth: six up, six down.
	for index = 0, 5 do
		local x = -4 + index * 1.6
		piece(
			Vector3.new(0.9, 2.2, 0.9),
			CFrame.new(x, 7.6, 19.5),
			BONE,
			Enum.Material.Marble,
			`ToothU{index}`
		)
		piece(
			Vector3.new(0.9, 1.8, 0.9),
			CFrame.new(x + 0.8, 6.4, 18.8) * CFrame.Angles(0.32, 0, 0),
			BONE,
			Enum.Material.Marble,
			`ToothD{index}`
		)
	end

	-- Neck plunging back and DOWN into the magma it rose from, each segment
	-- larger, each with a dorsal plate. It ends below the floor, so the body
	-- is implied and nothing pokes out of the far flank.
	for index = 1, 3 do
		local depth = -9 - index * 7
		local drop = 11 - index * 6.5
		local pitch = -0.45 * index
		piece(
			Vector3.new(12 + index * 1.5, 9 + index, 9),
			CFrame.new(0, drop, depth) * CFrame.Angles(pitch, 0, 0),
			red,
			Enum.Material.Slate,
			`Neck{index}`
		)
		piece(
			Vector3.new(1.6, 6, 6),
			CFrame.new(0, drop + 5 + index * 0.5, depth - 1) * CFrame.Angles(pitch - 0.4, 0, 0),
			BONE,
			Enum.Material.Marble,
			`Plate{index}`
		)
	end

	-- Crown scales.
	for index = 0, 3 do
		piece(
			Vector3.new(3.2, 1.2, 4),
			CFrame.new(-4.8 + index * 3.2, 17.6, -2) * CFrame.Angles(-0.15, 0, 0),
			belly,
			Enum.Material.Slate,
			`Scale{index}`
		)
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Speak"
	prompt.ObjectText = "the Dragon"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 16 * s
	prompt.RequiresLineOfSight = false
	prompt.Parent = snout

	--[[ It talks. There is no shop and nobody expects one in this build; the
		line is the deliverable. "local" is a notice kind the client already
		weights, so this needs nothing from interface. ]]
	prompt.Triggered:Connect(function(player: Player)
		local remotes = ReplicatedStorage:FindFirstChild("Remotes")
		local notice = if remotes then remotes:FindFirstChild("Notice") else nil
		if notice and notice:IsA("RemoteEvent") then
			notice:FireClient(
				player,
				"local",
				"The dragon regards you. It has nothing to sell you. Yet."
			)
		end
	end)

	model.PrimaryPart = head
	model.Parent = kit.decor
	return model
end

--[[ The chamber: three magma pools, a lava fall, and the dragon rising out of
	the largest pool at the back wall, facing the door. ]]
local function buildChamber(kit: Kit, centre: Vector3, mouth: number, name: string)
	local back = mouth + math.pi
	for index, spec in { { 0.9, 34, 9 }, { -0.7, 30, 7 }, { 2.4, 26, 6 } } do
		buildMagmaPool(
			kit,
			centre + onBearing(mouth + spec[1], spec[2]),
			spec[3],
			`{name}Pool{index}`
		)
	end

	local seat = centre + onBearing(back, 34)
	buildMagmaPool(kit, seat + onBearing(back, 10), 17, `{name}DragonPool`)
	Worldcraft.buildDragonHead(
		kit,
		CFrame.lookAt(seat + Vector3.new(0, 1, 0), seat + onBearing(back, 1) + Vector3.new(0, 1, 0)),
		`{name}Dragon`,
		1.8
	)

	local fall = newBlock(
		Vector3.new(3, 46, 5),
		CFrame.new(centre + onBearing(back + 0.5, 52) + Vector3.new(0, 30, 0)),
		LAVA,
		Enum.Material.Neon
	)
	fall.Name = `{name}LavaFall`
	fall.Transparency = 0.15
	makeInert(fall)
	light(fall, LAVA, 40, 2)
	fall.Parent = kit.decor
end

-- The volcano ---------------------------------------------------------------

--[[ A hollow cone of tangent facets. Eight bands of thin blocks, 12 to 21 per
	band, each tilted to its band's slope and yawed to its tangent, overlapping
	a tenth, jittered a stud. The interior comes free: a ring of facets is a
	cave. Facets are looked at, not stood on: decor.

	`centre` is on the plate (y 0); `mouth` defaults to `volcanoMouth`. ]]
function Worldcraft.buildVolcano(kit: Kit, centre: Vector3, mouth: number?)
	local name = "Volcano"
	local rng = kit.rngFor(name)
	local facing = mouth or Worldcraft.volcanoMouth(centre)
	local bands = 8
	local gapHalf = ARCH_SPAN + 3

	for band = 1, bands do
		local hLow = (band - 1) / bands * RIM_HEIGHT
		local hHigh = band / bands * RIM_HEIGHT
		local rLow = flankRadius(hLow)
		local rHigh = flankRadius(hHigh)
		local rMid = (rLow + rHigh) / 2
		local hMid = (hLow + hHigh) / 2
		local count = math.max(12, math.round(2 * math.pi * rMid / 22))
		local chord = 2 * math.pi * rMid / count * 1.12
		local slant = math.sqrt((rLow - rHigh) ^ 2 + (hHigh - hLow) ^ 2) + 1.5

		for index = 0, count - 1 do
			local angle = (index + 0.5 * (band % 2)) / count * math.pi * 2
			-- The doorway: two bands of facets left out over the arch.
			if band <= 2 and math.abs(wrapAngle(angle - facing)) * rMid < gapHalf then
				continue
			end
			local radial = onBearing(angle, 1)
			local upSlope = (Vector3.yAxis * (hHigh - hLow) - radial * (rLow - rHigh)).Unit
			local pos = centre
				+ radial * (rMid + rng:NextNumber(-1.2, 1.2))
				+ Vector3.new(0, hMid, 0)
			local facet = newBlock(
				Vector3.new(chord, slant, 3),
				CFrame.fromMatrix(pos, tangent(angle), upSlope)
					* CFrame.Angles(rng:NextNumber(-0.03, 0.03), 0, rng:NextNumber(-0.04, 0.04)),
				BASALT_LOW:Lerp(BASALT_HIGH, (band / bands) * 0.7 + rng:NextNumber(0, 0.3)),
				if band >= 7 then Enum.Material.Rock else Enum.Material.Basalt
			)
			facet.Name = `{name}Facet{band}_{index}`
			facet.Parent = kit.decor
		end
	end

	-- The ramp first, so the rim can leave a notch where it arrives.
	local arrival = buildRamp(kit, centre, facing, name)

	-- Crater: an inward ring of facets with a notch at the ramp, a floor you
	-- can stand on, a lake, and a stair back out of the bowl.
	local floorY = RIM_HEIGHT - CRATER_DEPTH
	local wallCount = 12
	local notch = math.round((wrapAngle(arrival) / (math.pi * 2)) * wallCount) % wallCount
	for index = 0, wallCount - 1 do
		if index == notch then
			continue
		end
		local angle = index / wallCount * math.pi * 2
		local radial = onBearing(angle, 1)
		local pos = centre
			+ radial * (RIM_RADIUS - 1.5)
			+ Vector3.new(0, RIM_HEIGHT - CRATER_DEPTH / 2 + 1, 0)
		local wall = newBlock(
			Vector3.new(2 * math.pi * (RIM_RADIUS - 1.5) / wallCount * 1.15, CRATER_DEPTH + 4, 3),
			CFrame.fromMatrix(pos, tangent(angle), (Vector3.yAxis * 12 + radial * 3).Unit),
			BASALT_HIGH,
			Enum.Material.Rock
		)
		wall.Name = `{name}CraterWall{index}`
		wall.Parent = kit.decor
	end
	local floor = newDisc(
		RIM_RADIUS - 2,
		2,
		centre + Vector3.new(0, floorY - 1, 0),
		DARK_STONE,
		Enum.Material.Basalt
	)
	floor.Name = `{name}CraterFloor`
	floor.Parent = kit.ground
	buildMagmaPool(kit, centre + Vector3.new(0, floorY, 0), 11, `{name}CraterLake`, true)

	-- Six two-stud steps from the crater floor up through the notch, so the
	-- bowl is a place you can leave without a technique.
	local stairAngle = notch / wallCount * math.pi * 2
	for step = 1, 6 do
		local r = RIM_RADIUS - 3 - (6 - step) * 2.2
		local tread = newBlock(
			Vector3.new(6, 2, 2.4),
			CFrame.new(centre + onBearing(stairAngle, r) + Vector3.new(0, floorY + step * 2 - 1, 0))
				* CFrame.Angles(0, -stairAngle, 0),
			DARK_STONE,
			Enum.Material.Basalt
		)
		tread.Name = `{name}CraterStair{step}`
		tread.Parent = kit.ground
	end

	-- Lava rivers: neon slivers laid on the facets, one per band per river,
	-- overlapping the band seams so they read as one flow.
	local riverCount = 4
	for river = 0, riverCount - 1 do
		local base = facing
			+ math.pi / 4
			+ river * (math.pi * 2 / riverCount)
			+ rng:NextNumber(-0.2, 0.2)
		for band = bands, 1, -1 do
			local hLow = (band - 1) / bands * RIM_HEIGHT
			local hHigh = band / bands * RIM_HEIGHT
			local rLow = flankRadius(hLow)
			local rHigh = flankRadius(hHigh)
			local angle = base + 0.18 * math.sin(band * 1.3 + river)
			local radial = onBearing(angle, 1)
			local upSlope = (Vector3.yAxis * (hHigh - hLow) - radial * (rLow - rHigh)).Unit
			local pos = centre
				+ radial * ((rLow + rHigh) / 2 + 1.9)
				+ Vector3.new(0, (hLow + hHigh) / 2, 0)
			local slant = math.sqrt((rLow - rHigh) ^ 2 + (hHigh - hLow) ^ 2) + 3.5
			local sliver = newBlock(
				Vector3.new(rng:NextNumber(2.2, 4.2) * (1 + (bands - band) * 0.12), slant, 1),
				CFrame.fromMatrix(pos, tangent(angle), upSlope),
				LAVA,
				Enum.Material.Neon
			)
			sliver.Name = `{name}River{river}_{band}`
			sliver.Transparency = 0.1
			makeInert(sliver)
			if band % 2 == 0 then
				light(sliver, LAVA, 22, 1.5)
			end
			sliver.Parent = kit.decor
		end
	end

	-- Stalactites under the crater floor, so the cave has a ceiling worth
	-- looking up at.
	for index = 1, 10 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local r = rng:NextNumber(6, 30)
		local length = rng:NextNumber(10, 26)
		local tooth = newBlock(
			Vector3.new(rng:NextNumber(3, 6), length, rng:NextNumber(3, 6)),
			CFrame.new(centre + onBearing(angle, r) + Vector3.new(0, floorY - 2 - length / 2, 0))
				* CFrame.Angles(rng:NextNumber(-0.12, 0.12), angle, rng:NextNumber(-0.12, 0.12)),
			BASALT_LOW,
			Enum.Material.Rock
		)
		tooth.Name = `{name}Stalactite{index}`
		tooth.Parent = kit.decor
	end

	buildArchway(kit, centre, facing, name)
	buildChamber(kit, centre, facing, name)
end

--[[ The REGIONS-entry form: `landmark = Worldcraft.volcanoLandmark`. The
	feature lobe is the LAST blob of the region, by contract with landscape. ]]
function Worldcraft.volcanoLandmark(region: RegionLike, kit: Kit)
	local lobe = region.blobs[#region.blobs]
	Worldcraft.buildVolcano(kit, Vector3.new(lobe.center.X, 0, lobe.center.Z))
end

--[[ Boot self-check, in the idiom of `patrols()`: warn, never skip. World
	data is Vector3 and cannot reach the Lune suite, so the checks a pure
	module would get from the suite happen here, once, against the built
	world. Call after the decor folder is parented.

	- The far foot must stand on ground: a mountain hanging off the plate is
	  the first thing the doubling can silently get wrong.
	- Nothing that is not the volcano's may stand inside its foot: the Barrens'
	  blight shards scatter by seeded angle and can land in the hollow.
	- The crown must be placeable: the ray at the centre must hit a part
	  under `kit.ground`, not decor and not the plate. ]]
function Worldcraft.checkVolcano(kit: Kit, centre: Vector3)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {}

	local function hitAt(point: Vector3): RaycastResult?
		return Workspace:Raycast(
			Vector3.new(point.X, 512, point.Z),
			Vector3.new(0, -1024, 0),
			params
		)
	end

	local mouth = Worldcraft.volcanoMouth(centre)
	local farFoot = hitAt(centre + onBearing(mouth + math.pi, FOOT_RADIUS + 4))
	if not farFoot then
		warn(
			"[worldcraft] volcano: the far foot is over open air -- the ground plate does not reach it"
		)
	end

	local crown = hitAt(centre)
	if not crown or not crown.Instance:IsDescendantOf(kit.ground) then
		warn(
			`[worldcraft] volcano: the crown is not placeable -- the ray at the centre hit {if crown
				then crown.Instance:GetFullName()
				else "nothing"}`
		)
	end

	local decorRoot = kit.decor.Parent
	if decorRoot then
		local intruders = 0
		local example = ""
		for _, item in decorRoot:GetDescendants() do
			-- Inlaid floors and rims are inert and lie under the mountain by
			-- design; only something solid counts.
			if
				item:IsA("BasePart")
				and item.CanCollide
				and not (item:IsDescendantOf(kit.decor) or item:IsDescendantOf(kit.ground))
			then
				local dx = item.Position.X - centre.X
				local dz = item.Position.Z - centre.Z
				if dx * dx + dz * dz < FOOT_RADIUS * FOOT_RADIUS then
					intruders += 1
					if example == "" then
						example = item.Name
					end
				end
			end
		end
		if intruders > 0 then
			warn(
				`[worldcraft] volcano: {intruders} foreign parts inside the foot (first: {example})`
			)
		end
	end
end

return Worldcraft
