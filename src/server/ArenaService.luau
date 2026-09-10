--!strict
--[[
	Builds the arena: ground, spawn, the static aura geography, the landmarks
	that make the place navigable by eye, and the sky over all of it.

	Held against the reference bar, every frame has to contain four distinct
	silhouettes between camera and horizon, five materials, a path that curves,
	a saturated palette with nothing left desaturated grey, distant geometry
	tinted blue, and a sky that is a set piece rather than a backdrop. That is
	what the layout below is for, and it is worth saying which piece does which:

	- *Silhouette.* Waymarks at 36 studs, corridor landmarks at 48-84, region
	  landmarks at 60-118, crags at 140-250, and sky islands overhead. Any
	  bearing from the spawn pad crosses at least four of those bands.
	- *Material.* Warm earth underfoot, cobbled roads, sandstone plaza, grass in
	  the Reach, glacier at the Wellspring, basalt in the Barrens, rock and
	  marble and painted timber on the landmarks.
	- *Paths that curve.* Three roads leave the plaza, bow out through the open
	  corridors past a landmark, and bend back into a region gate. A straight
	  line between two points tells the eye nothing; a curve gives it somewhere
	  to go, which is the entire trick.
	- *Depth.* The crags are painted blue-violet and low-contrast on purpose, so
	  distance reads from colour even before the Atmosphere haze applies.

	*Legible terrain.* `Config.StaticRegionMultipliers` is load-bearing -- Ruler
	techniques multiply their damage by the region the caster stands in, and
	cycling rate scales with it too -- so the four regions are four distinct
	floors, and richness reads three ways at once: hue, brightness, and how much
	is built on the ground. The Ember Barrens are dark and cracked and hold
	nothing but broken stone. The open field is the warm-earth commons. The
	Verdant Reach is green, glowing and full of cover. A Wellspring is
	blue-white, spired, and the *smallest* region on the map, so the best ground
	is also the hardest to hold.

	Regions are blobs -- overlapping discs along a spine -- rather than circles.
	That buys an organic outline, three wide open corridors between them for the
	roads and the fights, and an exact point-in-region test that is just a few
	distance comparisons. The rim discs sit a hair below the floor discs, so
	where two lobes overlap the internal rim is buried and only the true outer
	boundary is drawn.

	The layout is seeded, not rolled per server: static aura geography is
	supposed to be learnable, so one seed builds the same arena every run.

	`ArenaService.regionAt` and `ArenaService.landmarkAnchors` are the query side
	of this geography, for whoever owns node placement. Nothing calls them yet --
	NodeService still rolls a node's region at random and scatters positions by
	radius -- but the moment placement reads them, the floor a player is standing
	on and the multiplier on their Ruler technique become the same fact, and
	nodes start appearing at the places worth walking to.

	Skips anything the place already provides: connecting Rojo to a Studio
	Baseplate place is the common case, and duplicating its ground would z-fight.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)

local ArenaService = {}

local GROUND_NAME = "ArenaGround"
local GROUND_THICKNESS = 8
local DECOR_NAME = "ArenaDecor"
local REGION_FOLDER_NAME = "AuraRegions"

--[[ NodeService places nodes within this radius at y = 4, so everything inside
	it stays flat and walkable: floors, roads and patches are inlaid a fraction
	of a stud proud of the ground rather than raised, and nothing is built inside
	the spawn plaza. ]]
local NODE_FIELD_RADIUS = 220
local ARENA_RADIUS = NODE_FIELD_RADIUS + 130
local WALL_RADIUS = 330
local APRON_RADIUS = 430
local PLAZA_RADIUS = 40

-- Heights of the inlaid surfaces, top faces, ground at y = 0.
local RIM_TOP = 0.05
local FLOOR_TOP = 0.12
local PATCH_TOP = 0.2
local ROAD_TOP = 0.3

-- One seed, one arena. See the note about learnable geography above.
local rng = Random.new(20260910)

type Blob = { center: Vector3, radius: number }

type Region = {
	id: string,
	bearing: number,
	blobs: { Blob },
	floor: Color3,
	material: Enum.Material,
	rim: Color3,
	rimGlows: boolean,
	glow: Color3,
}

local function blob(x: number, z: number, radius: number): Blob
	return { center = Vector3.new(x, 0, z), radius = radius }
end

--[[ Three lobes on spines 120 degrees apart, leaving three open corridors for
	the roads. Reward runs inverse to area on purpose: the 2.6x Wellspring is
	the smallest footprint on the map and the 0.5x Barrens the largest. Spawn
	sits in `open` (1.0x) with no region within seventy studs of the pad, so
	there is no such thing as grinding where you respawn. ]]
local REGIONS: { Region } = {
	{
		id = "wellspring",
		bearing = math.pi / 2,
		blobs = { blob(0, 138, 36), blob(0, 172, 44), blob(0, 203, 32) },
		floor = Color3.fromRGB(150, 231, 240),
		material = Enum.Material.Glacier,
		rim = Color3.fromRGB(120, 245, 255),
		rimGlows = true,
		glow = Color3.fromRGB(150, 250, 255),
	},
	{
		id = "rich",
		bearing = math.pi * 7 / 6,
		blobs = {
			blob(-102.2, -59, 44),
			blob(-136.8, -79, 58),
			blob(-171.5, -99, 50),
			blob(-75, -129.9, 40),
		},
		floor = Color3.fromRGB(84, 166, 84),
		material = Enum.Material.Grass,
		rim = Color3.fromRGB(150, 255, 140),
		rimGlows = true,
		glow = Color3.fromRGB(150, 255, 160),
	},
	{
		id = "barren",
		bearing = math.pi * 11 / 6,
		blobs = {
			blob(97, -56, 48),
			blob(134.2, -77.5, 64),
			blob(173.2, -100, 56),
			blob(75, -129.9, 44),
		},
		floor = Color3.fromRGB(58, 46, 44),
		material = Enum.Material.Basalt,
		-- No neon rim. Dead ground announces itself by having nothing to
		-- announce -- but the cracks under it still smoulder, which is what
		-- makes it the Ember Barrens rather than a grey patch.
		rim = Color3.fromRGB(40, 32, 30),
		rimGlows = false,
		glow = Color3.fromRGB(255, 122, 46),
	},
}

-- Warm earth, not grey. This is the largest surface in every frame and it sets
-- the palette everything else is complementary to.
local OPEN_COLOR = Color3.fromRGB(152, 124, 84)
local ROAD_COLOR = Color3.fromRGB(198, 182, 152)
local PLAZA_COLOR = Color3.fromRGB(206, 176, 130)
local STONE_COLOR = Color3.fromRGB(192, 176, 150)
local DARK_STONE = Color3.fromRGB(84, 74, 64)
local TIMBER_COLOR = Color3.fromRGB(198, 74, 46)
local BRAZIER_COLOR = Color3.fromRGB(255, 168, 72)
-- Distance is painted, not only hazed: the crags are blue-violet and sit in a
-- deliberately narrow value range so they read as far away in a still frame.
local CRAG_LOW = Color3.fromRGB(72, 84, 118)
local CRAG_HIGH = Color3.fromRGB(126, 140, 176)

local function hasGround(): boolean
	for _, child in Workspace:GetChildren() do
		if child:IsA("BasePart") and (child.Name == "Baseplate" or child.Name == GROUND_NAME) then
			return true
		end
	end
	return false
end

local function hasSpawn(): boolean
	return Workspace:FindFirstChildWhichIsA("SpawnLocation", true) ~= nil
end

--[[ Wide enough that the whole node field is standable. NodeService places
	nodes within a 220-stud radius of the origin, so ground has to reach past
	that or Prime nodes will spawn over open air. ]]
local function groundSize(): number
	return ARENA_RADIUS * 2
end

local function buildGround()
	local ground = Instance.new("Part")
	ground.Name = GROUND_NAME
	ground.Anchored = true
	ground.Size = Vector3.new(groundSize(), GROUND_THICKNESS, groundSize())
	ground.Position = Vector3.new(0, -GROUND_THICKNESS / 2, 0)
	ground.Material = Enum.Material.Ground
	ground.Color = OPEN_COLOR
	ground.TopSurface = Enum.SurfaceType.Smooth
	ground.BottomSurface = Enum.SurfaceType.Smooth
	ground.Parent = Workspace
end

local function buildSpawn()
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "ArenaSpawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(24, 1, 24)
	spawn.Position = Vector3.new(0, 0.5, 0)
	spawn.Material = Enum.Material.Neon
	spawn.Color = Color3.fromRGB(255, 205, 110)
	spawn.Neutral = true
	-- No spawn forcefield. PvP is the game; an invulnerability window at the
	-- one place everyone returns to would make the spawn a safe grind.
	spawn.Duration = 0
	spawn.Parent = Workspace
end

-- Geometry helpers ----------------------------------------------------------

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

--[[ Inlaid surfaces carry no physics at all. They sit a fraction of a stud
	above the plate and would otherwise catch Striker raycasts fired at a
	target on the ground. ]]
local function makeInert(part: BasePart)
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
end

local function yawAt(angle: number): CFrame
	return CFrame.Angles(0, -angle, 0)
end

local function onBearing(angle: number, distance: number): Vector3
	return Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
end

-- Region floors -------------------------------------------------------------

--[[ Each lobe is a rim disc with a smaller floor disc inlaid on top, so the
	boundary -- the line where a Ruler technique's damage changes by up to 5x --
	is a visible edge rather than an inference. Rims go down first and sit lower
	than every floor, which buries the seams between overlapping lobes. ]]
local function buildRegionFloor(region: Region, decor: Folder, regionFolder: Folder)
	local names = Config.RegionNames :: { [string]: string }
	local multipliers = Config.StaticRegionMultipliers :: { [string]: number }

	for index, lobe in region.blobs do
		local rim = newDisc(
			lobe.radius + 7,
			2,
			lobe.center + Vector3.new(0, RIM_TOP - 1, 0),
			region.rim,
			if region.rimGlows then Enum.Material.Neon else Enum.Material.Basalt
		)
		rim.Name = `{region.id}Rim{index}`
		rim.Transparency = if region.rimGlows then 0.15 else 0
		makeInert(rim)
		rim.Parent = decor
	end

	for index, lobe in region.blobs do
		local floor = newDisc(
			lobe.radius,
			2,
			lobe.center + Vector3.new(0, FLOOR_TOP - 1, 0),
			region.floor,
			region.material
		)
		floor.Name = `{region.id}{index}`
		makeInert(floor)
		floor:SetAttribute("Region", region.id)
		floor:SetAttribute("RegionName", names[region.id])
		floor:SetAttribute("Radius", lobe.radius)
		floor:SetAttribute("Multiplier", multipliers[region.id])
		floor.Parent = regionFolder
	end
end

--[[ A shaft of light over the two regions worth crossing the map for. This is
	the one landmark readable from the far rim of the field, which is what makes
	"go to the Wellspring" a decision a player can act on from anywhere. ]]
local function buildBeacon(region: Region, height: number, decor: Folder)
	local anchor = region.blobs[2].center
	local shaft =
		newDisc(11, height, anchor + Vector3.new(0, height / 2, 0), region.glow, Enum.Material.Neon)
	shaft.Name = `{region.id}Beacon`
	shaft.Transparency = 0.82
	makeInert(shaft)
	shaft.Parent = decor
end

-- Region landmarks ----------------------------------------------------------

--[[ The Wellspring: a spire in a luminous pool, ringed by crystal. At 118 studs
	it clears the grove, the crags behind it and everything else on the map. ]]
local function buildWellspring(region: Region, decor: Folder)
	local heart = region.blobs[2].center

	-- Above the region floor's top face, not level with it.
	local pool = newDisc(27, 1.2, heart + Vector3.new(0, 0.2, 0), region.glow, Enum.Material.Neon)
	pool.Name = "WellspringPool"
	pool.Transparency = 0.45
	makeInert(pool)
	pool.Parent = decor

	local segments = { { 18, 46, 0.0 }, { 13, 40, 0.35 }, { 8.5, 32, 0.7 } }
	local base = 0
	for index, segment in segments do
		local width, height, yaw = segment[1], segment[2], segment[3]
		local block = newBlock(
			Vector3.new(width, height, width),
			CFrame.new(heart + Vector3.new(0, base + height / 2, 0)) * yawAt(yaw),
			STONE_COLOR:Lerp(region.glow, index * 0.14),
			Enum.Material.Marble
		)
		block.Name = `WellspringSpire{index}`
		block.Parent = decor
		base += height
	end

	local tip = newBlock(
		Vector3.new(5, 11, 5),
		CFrame.new(heart + Vector3.new(0, base + 5, 0)) * yawAt(0.7),
		region.glow,
		Enum.Material.Neon
	)
	tip.Name = "WellspringTip"
	tip.CastShadow = false
	tip.Parent = decor

	for index = 1, 6 do
		local angle = (index / 6) * math.pi * 2
		local height = rng:NextNumber(30, 52)
		local offset = onBearing(angle, 38)
		local crystal = newBlock(
			Vector3.new(7, height, 7),
			CFrame.new(heart + offset + Vector3.new(0, height / 2 - 3, 0))
				* yawAt(angle)
				* CFrame.Angles(0.16, 0, 0),
			Color3.fromRGB(176, 236, 244),
			Enum.Material.Glacier
		)
		crystal.Name = `WellspringCrystal{index}`
		crystal.Parent = decor

		local crown = newBlock(
			Vector3.new(4.5, 7, 4.5),
			CFrame.new(heart + offset + Vector3.new(0, height + 1, 0)) * yawAt(angle),
			region.glow,
			Enum.Material.Neon
		)
		crown.Name = `WellspringCrown{index}`
		crown.CastShadow = false
		crown.Parent = decor
	end
end

--[[ The Verdant Reach. Its pillars are the only dense cover on the map, which
	is deliberate: the 1.8x region is where fights should happen, and a fight
	with sightlines to break is a better fight than one on an open plate. ]]
local function buildGrove(region: Region, decor: Folder)
	local index = 0
	for lobeIndex, lobe in region.blobs do
		local count = if lobeIndex == 2 then 5 else 3
		for step = 1, count do
			index += 1
			local angle = (step / count) * math.pi * 2 + lobeIndex
			local dist = lobe.radius * (if step % 2 == 0 then 0.38 else 0.72)
			local height = rng:NextNumber(44, 66)
			local root = lobe.center + onBearing(angle, dist)

			local trunk = newBlock(
				Vector3.new(11, height, 11),
				CFrame.new(root + Vector3.new(0, height / 2, 0)) * yawAt(angle * 1.7),
				Color3.fromRGB(104, 84, 56),
				Enum.Material.Rock
			)
			trunk.Name = `GrovePillar{index}`
			trunk.Parent = decor

			local canopy = newBlock(
				Vector3.new(30, 6, 30),
				CFrame.new(root + Vector3.new(0, height + 3, 0)) * yawAt(angle * 1.7 + 0.5),
				Color3.fromRGB(96, 190, 96),
				Enum.Material.Grass
			)
			canopy.Name = `GroveCanopy{index}`
			canopy.Parent = decor

			local underglow = newBlock(
				Vector3.new(20, 1.4, 20),
				CFrame.new(root + Vector3.new(0, height - 0.6, 0)) * yawAt(angle * 1.7 + 0.5),
				region.glow,
				Enum.Material.Neon
			)
			underglow.Name = `GroveGlow{index}`
			underglow.Transparency = 0.35
			makeInert(underglow)
			underglow.Parent = decor
		end
	end

	-- A gate on the road-facing edge, so the Reach has a front door.
	local mouth = region.blobs[1].center + onBearing(region.bearing + math.pi, 30)
	local side = Vector3.new(-math.sin(region.bearing), 0, math.cos(region.bearing))
	for leg = -1, 1, 2 do
		local post = newBlock(
			Vector3.new(9, 54, 9),
			CFrame.new(mouth + side * (20 * leg) + Vector3.new(0, 27, 0)) * yawAt(region.bearing),
			Color3.fromRGB(126, 118, 92),
			Enum.Material.Rock
		)
		post.Name = `GroveGateLeg{if leg < 0 then "L" else "R"}`
		post.Parent = decor
	end
	local lintel = newBlock(
		Vector3.new(58, 10, 12),
		CFrame.new(mouth + Vector3.new(0, 58, 0)) * yawAt(region.bearing - math.pi / 2),
		Color3.fromRGB(126, 118, 92),
		Enum.Material.Rock
	)
	lintel.Name = "GroveGateLintel"
	lintel.Parent = decor
end

--[[ The Ember Barrens. Everything here is broken, and the only colour is what
	is still burning under the crust: the silhouette says "nothing grows" before
	the player has read a single number, and standing in it halves both their
	cycling rate and their Ruler damage. ]]
local function buildBlight(region: Region, decor: Folder)
	local index = 0
	for _, lobe in region.blobs do
		for _ = 1, 5 do
			index += 1
			local angle = rng:NextNumber(0, math.pi * 2)
			local dist = math.sqrt(rng:NextNumber(0.05, 1)) * (lobe.radius - 10)
			local height = rng:NextNumber(16, 44)
			local width = rng:NextNumber(5, 11)
			local root = lobe.center + onBearing(angle, dist)
			local shard = newBlock(
				Vector3.new(width, height, width * 0.8),
				CFrame.new(root + Vector3.new(0, height / 2 - 2, 0))
					* yawAt(rng:NextNumber(0, math.pi))
					* CFrame.Angles(rng:NextNumber(-0.3, 0.3), 0, rng:NextNumber(-0.3, 0.3)),
				Color3.fromRGB(48, 38, 36):Lerp(Color3.fromRGB(84, 62, 50), rng:NextNumber(0, 1)),
				Enum.Material.Basalt
			)
			shard.Name = `BlightShard{index}`
			shard.Parent = decor
		end

		-- Ember cracks. Thin neon slivers laid into the crust, which is the only
		-- saturated colour the Barrens are allowed.
		for _ = 1, 3 do
			index += 1
			local angle = rng:NextNumber(0, math.pi * 2)
			local dist = rng:NextNumber(0, lobe.radius - 16)
			local crack = newBlock(
				Vector3.new(rng:NextNumber(14, 34), 1, rng:NextNumber(1.6, 3.4)),
				CFrame.new(
					lobe.center + onBearing(angle, dist) + Vector3.new(0, PATCH_TOP - 0.5, 0)
				) * yawAt(rng:NextNumber(0, math.pi)),
				region.glow,
				Enum.Material.Neon
			)
			crack.Name = `EmberCrack{index}`
			crack.Transparency = 0.15
			makeInert(crack)
			crack.Parent = decor
		end
	end

	-- A fallen arch, half-buried, as the Barrens' one real landmark.
	local seat = region.blobs[3].center
	local arch = newBlock(
		Vector3.new(14, 70, 16),
		CFrame.new(seat + Vector3.new(0, 30, 0)) * yawAt(region.bearing) * CFrame.Angles(0, 0, 0.22),
		Color3.fromRGB(72, 60, 56),
		Enum.Material.Rock
	)
	arch.Name = "FallenArch"
	arch.Parent = decor

	local spar = newBlock(
		Vector3.new(13, 46, 15),
		CFrame.new(seat + Vector3.new(30, 12, 8))
			* yawAt(region.bearing + 0.4)
			* CFrame.Angles(0, 0, 1.15),
		Color3.fromRGB(66, 56, 52),
		Enum.Material.Rock
	)
	spar.Name = "FallenArchSpar"
	spar.Parent = decor

	local leaning = region.blobs[1].center
	local obelisk = newBlock(
		Vector3.new(12, 66, 12),
		CFrame.new(leaning + Vector3.new(0, 30, 0)) * yawAt(0.6) * CFrame.Angles(0.16, 0, 0.1),
		Color3.fromRGB(58, 50, 48),
		Enum.Material.Slate
	)
	obelisk.Name = "BarrenObelisk"
	obelisk.Parent = decor
end

-- Open ground ---------------------------------------------------------------

--[[ The commons are not allowed to be one flat colour either. Cobble aprons,
	dirt scars and grass tufts break the open field up so that any shot of it
	carries three or four materials on its own. ]]
local function buildOpenGround(decor: Folder)
	for index = 1, 16 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local dist = rng:NextNumber(PLAZA_RADIUS + 20, NODE_FIELD_RADIUS - 10)
		local center = onBearing(angle, dist) + Vector3.new(0, PATCH_TOP - 1, 0)
		local kind = index % 3
		local patch = newDisc(
			rng:NextNumber(14, 34),
			2,
			center,
			if kind == 0
				then Color3.fromRGB(176, 158, 126)
				elseif kind == 1 then Color3.fromRGB(112, 88, 58)
				else Color3.fromRGB(126, 156, 88),
			if kind == 0
				then Enum.Material.Cobblestone
				elseif kind == 1 then Enum.Material.Mud
				else Enum.Material.LeafyGrass
		)
		patch.Name = `GroundPatch{index}`
		makeInert(patch)
		patch.Parent = decor
	end
end

local function bezier(p0: Vector3, p1: Vector3, p2: Vector3, t: number): Vector3
	return p0:Lerp(p1, t):Lerp(p1:Lerp(p2, t), t)
end

--[[ A road from the plaza to each region gate, bowed out through the open
	corridor so it passes a landmark on the way. The bow is the point: a
	straight line is a measurement, a curve is an invitation. Lanterns every few
	segments carry the road after dark and add another silhouette band. ]]
local function buildRoad(region: Region, bow: number, decor: Folder)
	local segments = 17
	local start = onBearing(region.bearing, PLAZA_RADIUS + 6)
	local finish = region.blobs[1].center
	local control = onBearing(region.bearing + bow, 130)

	local previous = start
	for step = 0, segments do
		local t = step / segments
		local point = bezier(start, control, finish, t)
		local ahead = bezier(start, control, finish, math.min(t + 0.02, 1))
		if (ahead - point).Magnitude < 0.05 then
			ahead = point + (point - previous)
		end

		local slab = newBlock(
			Vector3.new(rng:NextNumber(13, 16), 1, 15),
			CFrame.lookAt(
				point + Vector3.new(0, ROAD_TOP - 0.5, 0),
				Vector3.new(ahead.X, ROAD_TOP - 0.5, ahead.Z)
			),
			ROAD_COLOR:Lerp(Color3.fromRGB(150, 134, 106), rng:NextNumber(0, 0.5)),
			Enum.Material.Cobblestone
		)
		slab.Name = `Road_{region.id}_{step}`
		makeInert(slab)
		slab.Parent = decor

		if step % 5 == 2 then
			local side = (ahead - point).Unit:Cross(Vector3.yAxis).Unit
			for lamp = -1, 1, 2 do
				local base = point + side * (13 * lamp)
				local post = newBlock(
					Vector3.new(2.6, 16, 2.6),
					CFrame.new(base + Vector3.new(0, 8, 0)),
					DARK_STONE,
					Enum.Material.Rock
				)
				post.Name = `RoadLamp_{region.id}_{step}_{lamp}`
				post.Parent = decor

				local flame = newBlock(
					Vector3.new(4, 4, 4),
					CFrame.new(base + Vector3.new(0, 17.5, 0)) * CFrame.Angles(0.6, 0.6, 0),
					BRAZIER_COLOR,
					Enum.Material.Neon
				)
				flame.Name = `RoadFlame_{region.id}_{step}_{lamp}`
				flame.CastShadow = false
				flame.Parent = decor
			end
		end
		previous = point
	end
end

-- Corridor landmarks --------------------------------------------------------

--[[ One landmark per open corridor, so the three bearings that are *not* a
	region still have something to walk toward and something to hide behind.
	Heights are staggered on purpose -- 48, 60 and 84 -- so the skyline between
	the regions is not a flat band. ]]
local function buildWatchtower(base: Vector3, decor: Folder)
	local bands = { { 22, 30 }, { 18, 26 }, { 14, 20 } }
	local height = 0
	for index, band in bands do
		local width, tall = band[1], band[2]
		local drum = newBlock(
			Vector3.new(width, tall, width),
			CFrame.new(base + Vector3.new(0, height + tall / 2, 0)) * yawAt(index * 0.4),
			STONE_COLOR:Lerp(DARK_STONE, index * 0.18),
			Enum.Material.Rock
		)
		drum.Name = `WatchtowerDrum{index}`
		drum.Parent = decor

		local ring = newBlock(
			Vector3.new(width + 4, 3, width + 4),
			CFrame.new(base + Vector3.new(0, height + tall, 0)) * yawAt(index * 0.4),
			TIMBER_COLOR,
			Enum.Material.Slate
		)
		ring.Name = `WatchtowerRing{index}`
		ring.Parent = decor
		height += tall
	end

	local brazier = newBlock(
		Vector3.new(9, 8, 9),
		CFrame.new(base + Vector3.new(0, height + 4, 0)) * yawAt(0.8),
		BRAZIER_COLOR,
		Enum.Material.Neon
	)
	brazier.Name = "WatchtowerBrazier"
	brazier.CastShadow = false
	brazier.Parent = decor
end

local function buildAqueduct(center: Vector3, bearing: number, decor: Folder)
	local span = Vector3.new(-math.sin(bearing), 0, math.cos(bearing))
	for index = -1, 1 do
		local pier = newBlock(
			Vector3.new(13, 40, 13),
			CFrame.new(center + span * (index * 40) + Vector3.new(0, 20, 0)) * yawAt(bearing),
			STONE_COLOR:Lerp(DARK_STONE, 0.3),
			Enum.Material.Rock
		)
		pier.Name = `AqueductPier{index + 2}`
		pier.Parent = decor

		local arch = newBlock(
			Vector3.new(8, 14, 11),
			CFrame.new(center + span * (index * 40 + 20) + Vector3.new(0, 33, 0)) * yawAt(bearing),
			STONE_COLOR:Lerp(DARK_STONE, 0.45),
			Enum.Material.Rock
		)
		arch.Name = `AqueductArch{index + 2}`
		arch.Parent = decor
	end

	local channel = newBlock(
		Vector3.new(130, 8, 16),
		CFrame.new(center + Vector3.new(0, 44, 0)) * yawAt(bearing - math.pi / 2),
		STONE_COLOR,
		Enum.Material.Rock
	)
	channel.Name = "AqueductChannel"
	channel.Parent = decor

	local water = newBlock(
		Vector3.new(126, 1.5, 9),
		CFrame.new(center + Vector3.new(0, 48.4, 0)) * yawAt(bearing - math.pi / 2),
		Color3.fromRGB(96, 206, 226),
		Enum.Material.Neon
	)
	water.Name = "AqueductWater"
	water.Transparency = 0.35
	makeInert(water)
	water.Parent = decor
end

local function buildTorii(base: Vector3, bearing: number, decor: Folder)
	local side = Vector3.new(-math.sin(bearing), 0, math.cos(bearing))
	for leg = -1, 1, 2 do
		local post = newBlock(
			Vector3.new(7, 52, 7),
			CFrame.new(base + side * (22 * leg) + Vector3.new(0, 26, 0)) * yawAt(bearing),
			TIMBER_COLOR,
			Enum.Material.WoodPlanks
		)
		post.Name = `ToriiPost{if leg < 0 then "L" else "R"}`
		post.Parent = decor
	end

	local tie = newBlock(
		Vector3.new(52, 5, 8),
		CFrame.new(base + Vector3.new(0, 42, 0)) * yawAt(bearing - math.pi / 2),
		TIMBER_COLOR,
		Enum.Material.WoodPlanks
	)
	tie.Name = "ToriiTie"
	tie.Parent = decor

	local cap = newBlock(
		Vector3.new(68, 6, 12),
		CFrame.new(base + Vector3.new(0, 55, 0))
			* yawAt(bearing - math.pi / 2)
			* CFrame.Angles(0.06, 0, 0),
		Color3.fromRGB(46, 38, 36),
		Enum.Material.WoodPlanks
	)
	cap.Name = "ToriiCap"
	cap.Parent = decor
end

local function buildStandingStones(center: Vector3, decor: Folder)
	for index = 1, 9 do
		local angle = (index / 9) * math.pi * 2
		local height = rng:NextNumber(30, 44)
		local stone = newBlock(
			Vector3.new(8, height, 5),
			CFrame.new(center + onBearing(angle, 34) + Vector3.new(0, height / 2 - 2, 0))
				* yawAt(angle)
				* CFrame.Angles(rng:NextNumber(-0.08, 0.08), 0, rng:NextNumber(-0.1, 0.1)),
			DARK_STONE:Lerp(STONE_COLOR, rng:NextNumber(0.2, 0.7)),
			Enum.Material.Slate
		)
		stone.Name = `StandingStone{index}`
		stone.Parent = decor
	end

	local altar = newDisc(
		16,
		3,
		center + Vector3.new(0, 1, 0),
		Color3.fromRGB(168, 150, 122),
		Enum.Material.Marble
	)
	altar.Name = "StoneCircleAltar"
	altar.CanQuery = false
	altar.CastShadow = false
	altar.Parent = decor
end

-- Sky -----------------------------------------------------------------------

--[[ Islands overhead. The horizon line is only half the skyline: without
	something *above* it the sky is a flat gradient, and a flat gradient is the
	single loudest tell that a place was built in an afternoon. ]]
local function buildSkyIslands(decor: Folder)
	local plan = {
		{ bearing = 0.6, dist = 250, height = 210, scale = 1.0 },
		{ bearing = 2.4, dist = 300, height = 260, scale = 1.4 },
		{ bearing = 3.9, dist = 220, height = 190, scale = 0.8 },
		{ bearing = 5.4, dist = 330, height = 240, scale = 1.2 },
	}
	for index, island in plan do
		local base = onBearing(island.bearing, island.dist) + Vector3.new(0, island.height, 0)
		local width = 46 * island.scale

		local slab = newBlock(
			Vector3.new(width, 14, width * 0.8),
			CFrame.new(base) * yawAt(island.bearing),
			Color3.fromRGB(120, 100, 74),
			Enum.Material.Rock
		)
		slab.Name = `SkyIsland{index}`
		slab.CanCollide = false
		slab.CastShadow = false
		slab.Parent = decor

		local turf = newBlock(
			Vector3.new(width * 0.94, 5, width * 0.74),
			CFrame.new(base + Vector3.new(0, 8, 0)) * yawAt(island.bearing),
			Color3.fromRGB(96, 178, 96),
			Enum.Material.Grass
		)
		turf.Name = `SkyIslandTurf{index}`
		turf.CanCollide = false
		turf.CastShadow = false
		turf.Parent = decor

		local keel = newBlock(
			Vector3.new(width * 0.5, 26, width * 0.4),
			CFrame.new(base + Vector3.new(0, -16, 0)) * yawAt(island.bearing + 0.5),
			Color3.fromRGB(96, 80, 62),
			Enum.Material.Rock
		)
		keel.Name = `SkyIslandKeel{index}`
		keel.CanCollide = false
		keel.CastShadow = false
		keel.Parent = decor
	end
end

-- Spawn ---------------------------------------------------------------------

--[[ Spawn ring plus one waymarker per region, each tipped in that region's own
	colour, standing on its bearing, and captioned with the name the
	announcements use. From the pad you can see which way the Reach is and which
	way the Barrens are, and the sign tells you what to call it when a Prime
	surfaces there. ]]
local function buildSpawnRing(decor: Folder)
	local names = Config.RegionNames :: { [string]: string }

	local plaza = newDisc(
		PLAZA_RADIUS,
		2,
		Vector3.new(0, PATCH_TOP - 1, 0),
		PLAZA_COLOR,
		Enum.Material.Sandstone
	)
	plaza.Name = "SpawnPlaza"
	makeInert(plaza)
	plaza.Parent = decor

	local inlay = newDisc(
		PLAZA_RADIUS - 12,
		2,
		Vector3.new(0, PATCH_TOP - 0.94, 0),
		Color3.fromRGB(226, 198, 148),
		Enum.Material.Marble
	)
	inlay.Name = "SpawnInlay"
	makeInert(inlay)
	inlay.Parent = decor

	for index = 1, 8 do
		local angle = (index / 8) * math.pi * 2 + math.pi / 8
		local offset = onBearing(angle, PLAZA_RADIUS - 5)
		local post = newBlock(
			Vector3.new(6, 15, 6),
			CFrame.new(offset + Vector3.new(0, 7.5, 0)) * yawAt(angle),
			STONE_COLOR,
			Enum.Material.Sandstone
		)
		post.Name = `SpawnPost{index}`
		post.Parent = decor

		local cap = newBlock(
			Vector3.new(7.5, 2.4, 7.5),
			CFrame.new(offset + Vector3.new(0, 16.2, 0)) * yawAt(angle),
			Color3.fromRGB(255, 205, 110),
			Enum.Material.Neon
		)
		cap.Name = `SpawnPostCap{index}`
		cap.CastShadow = false
		cap.Parent = decor
	end

	for _, region in REGIONS do
		local offset = onBearing(region.bearing, PLAZA_RADIUS + 24)
		local pillar = newBlock(
			Vector3.new(7, 36, 7),
			CFrame.new(offset + Vector3.new(0, 18, 0)) * yawAt(region.bearing),
			DARK_STONE:Lerp(STONE_COLOR, 0.5),
			Enum.Material.Slate
		)
		pillar.Name = `Waymark_{region.id}`
		pillar.Parent = decor

		local band = newBlock(
			Vector3.new(9, 5, 9),
			CFrame.new(offset + Vector3.new(0, 38, 0)) * yawAt(region.bearing + 0.4),
			region.glow,
			Enum.Material.Neon
		)
		band.Name = `WaymarkBand_{region.id}`
		band.CastShadow = false
		band.Parent = decor

		-- A finger of stone leaning the way the region lies.
		local finger = newBlock(
			Vector3.new(4, 16, 4),
			CFrame.new(offset + onBearing(region.bearing, 6) + Vector3.new(0, 44, 0))
				* yawAt(region.bearing)
				* CFrame.Angles(0.55, 0, 0),
			DARK_STONE:Lerp(STONE_COLOR, 0.5),
			Enum.Material.Slate
		)
		finger.Name = `WaymarkFinger_{region.id}`
		finger.Parent = decor

		-- World-space signage, sized to be read on a phone.
		local sign = Instance.new("BillboardGui")
		sign.Name = "WaymarkSign"
		sign.Size = UDim2.fromOffset(320, 56)
		sign.StudsOffsetWorldSpace = Vector3.new(0, 12, 0)
		sign.AlwaysOnTop = false
		sign.MaxDistance = 340
		sign.Parent = pillar

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Enum.Font.GothamBold
		label.TextScaled = true
		label.TextColor3 = region.glow
		label.Text = names[region.id]
		label.Parent = sign

		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 3
		stroke.Color = Color3.fromRGB(12, 10, 10)
		stroke.Parent = label
	end
end

--[[ The horizon. Three stacked, shrinking, differently yawed blocks read as a
	crag once they are three hundred studs out and sitting in haze, and twenty
	of them close the skyline in every direction -- which is the whole point. A
	player who can see where they are not allowed to go knows where they are. ]]
local function buildWall(decor: Folder)
	local apron = newDisc(
		APRON_RADIUS,
		30,
		Vector3.new(0, -15.6, 0),
		Color3.fromRGB(104, 88, 64),
		Enum.Material.Ground
	)
	apron.Name = "ArenaApron"
	apron.CastShadow = false
	apron.CanQuery = false
	apron.Parent = decor

	for index = 1, 20 do
		local angle = (index / 20) * math.pi * 2
		local dist = WALL_RADIUS + rng:NextNumber(-28, 42)
		local height = rng:NextNumber(140, 250)
		local width = rng:NextNumber(120, 190)
		local root = onBearing(angle, dist)
		local yaw = angle + rng:NextNumber(-0.5, 0.5)

		local massif = newBlock(
			Vector3.new(width, height, width * 0.72),
			CFrame.new(root + Vector3.new(0, height / 2 - 34, 0)) * yawAt(yaw),
			CRAG_LOW:Lerp(CRAG_HIGH, rng:NextNumber(0, 0.3)),
			Enum.Material.Slate
		)
		massif.Name = `Crag{index}A`
		massif.CastShadow = false
		massif.Parent = decor

		local shoulder = newBlock(
			Vector3.new(width * 0.64, height * 0.58, width * 0.5),
			CFrame.new(root + Vector3.new(0, height * 0.76, 0))
				* yawAt(yaw + 0.7)
				* CFrame.Angles(rng:NextNumber(-0.1, 0.1), 0, rng:NextNumber(-0.1, 0.1)),
			CRAG_LOW:Lerp(CRAG_HIGH, rng:NextNumber(0.25, 0.6)),
			Enum.Material.Rock
		)
		shoulder.Name = `Crag{index}B`
		shoulder.CastShadow = false
		shoulder.Parent = decor

		local peak = newBlock(
			Vector3.new(width * 0.34, height * 0.44, width * 0.3),
			CFrame.new(root + Vector3.new(0, height * 1.06, 0))
				* yawAt(yaw + 1.3)
				* CFrame.Angles(rng:NextNumber(-0.14, 0.14), 0, rng:NextNumber(-0.14, 0.14)),
			CRAG_LOW:Lerp(CRAG_HIGH, rng:NextNumber(0.55, 1)),
			Enum.Material.Rock
		)
		peak.Name = `Crag{index}C`
		peak.CastShadow = false
		peak.Parent = decor
	end
end

--[[ Haze is what turns twenty blue blocks into a distant range: without depth
	falloff the crags read as flat cutouts pasted on the skybox. Clouds put
	something in the upper half of the frame, bloom is what makes every neon
	rim, ember and beacon actually glow rather than just being bright, and the
	grade pushes saturation because a desaturated frame is the tell.

	Each piece is skipped if the place already has one, on the same principle as
	the ground: a place that brought its own art keeps it. ]]
local function buildAtmosphere()
	if not Lighting:FindFirstChildOfClass("Atmosphere") then
		local atmosphere = Instance.new("Atmosphere")
		atmosphere.Density = 0.35
		atmosphere.Offset = 0.15
		atmosphere.Color = Color3.fromRGB(206, 214, 232)
		atmosphere.Decay = Color3.fromRGB(96, 112, 150)
		atmosphere.Glare = 0.25
		atmosphere.Haze = 2.2
		atmosphere.Parent = Lighting

		Lighting.ClockTime = 15.4
		Lighting.GeographicLatitude = 24
		Lighting.Brightness = 2.6
		Lighting.Ambient = Color3.fromRGB(78, 76, 92)
		Lighting.OutdoorAmbient = Color3.fromRGB(136, 138, 156)
	end

	if not Lighting:FindFirstChildOfClass("BloomEffect") then
		local bloom = Instance.new("BloomEffect")
		bloom.Intensity = 0.7
		bloom.Size = 26
		bloom.Threshold = 1.35
		bloom.Parent = Lighting
	end

	if not Lighting:FindFirstChildOfClass("SunRaysEffect") then
		local rays = Instance.new("SunRaysEffect")
		rays.Intensity = 0.06
		rays.Spread = 0.9
		rays.Parent = Lighting
	end

	if not Lighting:FindFirstChildOfClass("ColorCorrectionEffect") then
		local grade = Instance.new("ColorCorrectionEffect")
		grade.Saturation = 0.14
		grade.Contrast = 0.06
		grade.Brightness = 0.01
		grade.TintColor = Color3.fromRGB(255, 250, 242)
		grade.Parent = Lighting
	end

	--[[ Clouds are the one part of the sky that can be built without shipping a
		skybox texture, and they do most of the work: a moving, lit layer above
		the crags. The stock skybox is still the stock skybox and remains the
		last unfinished thing about this view. ]]
	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	if terrain and not terrain:FindFirstChildOfClass("Clouds") then
		local clouds = Instance.new("Clouds")
		clouds.Cover = 0.62
		clouds.Density = 0.55
		clouds.Color = Color3.fromRGB(240, 240, 246)
		clouds.Parent = terrain
	end
end

-- Public --------------------------------------------------------------------

--[[ Which static region a point stands in. Regions are unions of discs and do
	not overlap, so the first lobe that contains the point is the answer.

	This is the geography Config.StaticRegionMultipliers prices. Once NodeService
	reads it instead of rolling `regions[math.random(1, #regions)]`, the floor a
	player is standing on and the multiplier on their Ruler technique become the
	same fact, and the terrain stops lying. ]]
function ArenaService.regionAt(position: Vector3): string
	for _, region in REGIONS do
		for _, lobe in region.blobs do
			local dx = position.X - lobe.center.X
			local dz = position.Z - lobe.center.Z
			if dx * dx + dz * dz <= lobe.radius * lobe.radius then
				return region.id
			end
		end
	end
	return "open"
end

export type Anchor = {
	name: string,
	position: Vector3,
	region: string,
	radius: number,
}

--[[ The places worth walking to, for whoever owns node placement.

	The design's pitch is that aura geography matters -- that nodes sit where
	something is. Scattering them by radius over a disc is the one thing that
	makes that claim false, because it puts as many nodes on empty ground as at
	the Wellspring. Placing inside these anchors instead, with `radius` as the
	scatter around each, ties the field to the map. ]]
function ArenaService.landmarkAnchors(): { Anchor }
	local anchors: { Anchor } = {}
	for _, region in REGIONS do
		for index, lobe in region.blobs do
			table.insert(anchors, {
				name = `{region.id}_lobe{index}`,
				position = lobe.center,
				region = region.id,
				radius = lobe.radius * 0.7,
			})
		end
	end
	table.insert(anchors, {
		name = "watchtower",
		position = onBearing(math.pi / 6, 132),
		region = "open",
		radius = 40,
	})
	table.insert(anchors, {
		name = "aqueduct",
		position = onBearing(math.pi * 5 / 6, 144),
		region = "open",
		radius = 44,
	})
	table.insert(anchors, {
		name = "stone_circle",
		position = onBearing(math.pi / 6, 198),
		region = "open",
		radius = 36,
	})
	table.insert(anchors, {
		name = "torii",
		position = onBearing(math.pi * 3 / 2, 118),
		region = "open",
		radius = 38,
	})
	return anchors
end

--[[ Centres and radii of the static regions, for anything that wants to place
	something *in* one rather than ask what it is standing on. ]]
function ArenaService.regions(): { { id: string, center: Vector3, radius: number } }
	local out = {}
	for _, region in REGIONS do
		local lobe = region.blobs[math.max(1, math.floor(#region.blobs / 2))]
		table.insert(out, { id = region.id, center = lobe.center, radius = lobe.radius })
	end
	return out
end

function ArenaService.start()
	if not hasGround() then
		buildGround()
	end
	if not hasSpawn() then
		buildSpawn()
	end

	-- Deliberately not setting Workspace.FallenPartsDestroyHeight: it carries the
	-- Plugin capability and a game script writing it throws, which took down the
	-- whole server bootstrap on the first Studio run. The engine default already
	-- destroys fallen parts, and falling kills the character, which is all the
	-- death handler needs.

	if not Workspace:FindFirstChild(DECOR_NAME) then
		local decor = Instance.new("Folder")
		decor.Name = DECOR_NAME

		local regionFolder = Instance.new("Folder")
		regionFolder.Name = REGION_FOLDER_NAME
		regionFolder.Parent = decor

		buildWall(decor)
		buildOpenGround(decor)
		for _, region in REGIONS do
			buildRegionFloor(region, decor, regionFolder)
		end
		buildWellspring(REGIONS[1], decor)
		buildGrove(REGIONS[2], decor)
		buildBlight(REGIONS[3], decor)
		buildBeacon(REGIONS[1], 460, decor)
		buildBeacon(REGIONS[2], 240, decor)

		--[[ Roads bow away from their bearing, each into a different open
			corridor, so all three corridors carry one and each road passes a
			landmark on the way out: the Wellspring road runs by the aqueduct,
			the Reach road by the torii, the Barrens road by the watchtower. ]]
		buildRoad(REGIONS[1], 0.62, decor)
		buildRoad(REGIONS[2], 0.7, decor)
		buildRoad(REGIONS[3], 0.66, decor)

		buildWatchtower(onBearing(math.pi / 6, 132), decor)
		buildAqueduct(onBearing(math.pi * 5 / 6, 144), math.pi * 5 / 6, decor)
		buildStandingStones(onBearing(math.pi / 6, 198), decor)
		buildTorii(onBearing(math.pi * 3 / 2, 118), math.pi * 3 / 2, decor)
		buildSkyIslands(decor)
		buildSpawnRing(decor)

		decor.Parent = Workspace
	end

	-- Last, and guarded. Geometry is the job; a lighting property that turns out
	-- to be unwritable must not cost the arena the way one already cost the
	-- server bootstrap.
	--
	-- pcall's result arity follows its callee, and this one returns nothing, so
	-- the error value has to be asked for explicitly. Same shape as the boot
	-- sequence's startService.
	local protectedAtmosphere = buildAtmosphere :: () -> any
	local ok, err = pcall(protectedAtmosphere)
	if not ok then
		warn(`[arena] atmosphere skipped: {err}`)
	end

	local multipliers = Config.StaticRegionMultipliers :: { [string]: number }
	print(
		`[arena] ready -- {#Config.Stages} stages, ground {groundSize()} studs, `
			.. `regions barren {multipliers.barren}x / open {multipliers.open}x / `
			.. `rich {multipliers.rich}x / wellspring {multipliers.wellspring}x`
	)
end

return ArenaService
