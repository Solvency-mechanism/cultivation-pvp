--!strict
-- Real builder, geometric construction evidence only; not engine physics.
local rb = require("@lune/roblox")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local env: any = table.clone(rb)
env.CFrame = table.clone(rb.CFrame)
env.CFrame.lookAt = function(at, target, up)
	local forward = (target - at).Unit
	local right = forward:Cross(up or rb.Vector3.yAxis).Unit
	return rb.CFrame.fromMatrix(at, right, right:Cross(forward), -forward)
end
local builder =
	luau.load(fs.readFile("src/server/PorcelainCascadeWorld.luau"), { environment = env })()
local function build()
	return builder.build({
		decor = rb.Instance.new("Folder"),
		ground = rb.Instance.new("Folder"),
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
	})
end
local result = build()
local checks = 0
local function check(ok, message)
	assert(ok, message)
	checks += 1
end
local function signature(value)
	local rows = {}
	for _, folder in { value.root, value.ground } do
		for _, p in folder:GetDescendants() do
			if p:IsA("BasePart") then
				table.insert(
					rows,
					p.Name
						.. tostring(p.CFrame)
						.. tostring(p.Size)
						.. tostring(p.Color)
						.. tostring(p.CanCollide)
				)
			end
		end
	end
	table.sort(rows)
	return table.concat(rows, "\n")
end
check(signature(result) == signature(build()), "deterministic authored construction")
local solids = {}
local waters = 0
local partCount = 0
local crownTop = -math.huge
local crownCount = 0
local ellipsoids = 0
local meshCount = 0
for _, folder in { result.root, result.ground } do
	for _, p in folder:GetDescendants() do
		if p:IsA("DataModelMesh") then
			meshCount += 1
		end
		if not p:IsA("BasePart") then
			continue
		end
		partCount += 1
		check(
			not p:IsA("Part") or p.Shape ~= rb.Enum.PartType.Ball,
			"anisotropic geometry must not use engine-uniform Ball shape"
		)
		if p:GetAttribute("CascadeEllipsoid") then
			ellipsoids += 1
			local mesh = p:FindFirstChildOfClass("SpecialMesh")
			check(
				p.Shape == rb.Enum.PartType.Block
					and mesh ~= nil
					and mesh.MeshType == rb.Enum.MeshType.Sphere
					and mesh.Scale == rb.Vector3.one,
				"declared ellipsoid uses size-scaled Sphere mesh renderer"
			)
		end
		check(p.Anchored, "anchored " .. p.Name)
		if p:GetAttribute("CascadeSourceShell") then
			crownCount += 1
			local cf, size = p.CFrame, p.Size
			local upper = cf.Position.Y
				+ (
						math.abs(cf.RightVector.Y) * size.X
						+ math.abs(cf.UpVector.Y) * size.Y
						+ math.abs(cf.LookVector.Y) * size.Z
					)
					/ 2
			crownTop = math.max(crownTop, upper)
		end
		local at = p.CFrame.Position
		check(
			math.abs(at.X) < 65 and at.Z > 100 and at.Z < 245 and at.Y < 65,
			"compact footprint " .. p.Name
		)
		if p:GetAttribute("CascadeWalkable") then
			check(
				p.CanCollide and p.CanQuery and p.Transparency == 0,
				"visible solid walkable " .. p.Name
			)
			if p.Shape == rb.Enum.PartType.Block then
				table.insert(solids, p)
			end
		elseif p:GetAttribute("CascadeNodeExclusion") then
			check(
				p.Name == "MineralOverhang" and p.CanQuery and not p.CanCollide,
				"only intentional roof query excludes node placement"
			)
		else
			check(
				not p.CanCollide and not p.CanQuery,
				"dressing cannot obstruct or intercept hits " .. p.Name
			)
		end
		if p:GetAttribute("CascadeWater") then
			waters += 1
			check(p.Transparency == 0 and not p.CanCollide, "opaque visual water " .. p.Name)
			local depth = p:GetAttribute("CascadeWaterDepth")
			if depth then
				check(depth > 0 and depth <= 1, "shallow readable pool")
				local bed =
					result.ground:FindFirstChild("MineralBed" .. p:GetAttribute("CascadeTier"))
				check(bed ~= nil and bed.CanCollide, "real pool bed")
				check(
					math.abs(
						(p.CFrame.Position.Y + p.Size.Y / 2)
							- (bed.CFrame.Position.Y + bed.Size.Y / 2)
							- depth
					) < 0.05,
					"water over correct solid bed"
				)
			end
		end
	end
end
check(waters >= 7, "seven pools plus visible cascades")
check(partCount <= 1100, "bounded static Cascade part budget")
check(ellipsoids > 0, "authored ellipsoid forms are explicitly tagged for renderer verification")
local rearSupport = result.root:FindFirstChild("SourceRearEscarpmentCore")
check(rearSupport ~= nil, "source crown has a rear mineral foundation")
check(
	rearSupport.CFrame.Position.Y - rearSupport.Size.Y / 2 <= 0.1
		and rearSupport.CFrame.Position.Y + rearSupport.Size.Y / 2 >= 41,
	"rear mineral support joins ground to source bed"
)
local unsupportedFoot = nil
for _, p in result.root:GetDescendants() do
	if p:IsA("BasePart") and p.Name == "SourceShellFoot" then
		local at = rearSupport.CFrame:PointToObjectSpace(p.CFrame.Position)
		if math.abs(at.X) > rearSupport.Size.X / 2 or math.abs(at.Z) > rearSupport.Size.Z / 2 then
			unsupportedFoot = p.Name
			break
		end
	end
end
check(unsupportedFoot == nil, "shell foot centres remain above grounded mineral backing")
check(
	crownCount > 1 and crownTop >= 56 and crownTop <= 63.5,
	"source crown rises approximately 15–22 studs above bed41"
)
for _, route in result.routes do
	for _, point in route do
		local blocker = nil
		for _, p in result.root:GetDescendants() do
			if
				p:IsA("BasePart")
				and p.Transparency < 0.9
				and not p:GetAttribute("CascadeWater")
			then
				local at = p.CFrame:PointToObjectSpace(point + rb.Vector3.new(0, 1, 0))
				if
					math.abs(at.X) < p.Size.X / 2
					and math.abs(at.Y) < p.Size.Y / 2
					and math.abs(at.Z) < p.Size.Z / 2
				then
					blocker = p.Name
					break
				end
			end
		end
		check(blocker == nil, "checkpoint torso clear of mineral dressing: " .. tostring(blocker))
	end
end
print(`Cascade static budget: {partCount} parts; {meshCount} meshes; crown top {crownTop}`)
-- Vertical ray/OBB intersection against real rectangular foundations and ramps.
local function floorAt(point)
	local best = nil
	for _, p in solids do
		local o = p.CFrame:PointToObjectSpace(point)
		local d = p.CFrame:VectorToObjectSpace(rb.Vector3.new(0, -1, 0))
		local near, far = 0, 12
		for _, axis in { "X", "Y", "Z" } do
			local half = p.Size[axis] / 2
			if math.abs(d[axis]) < 1e-8 then
				if math.abs(o[axis]) > half then
					far = -1
					break
				end
			else
				local a, b = (-half - o[axis]) / d[axis], (half - o[axis]) / d[axis]
				near = math.max(near, math.min(a, b))
				far = math.min(far, math.max(a, b))
			end
		end
		if far >= near and (best == nil or near < best) then
			best = near
		end
	end
	return best
end
local samples = 0
for name, route in result.routes do
	check(#route >= 9, "complete " .. name .. " route")
	for i = 1, #route - 1 do
		local a, b = route[i], route[i + 1]
		local delta = b - a
		check(
			math.abs(delta.Y) / rb.Vector3.new(delta.X, 0, delta.Z).Magnitude < 0.75,
			"normal walk slope"
		)
		for j = 0, math.ceil(delta.Magnitude / 1.5) do
			local point = a:Lerp(b, j / math.ceil(delta.Magnitude / 1.5))
			local distance = floorAt(point + rb.Vector3.new(0, 1, 0))
			check(
				distance ~= nil and distance < 6,
				"continuous ground " .. name .. " segment " .. i .. " sample " .. j
			)
			samples += 1
		end
	end
end
check(#result.pools == 7, "all seven pool standing points")
for _, point in result.pools do
	local distance = floorAt(point + rb.Vector3.new(0, 1, 0))
	check(distance ~= nil and distance < 5, "pool standing support")
end
print(
	`Cascade construction: {checks} passed; {samples} route samples. Not engine traversal acceptance.`
)
