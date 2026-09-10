--!strict
--[[
	Builds the arena: ground, spawn, the static aura geography, and the
	landmarks that make the place navigable by eye.

	Beyond "somewhere to stand", this does two jobs.

	*Silhouette.* A flat plate gives the eye nothing to fix on, so every bearing
	looks identical and the HUD compass becomes the only way to navigate. A ring
	of crags closes the horizon, three biomes break the middle distance, and two
	light shafts are visible from anywhere in the node field.

	*Legible terrain.* `Config.StaticRegionMultipliers` is load-bearing -- Ruler
	techniques multiply their damage by the region the caster stands in, and
	cycling rate scales with it too -- and it was invisible, which made a whole
	mechanic unreadable. The four regions are now four distinct floors, and
	richness reads three ways at once: hue, brightness, and how much is built on
	the ground. Barren is dark, flat and empty. Open is the mid-grey commons.
	Rich is green with a grove that doubles as cover. Wellspring is bright,
	spired, and the *smallest* of the three, so the best ground on the map is
	also the hardest to hold.

	The layout is fixed, not rolled per server: static aura geography is
	supposed to be learnable, so one seed builds the same arena every run.

	`ArenaService.regionAt` is the query side of that geography. Nothing calls
	it yet -- NodeService still rolls a node's region at random rather than
	reading it off the ground the node lands on -- but the moment it does, what
	a player sees under their feet and what the damage formula uses become the
	same fact.

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
	it stays flat and walkable: region floors are inlaid a tenth of a stud proud
	of the ground rather than raised, and no prop stands where the spawn ring is. ]]
local NODE_FIELD_RADIUS = 220
local ARENA_RADIUS = NODE_FIELD_RADIUS + 130
local WALL_RADIUS = 330
local APRON_RADIUS = 430
local SPAWN_CLEARANCE = 66

-- One seed, one arena. See the note about learnable geography above.
local rng = Random.new(20260910)

type Region = {
	id: string,
	center: Vector3,
	radius: number,
	floor: Color3,
	material: Enum.Material,
	rim: Color3,
	rimGlows: boolean,
	glow: Color3,
}

--[[ Three discs on a triangle around a neutral centre, so spawn is always in
	`open` (1.0x) and the three graded regions are equidistant from it. Reward
	runs inverse to area on purpose -- the 2.6x wellspring is the smallest
	footprint on the map and the 0.5x blight is the largest. ]]
local REGIONS: { Region } = {
	{
		id = "wellspring",
		center = Vector3.new(0, 0, 150),
		radius = 62,
		floor = Color3.fromRGB(146, 228, 238),
		material = Enum.Material.Glacier,
		rim = Color3.fromRGB(120, 245, 255),
		rimGlows = true,
		glow = Color3.fromRGB(150, 250, 255),
	},
	{
		id = "rich",
		center = Vector3.new(-134.2, 0, -77.5),
		radius = 96,
		floor = Color3.fromRGB(86, 156, 92),
		material = Enum.Material.Grass,
		rim = Color3.fromRGB(140, 255, 150),
		rimGlows = true,
		glow = Color3.fromRGB(150, 255, 160),
	},
	{
		id = "barren",
		center = Vector3.new(134.2, 0, -77.5),
		radius = 108,
		floor = Color3.fromRGB(58, 54, 52),
		material = Enum.Material.Basalt,
		-- No neon rim. Dead ground announces itself by having nothing to announce.
		rim = Color3.fromRGB(38, 35, 34),
		rimGlows = false,
		glow = Color3.fromRGB(120, 104, 94),
	},
}

local OPEN_COLOR = Color3.fromRGB(104, 104, 100)
local STONE_COLOR = Color3.fromRGB(178, 176, 166)
local DARK_STONE = Color3.fromRGB(62, 64, 70)

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
	ground.Material = Enum.Material.Slate
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

--[[ Floors carry no physics at all. They sit a tenth of a stud above the plate
	and would otherwise catch Striker raycasts fired at a prone target. ]]
local function makeInert(part: BasePart)
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
end

local function yawAt(angle: number): CFrame
	return CFrame.Angles(0, -angle, 0)
end

-- Region floors -------------------------------------------------------------

--[[ Each region is a rim band with the floor inlaid inside it, so the boundary
	-- the line where a Ruler technique's damage changes by up to 5x -- is a
	visible edge rather than an inference. ]]
local function buildRegionFloor(region: Region, decor: Folder, regionFolder: Folder)
	local rim = newDisc(
		region.radius + 8,
		2,
		region.center + Vector3.new(0, -0.95, 0),
		region.rim,
		if region.rimGlows then Enum.Material.Neon else Enum.Material.Basalt
	)
	rim.Name = `{region.id}Rim`
	rim.Transparency = if region.rimGlows then 0.15 else 0
	makeInert(rim)
	rim.Parent = decor

	local floor = newDisc(
		region.radius,
		2,
		region.center + Vector3.new(0, -0.88, 0),
		region.floor,
		region.material
	)
	floor.Name = region.id
	makeInert(floor)
	floor:SetAttribute("Region", region.id)
	floor:SetAttribute("Radius", region.radius)
	floor:SetAttribute(
		"Multiplier",
		(Config.StaticRegionMultipliers :: { [string]: number })[region.id]
	)
	floor.Parent = regionFolder
end

--[[ A shaft of light over the two regions worth crossing the map for. This is
	the one landmark readable from the far rim of the field, which is what makes
	"go to the wellspring" a decision a player can act on from anywhere. ]]
local function buildBeacon(region: Region, height: number, decor: Folder)
	local shaft = newDisc(
		11,
		height,
		region.center + Vector3.new(0, height / 2, 0),
		region.glow,
		Enum.Material.Neon
	)
	shaft.Name = `{region.id}Beacon`
	shaft.Transparency = 0.82
	makeInert(shaft)
	shaft.Parent = decor
end

-- Landmarks -----------------------------------------------------------------

--[[ The wellspring: a spire in a luminous pool, ringed by crystal. Tall enough
	to clear the grove and the crags behind it from anywhere in the field. ]]
local function buildWellspring(region: Region, decor: Folder)
	-- Above the region floor's top face (y = 0.12), not level with it.
	local pool =
		newDisc(27, 1.2, region.center + Vector3.new(0, -0.2, 0), region.glow, Enum.Material.Neon)
	pool.Name = "WellspringPool"
	pool.Transparency = 0.45
	makeInert(pool)
	pool.Parent = decor

	local segments = { { 18, 62, 0.0 }, { 13, 52, 0.35 }, { 8.5, 46, 0.7 } }
	local base = 0
	for index, segment in segments do
		local width, height, yaw = segment[1], segment[2], segment[3]
		local block = newBlock(
			Vector3.new(width, height, width),
			CFrame.new(region.center + Vector3.new(0, base + height / 2, 0)) * yawAt(yaw),
			STONE_COLOR:Lerp(region.glow, index * 0.12),
			Enum.Material.Marble
		)
		block.Name = `WellspringSpire{index}`
		block.Parent = decor
		base += height
	end

	local tip = newBlock(
		Vector3.new(5, 11, 5),
		CFrame.new(region.center + Vector3.new(0, base + 5, 0)) * yawAt(0.7),
		region.glow,
		Enum.Material.Neon
	)
	tip.Name = "WellspringTip"
	tip.CastShadow = false
	tip.Parent = decor

	for index = 1, 6 do
		local angle = (index / 6) * math.pi * 2
		local height = rng:NextNumber(30, 52)
		local offset = Vector3.new(math.cos(angle) * 42, 0, math.sin(angle) * 42)
		local crystal = newBlock(
			Vector3.new(7, height, 7),
			CFrame.new(region.center + offset + Vector3.new(0, height / 2 - 3, 0))
				* yawAt(angle)
				* CFrame.Angles(0.16, 0, 0),
			Color3.fromRGB(176, 236, 244),
			Enum.Material.Glacier
		)
		crystal.Name = `WellspringCrystal{index}`
		crystal.Parent = decor

		local crown = newBlock(
			Vector3.new(4.5, 7, 4.5),
			CFrame.new(region.center + offset + Vector3.new(0, height + 1, 0)) * yawAt(angle),
			region.glow,
			Enum.Material.Neon
		)
		crown.Name = `WellspringCrown{index}`
		crown.CastShadow = false
		crown.Parent = decor
	end
end

--[[ The rich grove. Its pillars are the only real cover on the map, which is
	deliberate: the 1.8x region is where fights should happen, and a fight with
	sightlines to break is a better fight than one on an empty plate. ]]
local function buildGrove(region: Region, decor: Folder)
	for index = 1, 9 do
		local angle = (index / 9) * math.pi * 2 + 0.4
		local dist = if index % 2 == 0 then 38 else 74
		local height = rng:NextNumber(44, 66)
		local offset = Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
		local root = region.center + offset

		local trunk = newBlock(
			Vector3.new(11, height, 11),
			CFrame.new(root + Vector3.new(0, height / 2, 0)) * yawAt(angle * 1.7),
			Color3.fromRGB(96, 104, 88),
			Enum.Material.Rock
		)
		trunk.Name = `GrovePillar{index}`
		trunk.Parent = decor

		local canopy = newBlock(
			Vector3.new(28, 6, 28),
			CFrame.new(root + Vector3.new(0, height + 3, 0)) * yawAt(angle * 1.7 + 0.5),
			Color3.fromRGB(96, 178, 102),
			Enum.Material.Grass
		)
		canopy.Name = `GroveCanopy{index}`
		canopy.Parent = decor

		local underglow = newBlock(
			Vector3.new(19, 1.4, 19),
			CFrame.new(root + Vector3.new(0, height - 0.6, 0)) * yawAt(angle * 1.7 + 0.5),
			region.glow,
			Enum.Material.Neon
		)
		underglow.Name = `GroveGlow{index}`
		underglow.Transparency = 0.35
		makeInert(underglow)
		underglow.Parent = decor
	end

	-- A gate on the spawn-facing edge, so the grove has a front door.
	local bearing = math.atan2(region.center.Z, region.center.X)
	local mouth = region.center
		- Vector3.new(math.cos(bearing), 0, math.sin(bearing)) * (region.radius - 6)
	local side = Vector3.new(-math.sin(bearing), 0, math.cos(bearing))
	for index = -1, 1, 2 do
		local leg = newBlock(
			Vector3.new(8, 48, 8),
			CFrame.new(mouth + side * (18 * index) + Vector3.new(0, 24, 0)) * yawAt(bearing),
			Color3.fromRGB(120, 126, 108),
			Enum.Material.Rock
		)
		leg.Name = `GroveGateLeg{if index < 0 then "L" else "R"}`
		leg.Parent = decor
	end
	local lintel = newBlock(
		Vector3.new(52, 9, 11),
		CFrame.new(mouth + Vector3.new(0, 52, 0)) * yawAt(bearing - math.pi / 2),
		Color3.fromRGB(120, 126, 108),
		Enum.Material.Rock
	)
	lintel.Name = "GroveGateLintel"
	lintel.Parent = decor
end

--[[ The blight. Everything here is short, dark and broken: the silhouette says
	"nothing grows" before the player has read a single number, and standing in
	it halves their cycling rate and their Ruler damage. ]]
local function buildBlight(region: Region, decor: Folder)
	for index = 1, 15 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local dist = math.sqrt(rng:NextNumber(0.05, 1)) * (region.radius - 12)
		local height = rng:NextNumber(16, 44)
		local width = rng:NextNumber(5, 11)
		local offset = Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
		local shard = newBlock(
			Vector3.new(width, height, width * 0.8),
			CFrame.new(region.center + offset + Vector3.new(0, height / 2 - 2, 0))
				* yawAt(rng:NextNumber(0, math.pi))
				* CFrame.Angles(rng:NextNumber(-0.3, 0.3), 0, rng:NextNumber(-0.3, 0.3)),
			Color3.fromRGB(46, 43, 44):Lerp(Color3.fromRGB(72, 62, 58), rng:NextNumber(0, 1)),
			Enum.Material.Basalt
		)
		shard.Name = `BlightShard{index}`
		shard.Parent = decor
	end

	for index = 1, 5 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local dist = rng:NextNumber(20, region.radius - 20)
		local offset = Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
		local slab = newBlock(
			Vector3.new(rng:NextNumber(18, 30), 3, rng:NextNumber(12, 20)),
			CFrame.new(region.center + offset + Vector3.new(0, 1, 0))
				* yawAt(rng:NextNumber(0, math.pi))
				* CFrame.Angles(0.06, 0, 0.04),
			Color3.fromRGB(52, 48, 47),
			Enum.Material.Slate
		)
		slab.Name = `BlightRubble{index}`
		slab.Parent = decor
	end
end

--[[ Spawn ring plus one waymarker per region, each tipped in that region's own
	colour and standing on its bearing. From the pad you can see which way the
	green is and which way the blight is without turning on the compass. ]]
local function buildSpawnRing(decor: Folder)
	local plaza = newDisc(
		52,
		2,
		Vector3.new(0, -0.8, 0),
		Color3.fromRGB(146, 142, 130),
		Enum.Material.Sandstone
	)
	plaza.Name = "SpawnPlaza"
	makeInert(plaza)
	plaza.Parent = decor

	for index = 1, 8 do
		local angle = (index / 8) * math.pi * 2 + math.pi / 8
		local offset = Vector3.new(math.cos(angle) * 46, 0, math.sin(angle) * 46)
		local post = newBlock(
			Vector3.new(6, 15, 6),
			CFrame.new(offset + Vector3.new(0, 7.5, 0)) * yawAt(angle),
			STONE_COLOR,
			Enum.Material.Sandstone
		)
		post.Name = `SpawnPost{index}`
		post.Parent = decor

		local cap = newBlock(
			Vector3.new(7.5, 2, 7.5),
			CFrame.new(offset + Vector3.new(0, 16, 0)) * yawAt(angle),
			Color3.fromRGB(255, 205, 110),
			Enum.Material.Neon
		)
		cap.Name = `SpawnPostCap{index}`
		cap.CastShadow = false
		cap.Parent = decor
	end

	for _, region in REGIONS do
		local bearing = math.atan2(region.center.Z, region.center.X)
		local offset = Vector3.new(math.cos(bearing), 0, math.sin(bearing)) * SPAWN_CLEARANCE
		local pillar = newBlock(
			Vector3.new(7, 36, 7),
			CFrame.new(offset + Vector3.new(0, 18, 0)) * yawAt(bearing),
			DARK_STONE:Lerp(STONE_COLOR, 0.5),
			Enum.Material.Slate
		)
		pillar.Name = `Waymark_{region.id}`
		pillar.Parent = decor

		local band = newBlock(
			Vector3.new(9, 5, 9),
			CFrame.new(offset + Vector3.new(0, 38, 0)) * yawAt(bearing + 0.4),
			region.glow,
			Enum.Material.Neon
		)
		band.Name = `WaymarkBand_{region.id}`
		band.CastShadow = false
		band.Parent = decor

		-- A finger of stone leaning the way the region lies.
		local finger = newBlock(
			Vector3.new(4, 16, 4),
			CFrame.new(offset + Vector3.new(math.cos(bearing) * 6, 44, math.sin(bearing) * 6))
				* yawAt(bearing)
				* CFrame.Angles(0.55, 0, 0),
			DARK_STONE:Lerp(STONE_COLOR, 0.5),
			Enum.Material.Slate
		)
		finger.Name = `WaymarkFinger_{region.id}`
		finger.Parent = decor
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
		Color3.fromRGB(48, 50, 56),
		Enum.Material.Slate
	)
	apron.Name = "ArenaApron"
	apron.CastShadow = false
	apron.CanQuery = false
	apron.Parent = decor

	local capColor = Color3.fromRGB(96, 104, 118)
	for index = 1, 20 do
		local angle = (index / 20) * math.pi * 2
		local dist = WALL_RADIUS + rng:NextNumber(-28, 42)
		local height = rng:NextNumber(140, 250)
		local width = rng:NextNumber(120, 190)
		local root = Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
		local yaw = angle + rng:NextNumber(-0.5, 0.5)

		local massif = newBlock(
			Vector3.new(width, height, width * 0.72),
			CFrame.new(root + Vector3.new(0, height / 2 - 34, 0)) * yawAt(yaw),
			DARK_STONE:Lerp(capColor, rng:NextNumber(0, 0.35)),
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
			DARK_STONE:Lerp(capColor, rng:NextNumber(0.2, 0.55)),
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
			DARK_STONE:Lerp(capColor, rng:NextNumber(0.5, 1)),
			Enum.Material.Rock
		)
		peak.Name = `Crag{index}C`
		peak.CastShadow = false
		peak.Parent = decor
	end
end

--[[ Haze is what turns twenty grey blocks into a distant range: without depth
	falloff the crags read as flat cutouts pasted on the skybox. Skipped
	entirely if the place already has an Atmosphere, on the same principle as
	the ground -- a place that has art of its own keeps it. ]]
local function buildAtmosphere()
	if Lighting:FindFirstChildOfClass("Atmosphere") then
		return
	end
	local atmosphere = Instance.new("Atmosphere")
	atmosphere.Density = 0.32
	atmosphere.Offset = 0.1
	atmosphere.Color = Color3.fromRGB(199, 209, 225)
	atmosphere.Decay = Color3.fromRGB(106, 112, 125)
	atmosphere.Glare = 0.15
	atmosphere.Haze = 1.6
	atmosphere.Parent = Lighting

	Lighting.ClockTime = 14.2
	Lighting.Brightness = 2.4
	Lighting.Ambient = Color3.fromRGB(72, 76, 86)
	Lighting.OutdoorAmbient = Color3.fromRGB(124, 130, 142)
end

-- Public --------------------------------------------------------------------

--[[ Which static region a point stands in. Smallest containing disc wins, so
	if regions are ever nested the tighter -- and richer -- one is the answer.

	This is the geography Config.StaticRegionMultipliers prices. Once NodeService
	reads it instead of rolling `regions[math.random(1, #regions)]`, the floor a
	player is standing on and the multiplier on their Ruler technique become the
	same fact, and the terrain stops lying. ]]
function ArenaService.regionAt(position: Vector3): string
	local found = "open"
	local foundRadius = math.huge
	for _, region in REGIONS do
		local dx = position.X - region.center.X
		local dz = position.Z - region.center.Z
		if dx * dx + dz * dz <= region.radius * region.radius and region.radius < foundRadius then
			found = region.id
			foundRadius = region.radius
		end
	end
	return found
end

--[[ Centres and radii of the static regions, for anything that wants to place
	something *in* one rather than ask what it is standing on. ]]
function ArenaService.regions(): { { id: string, center: Vector3, radius: number } }
	local out = {}
	for _, region in REGIONS do
		table.insert(out, { id = region.id, center = region.center, radius = region.radius })
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
		for _, region in REGIONS do
			buildRegionFloor(region, decor, regionFolder)
		end
		buildWellspring(REGIONS[1], decor)
		buildGrove(REGIONS[2], decor)
		buildBlight(REGIONS[3], decor)
		buildBeacon(REGIONS[1], 460, decor)
		buildBeacon(REGIONS[2], 240, decor)
		buildSpawnRing(decor)

		decor.Parent = Workspace
	end

	-- Last, and guarded. Geometry is the job; a lighting property that turns out
	-- to be unwritable must not cost the arena the way one already cost the
	-- server bootstrap.
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
