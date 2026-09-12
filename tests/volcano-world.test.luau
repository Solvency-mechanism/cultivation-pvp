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
env.require = function()
	return worldcraft
end
env.script = { Parent = { Worldcraft = true } }
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
local count = 0
local function check(value: any, message: string)
	assert(value, message)
	count += 1
end
-- The cave must never crop or remodel the original sculpture.
local original = worldcraft.buildDragonHead(kit, rb.CFrame.identity, "OriginalDragonReference", 1.8)
local dragon = result.root:FindFirstChild("VolcanoDragon")
check(dragon ~= nil, "dragon exists")
for _, part in original:GetChildren() do
	if part:IsA("BasePart") then
		local actual = dragon:FindFirstChild(part.Name)
		check(actual ~= nil, "original dragon part preserved: " .. part.Name)
		check(
			actual.Size == part.Size
				and actual.Color == part.Color
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
check(jawParts == 8, "jaw, tongue and six lower teeth animate together")

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
