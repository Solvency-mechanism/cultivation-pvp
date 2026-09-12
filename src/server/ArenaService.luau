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
	  landmarks at 60-118, crags at 55-250, and sky islands overhead. Any
	  bearing from the terrace crosses at least four of those bands.
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

	*The establishing shot.* None of the above counted for anything while spawn
	sat at the origin inside a ring of eight fifteen-stud posts: the captured
	frames contained the posts, the plaza and nothing else -- no landmark, no
	region, no node, no sky. Spawn is now a deck on the southern rim at
	(0, 22, -150), facing north across the whole map, and the posts are gone.

	Worked from the default follow camera -- eye about 13 studs back and 2 up,
	pitched 8.7 degrees down, 70-degree FOV, so the frame spans -43.7 to +26.3
	degrees vertically and +-51 horizontally -- the first frame of the game
	contains, measured:

	    crossroads monument    149 studs   dead ahead, +5.0 deg
	    Verdant Reach edge     107 studs   32.9 deg left
	    Ember Barrens edge     105 studs   27.8 deg right
	    torii                   76 studs   30.7 deg left, +18.8 deg
	    watchtower             244 studs   28.0 deg right, +12.7 deg
	    Wellspring floor       287 studs   dead ahead
	    Wellspring spire       321 studs   dead ahead, +17.3 deg
	    Wellspring beacon      321 studs   dead ahead, +53 deg, out the top
	    horizon (crag saddle)  ~500 studs  +4.1 deg centre, +18.1 at the edges

	which leaves 16 to 22 degrees of open sky across the middle of the frame --
	the top quarter of the image -- and puts two region edges, five landmarks and
	the sky in the player's first second. The saddle in the crag ring is what
	buys the sky; the deck height is what stops the ground plane eating the
	frame; and the pad sitting at the deck's *northern* edge is what keeps the
	terrace's own furniture behind the camera instead of in it.

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
local VolcanoWorld = require(script.Parent.VolcanoWorld)
local Worldcraft = require(script.Parent.Worldcraft)

local ArenaService = {}

local GROUND_NAME = "ArenaGround"
local GROUND_THICKNESS = 8
local DECOR_NAME = "ArenaDecor"
local REGION_FOLDER_NAME = "AuraRegions"

--[[ The inner field: everything inside this radius stays flat and walkable, so
	floors, roads and patches are inlaid a fraction of a stud proud of the ground
	rather than raised.

	This used to double as the node spawn radius, and the two facts drifted apart:
	NodeService scattered nodes over a disc of exactly this size while region
	lobes reached out to 256, so the outer thirds of the Reach, the Barrens and
	the Wellspring could never hold a node. Placement is now driven by
	`landmarkAnchors` rather than by a disc, so this number sizes the *ground*
	and nothing else, and the mismatch is gone rather than papered over. ]]
local NODE_FIELD_RADIUS = 220
local ARENA_RADIUS = NODE_FIELD_RADIUS + 130
local WALL_RADIUS = 330
local APRON_RADIUS = 540
local PLAZA_RADIUS = 40

--[[ The spawn terrace, and the reason it is not the middle of the map.

	A world was built and then hidden: spawn sat at the origin inside a ring of
	eight fifteen-stud posts, and from the one position every player starts and
	returns to, not a single landmark, region, beacon, node or piece of sky was
	in frame. The posts are gone, and spawn now stands on a deck on the southern
	rim, twenty-two studs up, facing in.

	Every number here is a sightline. The deck is high enough that the ground
	plane falls away instead of filling the screen, the pad sits at the deck's
	*northern* edge so the terrace furniture is all behind the camera, and there
	is deliberately nothing tall on the axis between the pad and the Wellspring
	three hundred studs out -- which is what leaves the top of the frame for the
	sky the Atmosphere was built for. ]]
local TERRACE_CENTER = Vector3.new(0, 0, -150)
local DECK_RADIUS = 26
local DECK_TOP = 22
local SPAWN_POINT = Vector3.new(0, DECK_TOP + 0.5, -136)
local RAMP_HIGH_Z = -124
local RAMP_LOW_Z = -78

--[[ The torii used to stand at 270 degrees, dead on the spawn axis, where it
	would have filled the middle of the establishing shot with a crossbeam. It
	now stands thirty degrees off to the left, close enough to frame the view
	and nowhere near blocking it. ]]
local TORII_POINT = Vector3.new(-38.9, 0, -83.4)

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
	the smallest footprint on the map and the 0.5x Barrens the largest.

	Spawn sits in `open` (1.0x). This comment used to claim "no region within
	seventy studs of the pad"; that was measured wrong. The nearest region edge
	is the `barren` lobe at (75, -129.9) r44, which is **31 studs** from
	SPAWN_POINT (0, -136) -- and from the bottom of the ramp it is 47. That is
	still far enough that nobody grinds where they respawn, and barren is the
	0.5x floor so standing there is a punishment rather than a shortcut, but the
	number in the prose was false and something would eventually have been built
	on it. ]]
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
	spawn.Size = Vector3.new(26, 1, 20)
	--[[ Facing matters as much as position. A character spawns looking along its
		SpawnLocation's LookVector, so pointing this north is what decides whether
		the first second of the game is the arena or the back of a wall. ]]
	spawn.CFrame = CFrame.lookAt(SPAWN_POINT, SPAWN_POINT + Vector3.zAxis)
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
	shaft.Transparency = 0.74
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

--[[ A road, laid as a bezier so it arrives curved. The bow is the point: a
	straight line is a measurement, a curve is an invitation. Lanterns every few
	segments carry the road after dark and add another silhouette band. ]]
local function buildRoad(
	name: string,
	start: Vector3,
	control: Vector3,
	finish: Vector3,
	segments: number,
	decor: Folder
)
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
		slab.Name = `Road_{name}_{step}`
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
				post.Name = `RoadLamp_{name}_{step}_{lamp}`
				post.Parent = decor

				local flame = newBlock(
					Vector3.new(4, 4, 4),
					CFrame.new(base + Vector3.new(0, 17.5, 0)) * CFrame.Angles(0.6, 0.6, 0),
					BRAZIER_COLOR,
					Enum.Material.Neon
				)
				flame.Name = `RoadFlame_{name}_{step}_{lamp}`
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
	colour. From the terrace this is the first structure on the axis, and walking
	into it tells you which way the Reach is and which way the Barrens are. The
	*names* live on the roadside signs at each region's threshold, not here --
	three captioned pillars clustered at one hub is how you get three captions
	in one frame.

	It used to be the spawn, ringed by eight fifteen-stud posts at eye height.
	Nothing here is taller than the waymarks now, and the waymarks stand outside
	the ring rather than around it, because the whole job of this place is to be
	looked *through*. ]]
local function buildCrossroads(decor: Folder)
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

	--[[ A compass rose inlaid in the floor instead of a picket of posts. It
		carries the same information -- which bearing goes where -- at zero cost
		to the sightline, because it is painted on the ground the player is
		standing on rather than standing between them and the map. ]]
	for _, region in REGIONS do
		for step = 1, 4 do
			local reach = PLAZA_RADIUS - 6
			local length = reach * (0.34 + step * 0.16)
			local spoke = newBlock(
				Vector3.new(length, 1, 3.4 - step * 0.5),
				CFrame.new(
					onBearing(region.bearing, length / 2 + 3) + Vector3.new(0, PATCH_TOP - 0.88, 0)
				) * yawAt(region.bearing),
				region.glow,
				Enum.Material.Neon
			)
			spoke.Name = `CompassSpoke_{region.id}_{step}`
			spoke.Transparency = 0.2 + step * 0.12
			makeInert(spoke)
			spoke.Parent = decor
		end
	end

	--[[ One vertical at the crossroads, and only one: forty studs of stone at a
		hundred and thirty from the terrace, which is five degrees of the frame.
		Enough to be the thing you say "meet me at" and far too small to hide the
		map behind. ]]
	local shaftHeight = 34
	local monument = newBlock(
		Vector3.new(9, shaftHeight, 9),
		CFrame.new(0, shaftHeight / 2, 0) * yawAt(0.4),
		STONE_COLOR,
		Enum.Material.Marble
	)
	monument.Name = "CrossroadsMonument"
	monument.Parent = decor

	local crown = newBlock(
		Vector3.new(6, 8, 6),
		CFrame.new(0, shaftHeight + 3, 0) * yawAt(0.9),
		Color3.fromRGB(255, 205, 110),
		Enum.Material.Neon
	)
	crown.Name = "CrossroadsCrown"
	crown.CastShadow = false
	crown.Parent = decor

	for _, region in REGIONS do
		local offset = onBearing(region.bearing, PLAZA_RADIUS + 30)
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
	end
end

--[[ A roadside sign at each region's threshold, and the post-mortem on the
	banners it replaces.

	The names were `BillboardGui`s on the three crossroads pillars, sized with
	`UDim2.fromOffset(320, 56)`. That is 320 by 56 *pixels*, held constant at
	every distance -- a billboard's Offset size does not shrink as you walk away
	from it. So three captions each a sixth of the screen wide hung in the middle
	of the frame at any range, overlapped each other into
	"e Emb r Barrens W ll p the Verd ch", and drew over the AURA SENSE panel.
	Round 1's finding was that a broken string reads as unfinished more loudly
	than placeholder geometry does. That was the same failure, in 96-point type.

	These are `SurfaceGui`s on real boards instead, and the difference is not a
	tuning pass -- it is a different class of object. A SurfaceGui is a texture on
	a surface: it is measured in studs, so it shrinks with distance like every
	other thing in the world; it is depth-tested, so geometry occludes it; and it
	renders in the 3D scene, so it cannot land on top of a ScreenGui. There is no
	setting on it that can reproduce the failure above.

	Placement and range do the rest, and both are arithmetic rather than hope:

	- One sign per region, standing just *outside* that region's near rim on its
	  own bearing, thirteen studs to the side of the road. The closest pair are
	  109 studs apart, so any viewer near enough to render both is standing
	  between them and sees them 105 to 161 degrees apart -- opposite sides of
	  the screen, never the same part of it.
	- `MaxDistance` is 80, and at 80 studs the caption is about 214 pixels wide
	  in a 1920 frame. A sign therefore only exists on screen once it is big
	  enough to read, and there is no range at which a smear of unreadable type
	  can appear at all.
	- From the spawn terrace the nearest sign is 116 studs away, which is past
	  that cutoff: **the establishing shot contains no text whatsoever.** The
	  first caption appears once you have committed to walking somewhere.

	Both faces are captioned, so it reads on the way in and on the way out.

	Keeping the text at all is a judgement call: the regions are already legible
	from terrain alone, which was the actual goal. But "a Prime node has surfaced
	in the Ember Barrens" is the game's loudest sentence, and one sign standing
	where the Barrens begin is what connects that sentence to a place. ]]
local function buildRegionSign(region: Region, decor: Folder)
	local names = Config.RegionNames :: { [string]: string }
	local caption = names[region.id]
	if not caption then
		return
	end

	local lobe = region.blobs[1]
	-- On the bearing at the region's near rim, but never crowding the
	-- crossroads, and set beside the road rather than across it.
	local reach = math.max(lobe.center.Magnitude - lobe.radius - 8, PLAZA_RADIUS + 14)
	local side = Vector3.new(-math.sin(region.bearing), 0, math.cos(region.bearing))
	local base = onBearing(region.bearing, reach) + side * 13
	local facing = CFrame.lookAt(base + Vector3.new(0, 12, 0), Vector3.new(0, 12, 0))

	for leg = -1, 1, 2 do
		local post = newBlock(
			Vector3.new(2.4, 11, 2.4),
			facing * CFrame.new(6.5 * leg, -6.5, 0),
			DARK_STONE,
			Enum.Material.Rock
		)
		post.Name = `SignPost_{region.id}_{if leg < 0 then "L" else "R"}`
		post.Parent = decor
	end

	local board =
		newBlock(Vector3.new(18, 5, 0.8), facing, Color3.fromRGB(38, 32, 30), Enum.Material.Slate)
	board.Name = `RegionSign_{region.id}`
	board.Parent = decor

	local cap = newBlock(
		Vector3.new(19.5, 1, 2),
		facing * CFrame.new(0, 3, 0),
		region.glow,
		Enum.Material.Neon
	)
	cap.Name = `RegionSignCap_{region.id}`
	cap.CastShadow = false
	cap.Parent = decor

	-- Front looks back down the road, Back looks into the region.
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local surface = Instance.new("SurfaceGui")
		surface.Name = `Caption_{face.Name}`
		surface.Face = face
		surface.PixelsPerStud = 40
		surface.LightInfluence = 0
		surface.AlwaysOnTop = false
		surface.MaxDistance = 80
		surface.Parent = board

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(0.92, 0.8)
		label.Position = UDim2.fromScale(0.04, 0.1)
		label.Font = Enum.Font.GothamBold
		label.TextScaled = true
		label.TextColor3 = region.glow
		label.Text = caption
		label.Parent = surface

		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Color = Color3.fromRGB(10, 9, 9)
		stroke.Parent = label
	end
end

--[[ The spawn terrace: a deck on piers at the southern rim, a ramp down into
	the field, and nothing at all in front of it.

	Three things about it are load-bearing rather than decorative.

	*It is high.* Twenty-two studs puts the eye above the ground plane, so the
	field recedes instead of filling the screen and the horizon sits low enough
	that the top of the frame is sky.

	*It is open to the north.* The parapet stops at the halfway line and the pad
	sits at the deck's front edge, so every piece of furniture -- piers, banner
	pylons, back wall -- is behind the camera rather than in it.

	*It stands on piers.* The node field runs to 220 studs and this sits inside
	it, so the ground underneath stays flat and walkable and a node that spawns
	below the deck is still a node you can walk to and stand in. The deck is
	shade and cover, not a lid.

	It is also the one piece of architecture visible from the whole map, which
	makes "home" a thing you can navigate back to by eye. ]]
local function buildTerrace(decor: Folder)
	local deck = newDisc(
		DECK_RADIUS,
		4,
		TERRACE_CENTER + Vector3.new(0, DECK_TOP - 2, 0),
		PLAZA_COLOR,
		Enum.Material.Sandstone
	)
	deck.Name = "TerraceDeck"
	deck.CanQuery = false
	deck.Parent = decor

	local inlay = newDisc(
		DECK_RADIUS - 7,
		1,
		TERRACE_CENTER + Vector3.new(0, DECK_TOP + 0.1, 0),
		Color3.fromRGB(226, 198, 148),
		Enum.Material.Marble
	)
	inlay.Name = "TerraceInlay"
	makeInert(inlay)
	inlay.Parent = decor

	for index = 1, 6 do
		local angle = (index / 6) * math.pi * 2
		local pier = newBlock(
			Vector3.new(7, DECK_TOP, 7),
			CFrame.new(
				TERRACE_CENTER + onBearing(angle, DECK_RADIUS - 8) + Vector3.new(0, DECK_TOP / 2, 0)
			) * yawAt(angle),
			STONE_COLOR:Lerp(DARK_STONE, 0.35),
			Enum.Material.Rock
		)
		pier.Name = `TerracePier{index}`
		pier.Parent = decor
	end

	--[[ Parapet on the southern half only. A waist-high wall in front of the
		player would cut off exactly the near-to-middle ground the terrace exists
		to show them. ]]
	for index = 1, 7 do
		local angle = math.pi + (index / 8) * math.pi
		local wall = newBlock(
			Vector3.new(15, 5, 4),
			CFrame.new(
				TERRACE_CENTER
					+ onBearing(angle, DECK_RADIUS - 2)
					+ Vector3.new(0, DECK_TOP + 2.5, 0)
			) * yawAt(angle + math.pi / 2),
			STONE_COLOR,
			Enum.Material.Sandstone
		)
		wall.Name = `TerraceParapet{index}`
		wall.Parent = decor
	end

	-- Banner pylons at the back corners: the terrace's silhouette from the
	-- field, and out of frame from on top of it.
	for lamp = -1, 1, 2 do
		local base = TERRACE_CENTER + Vector3.new(19 * lamp, 0, -16)
		local pylon = newBlock(
			Vector3.new(5, DECK_TOP + 30, 5),
			CFrame.new(base + Vector3.new(0, (DECK_TOP + 30) / 2, 0)),
			DARK_STONE,
			Enum.Material.Rock
		)
		pylon.Name = `TerracePylon{if lamp < 0 then "L" else "R"}`
		pylon.Parent = decor

		local banner = newBlock(
			Vector3.new(1.2, 22, 11),
			CFrame.new(base + Vector3.new(3 * lamp, DECK_TOP + 18, 0)),
			TIMBER_COLOR,
			Enum.Material.Fabric
		)
		banner.Name = `TerraceBanner{if lamp < 0 then "L" else "R"}`
		banner.CanQuery = false
		banner.Parent = decor

		local flame = newBlock(
			Vector3.new(5, 5, 5),
			CFrame.new(base + Vector3.new(0, DECK_TOP + 32, 0)) * CFrame.Angles(0.6, 0.6, 0),
			BRAZIER_COLOR,
			Enum.Material.Neon
		)
		flame.Name = `TerraceFlame{if lamp < 0 then "L" else "R"}`
		flame.CastShadow = false
		flame.Parent = decor
	end

	-- The ramp down into the field. It is also the establishing shot's leading
	-- line: it points at the crossroads, which points at the Wellspring.
	local run = RAMP_LOW_Z - RAMP_HIGH_Z
	local drop = DECK_TOP
	local length = math.sqrt(run * run + drop * drop)
	local ramp = newBlock(
		Vector3.new(26, 2, length),
		CFrame.new(0, DECK_TOP / 2 - 1, (RAMP_HIGH_Z + RAMP_LOW_Z) / 2)
			* CFrame.Angles(math.atan2(drop, run), 0, 0),
		ROAD_COLOR,
		Enum.Material.Cobblestone
	)
	ramp.Name = "TerraceRamp"
	ramp.CanQuery = false
	ramp.Parent = decor

	for kerb = -1, 1, 2 do
		local rail = newBlock(
			Vector3.new(2, 2.5, length),
			CFrame.new(14 * kerb, DECK_TOP / 2 + 0.6, (RAMP_HIGH_Z + RAMP_LOW_Z) / 2)
				* CFrame.Angles(math.atan2(drop, run), 0, 0),
			DARK_STONE,
			Enum.Material.Rock
		)
		rail.Name = `TerraceRail{if kerb < 0 then "L" else "R"}`
		rail.Parent = decor
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

		--[[ The pass. A wall of 250-stud crags at 330 studs subtends 25 degrees
			from the terrace, and a camera that pitches down at all then has no
			sky left in frame -- which is exactly what the round-2 captures
			showed. So the ring is a saddle rather than a fence: it sinks to
			about a quarter height and steps back on the bearing the player
			spawns facing, and climbs to full height around the sides. The centre
			of the establishing shot gets twenty degrees of open sky above a low
			horizon, and the frame still has tall rock closing both edges. ]]
		local offAxis =
			math.abs(math.atan2(math.sin(angle - math.pi / 2), math.cos(angle - math.pi / 2)))
		local rise = math.clamp(offAxis / 1.2, 0, 1)
		height *= 0.28 + 0.72 * rise * rise
		dist += 70 * (1 - rise)

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
	local volcanoOffset = position - Vector3.new(251, 0, -145)
	if volcanoOffset.X * volcanoOffset.X + volcanoOffset.Z * volcanoOffset.Z <= 96 * 96 then
		return "barren"
	end
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

--[[ Where the ground is under a point, or nil if nothing may be placed there.

	Node spawn heights used to be the constant `y = 4`, which was fine only
	because the arena is one flat plate. The moment the ground varies -- and it
	will -- a constant floats or buries every node on the map, so placement asks
	the world instead of assuming it.

	Bare ground only. A hit on decor means the point is inside the Wellspring
	spire, inside a grove pillar, on a crag or under the terrace deck, and a node
	there is either invisible or standing on a roof. Those come back nil so the
	caller re-rolls rather than spawning something unreachable. Inlaid surfaces
	-- floors, roads, rims -- are `makeInert` and carry no query, so they are
	already invisible to this ray and the node lands on the plate beneath them,
	which is the correct answer. ]]
local PLACEMENT_RAY_TOP = 512
local PLACEMENT_RAY_LENGTH = 1024

function ArenaService.groundYAt(position: Vector3): number?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true

	--[[ Exclude the two folders that are themselves spawned content. Without
		this, nodes stack on each other's ring beds and on live constructs. ]]
	local excluded: { Instance } = {}
	for _, name in { "AuraNodes", "Constructs" } do
		local folder = Workspace:FindFirstChild(name)
		if folder then
			table.insert(excluded, folder)
		end
	end
	params.FilterDescendantsInstances = excluded

	local origin = Vector3.new(position.X, PLACEMENT_RAY_TOP, position.Z)
	local hit = Workspace:Raycast(origin, Vector3.new(0, -PLACEMENT_RAY_LENGTH, 0), params)
	if not hit then
		return nil
	end

	--[[ Reject decor by parentage rather than by name, so this keeps working
		whether the ground is the plate this service builds or a Baseplate the
		place already provided. ]]
	local decor = Workspace:FindFirstChild(DECOR_NAME)
	if decor and hit.Instance:IsDescendantOf(decor) then
		return nil
	end
	return hit.Position.Y
end

--[[ Ground a node must never be placed on, regardless of what the ray says.

	The spawn terrace sits at (0, -150) and the old 220-stud spawn disc reached
	well past it, so a node could spawn *under the deck*: invisible, uncontested,
	and if it were a Prime its three-hundred-stud shaft would fire up through the
	floor the players are standing on. The plaza is excluded for the same reason
	the arena builds nothing in it -- it is the one piece of ground that has to
	stay readable.

	The anchors happen to clear both already; this exists so that stays true when
	somebody edits them. ]]
local TERRACE_KEEPOUT = DECK_RADIUS + 18

function ArenaService.isPlaceable(position: Vector3): boolean
	local dx = position.X - TERRACE_CENTER.X
	local dz = position.Z - TERRACE_CENTER.Z
	if dx * dx + dz * dz <= TERRACE_KEEPOUT * TERRACE_KEEPOUT then
		return false
	end
	if position.X * position.X + position.Z * position.Z <= PLAZA_RADIUS * PLAZA_RADIUS then
		return false
	end
	return true
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
	table.insert(anchors, {
		name = "volcano_crown",
		position = Vector3.new(251, 88, -145),
		region = "barren",
		radius = 7,
	})
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
		position = TORII_POINT,
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

-- ===================================================================
-- Neutral patrol routes -- world data, kept with the world.
-- ===================================================================

--[[ The placement table `NpcService.start` reads. It lives here rather than in
	Config because a route is geography, not tuning: every waypoint below was
	computed against the lobes, the pillars, the gate legs, the crystals, the
	deck and the plaza that this file builds, and it is checked against them
	again at boot (see `patrols`). The shape is the one confirmed in npcs.md;
	NpcService declares the same fields, and either side can point at its
	declaration if the other drifts. `stage` is a stage NAME, resolved the way
	`/dummy`'s argument is. `pingPong` is per route, because the routes below
	need both traversal modes. ]]
export type Patrol = {
	name: string,
	region: string,
	stage: string,
	walkSpeed: number,
	pingPong: boolean,
	route: { Vector3 },
}

--[[ Routes are authored as x,z; the floor supplies y at boot through
	`groundYAt`, and the root is lifted the way the dummy row's is for the same
	2x5x1 rig. Every position was computed, not eyeballed, and each carries a
	1.6-stud body margin over the obstacle face:

	- Pillars, gate legs, spire and crystals are deterministic here (`rng` is
	  seeded and only ever used for heights), so they were placed exactly.
	  NO ring around any Reach lobe clears its trunks -- the best full ring
	  collides by 4.4 studs -- so the Reach route is one straight line through
	  the grove threading between them, at 2.9 clearance.
	- The Barrens' blight spires are placed with that rng at random angles, so
	  they cannot be placed offline -- but `sqrt(U(0.05,1)) * (r - 10)` with
	  width <= 11 bounds every one to within r - 4.5 of its lobe centre, so the
	  outer band of each lobe is clear BY CONSTRUCTION. The Barrens route stays
	  in that band for every lobe that reaches it; its closing chord would cut
	  through the blight, which is why it ping-pongs.
	- Node parts are CanCollide false, so a node on a route is not an obstacle.
	- Nothing runs within 34 studs of the terrace centre, up the ramp, or across
	  the plaza. NPCs retaliate once hit; a route past the deck would drag a
	  fight onto the spawn. ]]
local PATROL_ROOT_LIFT = 3

type PatrolSpec = {
	name: string,
	region: string,
	stage: string,
	walkSpeed: number,
	pingPong: boolean,
	points: { { number } },
}

local PATROLS: { PatrolSpec } = {
	{
		--[[ A straight crossing of the Reach grove, north to south, 82 studs.
			Both ends sit ~41 from the (-102,-59) lobe centre, inside its 44
			floor. The line passes the lobe centre between the inner and outer
			pillar rings and skirts the gate's left leg; it crosses behind the
			gate the deck's own sightline points at. ]]
		name = "Grove Walker",
		region = "rich",
		stage = "lowgold",
		walkSpeed = 6,
		pingPong = true,
		points = { { -93.5, -18.8 }, { -114.0, -98.6 } },
	},
	{
		--[[ The north rim of the near Barrens lobe (97,-56): five points at
			radius 47.3 from bearing 51 to 140 degrees -- the longest arc of
			that lobe that stays in the clear band of every Barrens lobe that
			reaches it, 3.8 clear of the Barrens waymark at (61,-35), on basalt
			end to end, 66 studs from the plaza centre. Chord sag stays above
			the blight bound. PING-PONG ONLY: the chord from the last point back
			to the first crosses the blight zone. ]]
		name = "Ash Sentinel",
		region = "barren",
		stage = "foundation",
		walkSpeed = 6,
		pingPong = true,
		points = {
			{ 126.8, -19.2 },
			{ 110.6, -10.7 },
			{ 92.5, -8.9 },
			{ 75.0, -14.1 },
			{ 60.8, -25.6 },
		},
	},
	{
		--[[ An octagon at radius 30 around the Wellspring heart (0,172): outside
			the 27-radius pool, inside the six crystals at 38 (2.9 clear), well
			clear of the spire base and the beacon, every point inside the
			(0,172) lobe's 44 floor. Every chord verified; it loops. ]]
		name = "Pool Warden",
		region = "wellspring",
		stage = "highgold",
		walkSpeed = 6,
		pingPong = false,
		points = {
			{ 30.0, 172.0 },
			{ 21.2, 193.2 },
			{ 0.0, 202.0 },
			{ -21.2, 193.2 },
			{ -30.0, 172.0 },
			{ -21.2, 150.8 },
			{ 0.0, 142.0 },
			{ 21.2, 150.8 },
		},
	},
}

--[[ The routes, lifted onto the floor, checked against the world they were
	computed for. The data is not Lune-reachable (it is Vector3), so the check a
	pure module would get from the suite happens here, once, at boot: a waypoint
	whose `regionAt` disagrees with its declared region, or which sits inside the
	terrace keep-out or the plaza, is a warning naming the route and the point.
	Warn rather than skip, because the NPC still spawning where the author put it
	is the thing that makes the mistake visible. ]]
function ArenaService.patrols(): { Patrol }
	local out: { Patrol } = {}
	for _, spec in PATROLS do
		local route: { Vector3 } = {}
		for index, xz in spec.points do
			local flat = Vector3.new(xz[1], 0, xz[2])
			local groundY = ArenaService.groundYAt(flat) or FLOOR_TOP
			local point = Vector3.new(flat.X, groundY + PATROL_ROOT_LIFT, flat.Z)
			table.insert(route, point)

			local region = ArenaService.regionAt(flat)
			if region ~= spec.region then
				warn(
					`[arena] patrol {spec.name} point {index} is on {region} ground, declared {spec.region}`
				)
			end
			local fromTerrace = (Vector3.new(flat.X, 0, flat.Z) - TERRACE_CENTER).Magnitude
			if fromTerrace < TERRACE_KEEPOUT then
				warn(`[arena] patrol {spec.name} point {index} is inside the terrace keep-out`)
			end
			if Vector3.new(flat.X, 0, flat.Z).Magnitude < PLAZA_RADIUS then
				warn(`[arena] patrol {spec.name} point {index} is inside the plaza`)
			end
		end
		table.insert(out, {
			name = spec.name,
			region = spec.region,
			stage = spec.stage,
			walkSpeed = spec.walkSpeed,
			pingPong = spec.pingPong,
			route = route,
		})
	end
	return out
end

-- ===================================================================
-- The establishing shot, measured at boot.
-- ===================================================================

--[[ The header's table of what the first frame contains was measured once by
	hand and would rot silently: any builder that grows, any relayout, any
	re-seed moves the numbers and nothing says so. This measures the SAME
	frame, from the same documented camera, against the world as actually
	built -- part positions and sizes read back out of the decor, so seeded
	heights and later reshuffles are included for free -- and it warns when
	something lands where the header fought for sky.

	Camera, MEASURED by worldcraft in a real session rather than taken from
	the header's estimate: the default follow camera at spawn sits 8.2 studs
	above the pad and ~6.5 behind the character -- eye (x, 30.7, z) for a pad
	at 22.5, so SPAWN_POINT + (0, 8.2, -6.5) -- pitched 15.0 degrees down with
	a 70-degree vertical FOV, so the frame spans -50..+20 degrees above the
	horizon and about +-51 across. The header said 13 back, 2 up, 8.7 down;
	against that, the horizon sits ~6 degrees higher in the real frame. x/z
	drift a few studs with where on the pad the character lands, and the
	first-frame camera may depend on the last-used zoom, so one re-measure
	against a real client is still owed. Elevations below are above the
	HORIZON, which is how the header quotes them.

	Same idiom as patrols(): warn, never skip. World data is Vector3 and
	cannot reach Lune, so the check a pure module would get from the suite
	happens here, once, at the end of start(). The exemption list is the one
	thing meant to leave the frame through the top -- the Wellspring beacon,
	readable from anywhere by design. ]]
local FRAME_EYE_OFFSET = Vector3.new(0, 8.2, -6.5)
local FRAME_PITCH_DEG = -15.0
local FRAME_HALF_VFOV_DEG = 35
local FRAME_HALF_HFOV_DEG = 51
-- The sky the header bought: nothing but the beacon may stand this high this
-- close to dead ahead.
local FRAME_CONE_HALF_AZ_DEG = 15
local FRAME_CONE_EL_DEG = 18
-- The header measured 16..22 degrees of open sky over the saddle.
local FRAME_MIN_SKY_DEG = 14

local FRAME_EXEMPT: { [string]: boolean } = { wellspringBeacon = true }

type FrameProbe = { label: string, partName: string }

-- Landmarks by the Name their builder gives them; top-centre of the part.
local FRAME_PROBES: { FrameProbe } = {
	{ label = "crossroads crown", partName = "CrossroadsCrown" },
	{ label = "torii cap", partName = "ToriiCap" },
	{ label = "watchtower brazier", partName = "WatchtowerBrazier" },
	{ label = "Wellspring spire tip", partName = "WellspringTip" },
	{ label = "Wellspring beacon", partName = "wellspringBeacon" },
	{ label = "Reach beacon", partName = "richBeacon" },
	{ label = "grove gate lintel", partName = "GroveGateLintel" },
}

local function frameAngles(eye: Vector3, point: Vector3): (number, number, number)
	local d = point - eye
	local horizontal = math.sqrt(d.X * d.X + d.Z * d.Z)
	local az = math.deg(math.atan2(d.X, d.Z))
	local el = math.deg(math.atan2(d.Y, horizontal))
	return d.Magnitude, az, el
end

-- Luau interpolation takes expressions only, so degrees are formatted here.
local function deg1(x: number): string
	return string.format("%.1f", x)
end

local function degSigned(x: number): string
	return string.format("%+.1f", x)
end

local function frameLine(label: string, dist: number, az: number, el: number): string
	local side = if math.abs(az) < 0.5
		then "dead ahead"
		else `{deg1(math.abs(az))} deg {if az < 0 then "left" else "right"}`
	return `[arena] frame: {label} -- {string.format("%.0f", dist)} studs, {side}, {degSigned(el)} deg`
end

function ArenaService.frameCheck()
	local decor = Workspace:FindFirstChild(DECOR_NAME)
	if not decor then
		warn("[arena] frame: no decor to measure")
		return
	end
	local eye = SPAWN_POINT + FRAME_EYE_OFFSET
	local frameTop = FRAME_PITCH_DEG + FRAME_HALF_VFOV_DEG

	-- Named landmarks.
	local byName: { [string]: BasePart } = {}
	for _, inst in decor:GetDescendants() do
		if inst:IsA("BasePart") then
			byName[inst.Name] = inst
		end
	end
	for _, probe in FRAME_PROBES do
		local part = byName[probe.partName]
		if not part then
			warn(`[arena] frame: no part named {probe.partName} to measure ({probe.label})`)
			continue
		end
		local top = part.Position + Vector3.new(0, part.Size.Y / 2, 0)
		local dist, az, el = frameAngles(eye, top)
		print(frameLine(probe.label, dist, az, el))
		if
			not FRAME_EXEMPT[probe.partName]
			and math.abs(az) <= FRAME_CONE_HALF_AZ_DEG
			and el > FRAME_CONE_EL_DEG
		then
			warn(
				`[arena] frame: {probe.label} intrudes on the centre cone `
					.. `({degSigned(az)} az, {degSigned(el)} el) -- the header fought for that sky`
			)
		end
	end

	-- Region edges: the nearest boundary point of each region's first lobe,
	-- along the line from the eye to its centre, at ground.
	local flatEye = Vector3.new(eye.X, 0, eye.Z)
	for _, region in REGIONS do
		local lobe = region.blobs[1]
		local toCentre = lobe.center - flatEye
		if toCentre.Magnitude > lobe.radius then
			local edge = lobe.center - toCentre.Unit * lobe.radius
			local dist, az, el = frameAngles(eye, edge)
			print(frameLine(`{region.id} edge`, dist, az, el))
		end
	end

	-- The crag ring: the saddle (highest peak near dead ahead) and the edges.
	local saddleEl, saddleAz, edgeEl = -90, 0, -90
	for name, part in byName do
		if string.match(name, "^Crag%d+C$") then
			local top = part.Position + Vector3.new(0, part.Size.Y / 2, 0)
			local _, az, el = frameAngles(eye, top)
			if math.abs(az) <= FRAME_CONE_HALF_AZ_DEG and el > saddleEl then
				saddleEl, saddleAz = el, az
			elseif math.abs(az) >= 40 and math.abs(az) <= FRAME_HALF_HFOV_DEG and el > edgeEl then
				edgeEl = el
			end
		end
	end
	if saddleEl > -90 then
		local sky = frameTop - saddleEl
		print(
			`[arena] frame: crag saddle -- {degSigned(saddleEl)} deg at {degSigned(saddleAz)} az, `
				.. `edges {degSigned(edgeEl)} deg, open sky {deg1(sky)} deg to the frame top`
		)
		if sky < FRAME_MIN_SKY_DEG then
			warn(`[arena] frame: only {deg1(sky)} deg of sky over the saddle (header: 16..22)`)
		end
	else
		warn("[arena] frame: no crag peak found near dead ahead -- is the ring built?")
	end
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
		for _, region in REGIONS do
			local bow = if region.id == "wellspring"
				then 0.62
				elseif region.id == "rich" then 0.7
				else 0.66
			buildRoad(
				region.id,
				onBearing(region.bearing, PLAZA_RADIUS + 6),
				onBearing(region.bearing + bow, 130),
				region.blobs[1].center,
				17,
				decor
			)
		end

		for _, region in REGIONS do
			buildRegionSign(region, decor)
		end

		buildTerrace(decor)
		-- The short road off the ramp into the crossroads. Barely a curve, but
		-- it is what makes the terrace part of the map rather than a platform
		-- parked next to it.
		buildRoad(
			"terrace",
			Vector3.new(0, 0, RAMP_LOW_Z),
			Vector3.new(9, 0, (RAMP_LOW_Z - PLAZA_RADIUS) / 2),
			Vector3.new(0, 0, -PLAZA_RADIUS - 4),
			5,
			decor
		)

		buildWatchtower(onBearing(math.pi / 6, 132), decor)
		buildAqueduct(onBearing(math.pi * 5 / 6, 144), math.pi * 5 / 6, decor)
		buildStandingStones(onBearing(math.pi / 6, 198), decor)
		buildTorii(TORII_POINT, math.pi * 5 / 4, decor)
		buildSkyIslands(decor)
		buildCrossroads(decor)

		decor.Parent = Workspace

		-- Keep the arena footprint and its existing random sequence intact.
		-- Remove peripheral decoration inside the new mountain, never landmarks
		-- elsewhere; the volcanic builders use independent deterministic streams.
		local volcanoCentre = Vector3.new(251, 0, -145)
		for _, part in decor:GetDescendants() do
			if part:IsA("BasePart") then
				local offset = part.Position - volcanoCentre
				if
					offset.X * offset.X + offset.Z * offset.Z
						< (84 + part.Size.Magnitude / 2) ^ 2
					and (
						part.Name:match("^Crag")
						or part.Name:match("^BlightShard")
						or part.Name:match("^EmberCrack")
						or part.Name:match("^FallenArch")
					)
				then
					part:Destroy()
				end
			end
		end
		local ground = Instance.new("Folder")
		ground.Name = "ArenaWalkable"
		ground.Parent = Workspace
		local function volcanoRng(name: string): Random
			local seed = 20260912
			for index = 1, #name do
				seed = (seed * 31 + string.byte(name, index)) % 2147483647
			end
			return Random.new(seed)
		end
		VolcanoWorld.build({ rngFor = volcanoRng, decor = decor, ground = ground }, volcanoCentre)
		local approach = Worldcraft.volcanoApproach(volcanoCentre)
		buildRoad(
			"volcano",
			Vector3.new(140, 0, -75),
			Vector3.new(155, 0, -170),
			approach,
			18,
			decor
		)
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

	-- Measure the first frame against the world just built. A measurement
	-- must never take the arena down, so it is protected the same way.
	local protectedFrame = ArenaService.frameCheck :: () -> any
	local frameOk, frameErr = pcall(protectedFrame)
	if not frameOk then
		warn(`[arena] frame check skipped: {frameErr}`)
	end

	local multipliers = Config.StaticRegionMultipliers :: { [string]: number }
	print(
		`[arena] ready -- {#Config.Stages} stages, ground {groundSize()} studs, `
			.. `regions barren {multipliers.barren}x / open {multipliers.open}x / `
			.. `rich {multipliers.rich}x / wellspring {multipliers.wellspring}x`
	)
end

return ArenaService
