--!strict
-- Construction QA with Lune's Roblox datatype/instance model, NOT engine physics.
-- Lune has no Roblox event signals or computed BasePart.Position property.
local rb = require("@lune/roblox")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local env: any = table.clone(rb)
-- Lune 0.10.5 lookAt reverses the Z component for this bearing. Use Roblox's
-- documented basis construction so geometry assertions exercise intended frames.
env.CFrame = table.clone(rb.CFrame)
env.CFrame.lookAt = function(at, target, up)
	local forward = (target - at).Unit
	local right = forward:Cross(up or rb.Vector3.yAxis).Unit
	return rb.CFrame.fromMatrix(at, right, right:Cross(forward), -forward)
end
env.game = {
	GetService = function()
		return rb.Instance.new("Folder")
	end,
}
local source = fs.readFile("src/server/Worldcraft.luau")
source = source:gsub(
	'local prompt = Instance.new%("ProximityPrompt"%).-model.PrimaryPart = head',
	"model.PrimaryPart = head"
)
source = source:gsub("part%.Position = position", "part.CFrame = CFrame.new(position)")
local worldcraft = luau.load(source, { environment = env })()
local cave = luau.load(fs.readFile("src/server/VolcanoCave.luau"), { environment = env })()
env.require = function(name)
	return if name == "VolcanoCave" then cave else worldcraft
end
env.script = { Parent = { Worldcraft = "Worldcraft", VolcanoCave = "VolcanoCave" } }
local moduleSource = fs.readFile("src/server/VolcanoWorld.luau")
	:gsub("p%.Position", "p.CFrame.Position")
local world = luau.load(moduleSource, { environment = env })()
local decor, ground = rb.Instance.new("Folder"), rb.Instance.new("Folder")
local kit = {
	decor = decor,
	ground = ground,
	rngFor = function()
		return {
			NextNumber = function(_, a, b)
				return (a + b) / 2
			end,
			NextInteger = function(_, a, b)
				return math.floor((a + b) / 2)
			end,
		}
	end,
}
local result = world.build(kit, rb.Vector3.new(251, 0, -145))
local props = luau.load(fs.readFile("src/server/VolcanoProps.luau"), { environment = env })()
props.build(result.root, result.ground)
local detail =
	luau.load(fs.readFile("src/server/VolcanoDragonDetail.luau"), { environment = env })()
detail.build(result.root)
local surface =
	luau.load(fs.readFile("src/server/VolcanoSurfaceDetail.luau"), { environment = env })()
surface.build(result.root)
local count = 0
local function check(value: any, message: string)
	assert(value, message)
	count += 1
end
-- The cave preserves source geometry; the authorized art variant retains its
-- hidden control parts and records original eye color for comparison.
local original = worldcraft.buildDragonHead(kit, rb.CFrame.identity, "OriginalDragonReference", 1.8)
local dragon = result.root:FindFirstChild("VolcanoDragon")
check(dragon ~= nil, "dragon exists")
for _, part in original:GetChildren() do
	if part:IsA("BasePart") then
		local actual = dragon:FindFirstChild(part.Name)
		check(actual ~= nil, "original dragon part preserved: " .. part.Name)
		if actual:GetAttribute("SculptureBaselineHidden") then
			check(
				actual.Transparency == 1 and not actual.CanQuery,
				"hidden comparison control must remain hidden and non-queryable: " .. part.Name
			)
			check(
				not actual:GetAttribute("VolcanoEye")
					and not actual:GetAttribute("VolcanoClue")
					and not actual:GetAttribute("VolcanoBreath"),
				"hidden comparison control cannot join opacity animation: " .. part.Name
			)
		end
		check(
			actual.Size == part.Size
				and (if part.Name == "EyeL" or part.Name == "EyeR"
					then actual:GetAttribute("SculptureBaselineColor")
					else actual.Color) == part.Color
				and actual.Material == part.Material,
			"original sculpture appearance preserved: " .. part.Name
		)
		local expectedOffset = original.Head.CFrame:ToObjectSpace(part.CFrame)
		local actualOffset = dragon.Head.CFrame:ToObjectSpace(actual.CFrame)
		check(
			(expectedOffset.Position - actualOffset.Position).Magnitude < 0.001,
			"original sculpture proportions preserved: " .. part.Name
		)
	end
end
original:Destroy()
-- Regression for actual Studio Plate2/Plate3 leakage: all exposed dragon
-- corners behind its face fit in front of the sloping black rear enclosure.
for _, p in dragon:GetChildren() do
	if p:IsA("BasePart") then
		for _, x in { -1, 1 } do
			for _, y in { -1, 1 } do
				for _, z in { -1, 1 } do
					local corner = result.frame:PointToObjectSpace(
						p.CFrame * (p.Size * rb.Vector3.new(x, y, z) / 2)
					)
					if corner.Y > 0 and corner.Z > 18 then
						check(
							corner.Z < 75 - corner.Y * 18 / 68 - 0.9,
							"exposed dragon corner outside rear enclosure: " .. p.Name
						)
					end
				end
			end
		end
	end
end
local actions = {}
local hazards, seals, jawParts = 0, 0, 0
local all = result.root:GetDescendants()
local floors = result.ground:GetDescendants()
for _, p in all do
	if p:IsA("BasePart") then
		check(p.Anchored, p.Name .. " must be anchored")
		if p:GetAttribute("VolcanoAction") then
			check(not actions[p.Name], "duplicate action " .. p.Name)
			check(not p.CanCollide, "interactive part collision " .. p.Name)
			actions[p.Name] = p
		end
		if p:GetAttribute("VolcanoHazard") then
			hazards += 1
		end
		if p:GetAttribute("VolcanoAshSeal") then
			seals += 1
		end
		if p:GetAttribute("VolcanoJaw") then
			jawParts += 1
		end
	elseif p:IsA("PointLight") then
		check(p.Range <= 68, "light range budget")
	end
end
local expected = {
	EmberBrazier = "light_brazier",
	RefugeCache = "refuge",
	FissureCache = "fissure",
	DragonOffer = "dragon",
	TrialStart = "trial_start",
	TrialFinish = "trial_finish",
	PurifyFont = "purify",
	ForgeAnvil = "forge",
	CraterSource = "gather",
}
for name, id in expected do
	check(actions[name] and actions[name]:GetAttribute("VolcanoAction") == id, name)
end
check(hazards == 2, "two optional vents")
check(seals == 1, "one physical ash seal")
check(
	jawParts > 2
		and dragon.Jaw:GetAttribute("VolcanoJaw")
		and dragon.Tongue:GetAttribute("VolcanoJaw"),
	"jaw and tongue remain the shared animation control"
)
-- Art regressions exercise geometry/attachment semantics, not the incidental
-- number of cosmetic primitives. Both tooth rows must belong to both arches.
local sculpture = assert(dragon:FindFirstChild("SculptureDetail"))
local toothRows = { upper = { {}, {} }, lower = { {}, {} } }
local mouthPieces, outerHorns = 0, 0
local headBasis = dragon.Head.CFrame
local pivot = dragon.Jaw.CFrame
local peakDelta = pivot * rb.CFrame.Angles(math.rad(3), 0, 0) * pivot:Inverse()
for _, p in sculpture:GetChildren() do
	if not p:IsA("BasePart") then
		continue
	end
	check(
		not p.CanCollide and not p.CanQuery,
		"cosmetic dragon additions cannot alter traversal or target queries: " .. p.Name
	)
	local row = p:GetAttribute("DragonToothRow")
	local arch = p:GetAttribute("DragonToothSide")
	if p.Name:match("^LowerJaw") or p.Name == "BeveledLowerLip" then
		check(
			p:GetAttribute("VolcanoJaw") == true,
			"lower jaw shell/lip must follow animation pivot: " .. p.Name
		)
	end
	if row then
		check(
			(row == 1 or row == 2) and (arch == "upper" or arch == "lower"),
			"tooth has valid row/arch metadata"
		)
		table.insert(toothRows[arch][row], p)
		check(p:IsA("WedgePart") and p.Transparency == 0, "visible teeth have tapered geometry")
		check(
			(p:GetAttribute("VolcanoJaw") == true) == (arch == "lower"),
			"only lower tooth arch follows jaw: " .. p.Name
		)
	end
	if p:GetAttribute("DragonMouthInterior") then
		mouthPieces += 1
		check(math.max(p.Color.R, p.Color.G, p.Color.B) <= 0.12, "mouth interior remains dark")
		check(
			not p:GetAttribute("VolcanoBreath") and not p:GetAttribute("VolcanoEye"),
			"mouth backing cannot pulse opaque/bright"
		)
		check(
			(p:GetAttribute("VolcanoJaw") == true) == (p.Name == "MouthBed"),
			"lower mouth bed follows jaw while roof/back stay with upper skull"
		)
	end
	if p:GetAttribute("DragonOuterHorn") then
		outerHorns += 1
	end
	if row or p:GetAttribute("DragonMouthInterior") then
		for _, phase in { 0, 1 } do
			local cf = if phase == 1 and p:GetAttribute("VolcanoJaw")
				then peakDelta * p.CFrame
				else p.CFrame
			for _, x in { -1, 1 } do
				for _, y in { -1, 1 } do
					for _, z in { -1, 1 } do
						local corner = result.frame:PointToObjectSpace(
							cf * (p.Size * rb.Vector3.new(x, y, z) / 2)
						)
						if corner.Y > 0 and corner.Z > 18 then
							check(
								corner.Z < 75 - corner.Y * 18 / 68 - 0.9,
								`mouth/teeth escape rear cave at phase{phase}: {p.Name}`
							)
							check(
								math.abs(corner.X) < (if corner.Y < 25.5 then 23.2 else 32.2),
								`mouth/teeth escape side cave at phase{phase}: {p.Name}`
							)
						end
					end
				end
			end
		end
	end
end
check(mouthPieces >= 3, "dark mouth has roof, rear and moving lower bed")
for _, arch in { "upper", "lower" } do
	local depth = {}
	for row = 1, 2 do
		check(#toothRows[arch][row] >= 4, arch .. " arch retains both substantial tooth rows")
		local total = 0
		for _, tooth in toothRows[arch][row] do
			total += headBasis:PointToObjectSpace(tooth.CFrame.Position).Z
		end
		depth[row] = total / #toothRows[arch][row]
	end
	check(depth[2] < depth[1] - 0.5, arch .. " second row sits behind front row")
end
check(outerHorns >= 4, "both outer horns have distinct base and tip segments")
for _, suffix in { "L", "R" } do
	local base = assert(sculpture:FindFirstChild("OuterHornBase" .. suffix))
	local tip = assert(sculpture:FindFirstChild("OuterHornTip" .. suffix))
	local baseAt = headBasis:PointToObjectSpace(base.CFrame.Position)
	local tipAt = headBasis:PointToObjectSpace(tip.CFrame.Position)
	check(
		math.abs(tipAt.X) > math.abs(baseAt.X) and tipAt.Y > baseAt.Y,
		"outer horn sweeps outward/up: " .. suffix
	)
end
-- Regression for QA5's hidden outer horns: fitting inside an enclosure does
-- not imply a camera can see them. OBB rays deliberately ignore CanQuery;
-- decorative opaque parts still occlude the rendered view. Wedge boxes are
-- conservative potential blockers, so this remains geometry evidence only.
local function segmentHitsBox(origin: any, target: any, box: any): boolean
	local start = box.CFrame:PointToObjectSpace(origin)
	local delta = box.CFrame:VectorToObjectSpace(target - origin)
	local half = box.Size / 2
	local low, high = 0.0001, 0.9999
	for _, axis in { "X", "Y", "Z" } do
		if math.abs(delta[axis]) < 0.000001 then
			if math.abs(start[axis]) > half[axis] then
				return false
			end
		else
			local a = (-half[axis] - start[axis]) / delta[axis]
			local b = (half[axis] - start[axis]) / delta[axis]
			low = math.max(low, math.min(a, b))
			high = math.min(high, math.max(a, b))
			if low > high then
				return false
			end
		end
	end
	return high >= low
end
local heroCamera = result.frame:PointToWorldSpace(rb.Vector3.new(0, 27, -33))
for _, suffix in { "L", "R" } do
	local tip = assert(sculpture:FindFirstChild("OuterHornTip" .. suffix))
	local clearSamples = 0
	local blockers: { [string]: boolean } = {}
	for _, t in { -0.45, 0, 0.45 } do
		local target = tip.CFrame * rb.Vector3.new(0, tip.Size.Y * t, 0)
		local blocked = false
		for _, p in all do
			if
				p:IsA("BasePart")
				and p ~= tip
				and p.Transparency < 0.95
				and segmentHitsBox(heroCamera, target, p)
			then
				blocked = true
				blockers[p.Name] = true
			end
		end
		if not blocked then
			clearSamples += 1
		end
	end
	local names = {}
	for name in blockers do
		table.insert(names, name)
	end
	table.sort(names)
	check(
		clearSamples > 0,
		"outer horn "
			.. suffix
			.. " fully blocked from hero camera by opaque OBBs: "
			.. table.concat(names, ", ")
	)
end
check(
	sculpture.MuzzleRoot.Size.X > sculpture.MuzzleMiddle.Size.X
		and sculpture.MuzzleMiddle.Size.X > sculpture.MuzzleTip.Size.X,
	"broad muzzle still tapers toward nose"
)
check(
	sculpture.MuzzleRoot.Size.X >= dragon.Head.Size.X * 0.85,
	"broadened muzzle supports head silhouette"
)

-- Vertical ray/OBB slab intersection. Ground discs use bounding boxes, so this
-- is an estimate; marker support is also manually constrained inside crater r24.
local function supported(point: any): boolean
	for _, p in floors do
		if not p:IsA("BasePart") then
			continue
		end
		local origin = p.CFrame:PointToObjectSpace(point)
		local direction = p.CFrame:VectorToObjectSpace(rb.Vector3.new(0, -1, 0))
		local half = p.Size / 2
		local low, high = 0, 8
		for _, axis in { "X", "Y", "Z" } do
			local o, d, extent = origin[axis], direction[axis], half[axis]
			if math.abs(d) < 0.00001 then
				if math.abs(o) > extent then
					high = -1
				end
			else
				local a, b = (-extent - o) / d, (extent - o) / d
				low = math.max(low, math.min(a, b))
				high = math.min(high, math.max(a, b))
			end
		end
		if high >= low then
			return true
		end
	end
	return false
end
local function clearBody(point: any, label: string)
	for _, p in all do
		if not p:IsA("BasePart") or not p.CanCollide then
			continue
		end
		local localPoint = p.CFrame:PointToObjectSpace(point)
		local half = p.Size / 2 + rb.Vector3.new(0.75, 0.75, 0.75)
		check(
			not (
					math.abs(localPoint.X) < half.X
					and math.abs(localPoint.Y) < half.Y
					and math.abs(localPoint.Z) < half.Z
				),
			label .. " obstructed by " .. p.Name
		)
	end
end
for name, p in actions do
	check(supported(p.CFrame.Position), name .. " lacks floor within 8 studs")
	clearBody(p.CFrame.Position + rb.Vector3.new(0, 1, 0), name)
end
for _, p in floors do
	if p:IsA("BasePart") then
		check(p.CanCollide, "walkable floor must collide")
		if
			p.Name:match("^TrialTread")
			or p.Name:match("^VolcanoRamp%d+$")
			or p.Name == "CinderShortcutLanding"
			or p.Name == "FissureFloor"
		then
			for step = -4, 4 do
				local sample = p.CFrame * rb.Vector3.new(0, 0, p.Size.Z * step / 10)
				clearBody(sample + rb.Vector3.new(0, 3, 0), p.Name)
			end
		end
	end
end

local caveOwner = result.root:FindFirstChild("DragonCaveArchitecture")
check(caveOwner ~= nil, "explicit cave ownership")
for _, p in caveOwner.BlackInterior:GetDescendants() do
	if p:IsA("BasePart") then
		for _, x in { -1, 1 } do
			for _, y in { -1, 1 } do
				for _, z in { -1, 1 } do
					local corner = result.frame:PointToObjectSpace(
						p.CFrame * (p.Size * rb.Vector3.new(x, y, z) / 2)
					)
					check(
						math.sqrt(corner.X ^ 2 + corner.Z ^ 2) <= 80,
						"black enclosure exceeds original mountain foot: " .. p.Name
					)
				end
			end
		end
	end
end
for _, p in floors do
	if p:IsA("BasePart") and p.Name:match("^VolcanoRamp%d+$") then
		check(
			p.Material == rb.Enum.Material.Cobblestone and p.Color ~= rb.Color3.new(0, 0, 0),
			"spiral must be visible physical stone"
		)
	end
end

local head = dragon:FindFirstChild("Head")
local snout = dragon:FindFirstChild("Snout")
local forward = (snout.CFrame.Position - head.CFrame.Position).Unit
local approach = (worldcraft.volcanoApproach(result.centre) - head.CFrame.Position).Unit
check(forward:Dot(approach) > 0.85, "dragon must face entrance")
for name, rate in { EmberBrazier = 6, ForgeAnvil = 8, CraterSource = 18 } do
	check(actions[name]:GetAttribute("VolcanoCultivationRate") == rate, name .. " cultivation rate")
end
print(
	`Volcano construction QA: {count} checks; {#all} decor / {#floors} ground descendants. Not engine physics acceptance.`
)
local partCount, meshCount, lightCount = 0, 0, 0
for _, collection in { all, floors } do
	for _, instance in collection do
		if instance:IsA("BasePart") then
			partCount += 1
		end
		if instance:IsA("DataModelMesh") or instance:IsA("MeshPart") then
			meshCount += 1
		end
		if instance:IsA("Light") then
			lightCount += 1
		end
	end
end
print(
	`Volcano construction cost: {partCount} BaseParts; {meshCount} mesh instances; {lightCount} lights. Counts are not a performance measurement.`
)
