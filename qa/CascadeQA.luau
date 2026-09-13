--!strict
-- Explicit Studio checks; no auto execution or production state injection.
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local Server = game:GetService("ServerScriptService"):WaitForChild("Server")
local Arena = require(Server.ArenaService)

local QA = {}
local running = false
local function markers(): ({ BasePart }, { BasePart })
	local root = assert(Workspace:FindFirstChild("PorcelainCascade", true), "Cascade missing")
	local west, east = {}, {}
	for _, p in root:GetDescendants() do
		if p:IsA("BasePart") and p:GetAttribute("CascadeCheckpoint") then
			table.insert(if p:GetAttribute("CascadeRoute") == "west" then west else east, p)
		end
	end
	local function order(a: BasePart, b: BasePart): boolean
		return (a:GetAttribute("CascadeRouteIndex") :: number)
			< b:GetAttribute("CascadeRouteIndex") :: number
	end
	table.sort(west, order)
	table.sort(east, order)
	assert(#west > 1 and #east > 1, "Route markers missing")
	return west, east
end
function QA.spatial(): any
	assert(RunService:IsStudio(), "Studio only")
	local root = assert(Workspace:FindFirstChild("PorcelainCascade", true))
	local report: any =
		{ passed = 0, failures = {}, evidence = "Engine spatial queries; not walking acceptance" }
	local function check(ok: boolean, label: string)
		if ok then
			report.passed += 1
		else
			table.insert(report.failures, label)
		end
	end
	local params = RaycastParams.new()
	params.RespectCanCollide = true
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excluded: { Instance } = {}
	for _, p in game:GetService("Players"):GetPlayers() do
		if p.Character then
			table.insert(excluded, p.Character)
		end
	end
	params.FilterDescendantsInstances = excluded
	local probes = 0
	for _, p in root:GetDescendants() do
		if
			p:IsA("BasePart")
			and (p:GetAttribute("CascadeCheckpoint") or p:GetAttribute("CascadePool"))
		then
			probes += 1
			check(Arena.regionAt(p.Position) == "wellspring", p.Name .. ": wellspring")
			local hit =
				Workspace:Raycast(p.Position + Vector3.new(0, 1, 0), Vector3.new(0, -10, 0), params)
			check(hit ~= nil, p.Name .. ": solid support")
			local nodeY = Arena.groundYAt(p.Position)
			-- An overhang may legitimately select the upper walkable terrace.
			if nodeY then
				local nodePoint = Vector3.new(p.Position.X, nodeY, p.Position.Z)
				local support = Workspace:Raycast(
					nodePoint + Vector3.new(0, 0.1, 0),
					Vector3.new(0, -0.3, 0),
					params
				)
				check(
					support ~= nil
						and support.Instance:IsDescendantOf(
							assert(Workspace:FindFirstChild("ArenaWalkable"), "Ground missing")
						),
					p.Name .. ": node placement walkable support"
				)
				check(
					Workspace:Raycast(
						nodePoint + Vector3.new(0, 0.2, 0),
						Vector3.new(0, 5.5, 0),
						params
					) == nil,
					p.Name .. ": node headroom"
				)
			end
			if hit then
				local ceiling = Workspace:Raycast(
					hit.Position + Vector3.new(0, 0.2, 0),
					Vector3.new(0, 5.5, 0),
					params
				)
				check(ceiling == nil, p.Name .. ": standing headroom")
			end
		end
	end
	check(probes >= 20, "route/pool coverage")
	print("[Cascade spatial] " .. HttpService:JSONEncode(report))
	Workspace:SetAttribute("CascadeSpatialReport", HttpService:JSONEncode(report))
	return report
end
function QA.walk(player: Player, visitPools: boolean?): any
	assert(RunService:IsStudio() and not running, "Studio only / already running")
	local character = assert(player.Character, "Character missing")
	local humanoid = assert(character:FindFirstChildOfClass("Humanoid"))
	local root = assert(character:FindFirstChild("HumanoidRootPart")) :: BasePart
	assert(humanoid.Health > 0 and humanoid.WalkSpeed == 16, "Requires alive normal WalkSpeed 16")
	local west, east = markers()
	local route: any = {}
	local cascade = assert(Workspace:FindFirstChild("PorcelainCascade", true), "Cascade missing")
	for i, checkpoint in west do
		table.insert(route, checkpoint)
		if visitPools and i < #west then
			local pools = {}
			for _, p in cascade:GetDescendants() do
				if
					p:IsA("BasePart")
					and p:GetAttribute("CascadePool")
					and p.Position.Z >= checkpoint.Position.Z
					and p.Position.Z < west[i + 1].Position.Z
				then
					table.insert(pools, p)
				end
			end
			table.sort(pools, function(a, b)
				return a.Position.Z < b.Position.Z
			end)
			for _, pool in pools do
				local t = (pool.Position.Z - checkpoint.Position.Z)
					/ (west[i + 1].Position.Z - checkpoint.Position.Z)
				local bank = {
					Name = pool.Name .. "Bank",
					Position = checkpoint.Position:Lerp(west[i + 1].Position, t),
				}
				table.insert(route, bank)
				table.insert(route, pool)
				table.insert(route, bank)
			end
		end
	end
	for i = #east - 1, 1, -1 do
		table.insert(route, east[i])
	end
	local report: any = {
		passed = 0,
		failed = 0,
		setupRelocations = 1,
		walkSpeed = humanoid.WalkSpeed,
		points = {},
		evidence = "Real Humanoid.MoveTo controller contact; not human traversal",
	}
	running = true
	local ok, err = pcall(function()
		root.Anchored = false
		root.CFrame = CFrame.new(route[1].Position) -- ONE entry setup relocation; never between waypoints.
		root.AssemblyLinearVelocity = Vector3.zero
		task.wait(0.5)
		for _, p in route do
			local began = time()
			humanoid:MoveTo(p.Position)
			local reached = false
			repeat
				RunService.Heartbeat:Wait()
				local d = root.Position - p.Position
				reached = Vector3.new(d.X, 0, d.Z).Magnitude < 1.5
					and math.abs(d.Y) < 2.5
					and humanoid.FloorMaterial ~= Enum.Material.Air
			until reached
				or time() - began >= 8
				or humanoid.Health <= 0
				or player.Character ~= character
				or Workspace:GetAttribute("CascadeWalkCancel") == true
			table.insert(
				report.points,
				{ name = p.Name, reached = reached, seconds = time() - began }
			)
			if reached then
				report.passed += 1
			else
				report.failed += 1
				break
			end
		end
		-- Observe the existing service naturally, without granting mana or ticking it twice.
		local observation = QA.observe(player)
		report.cultivation = observation
		report.finalRegion = Arena.regionAt(root.Position)
	end)
	running = false
	report.ok = ok
	report.error = if ok then nil else tostring(err)
	local compact = table.clone(report)
	compact.points = nil
	for _, point in report.points do
		print("[Cascade waypoint] " .. HttpService:JSONEncode(point))
	end
	print("[Cascade walk] " .. HttpService:JSONEncode(compact))
	Workspace:SetAttribute("CascadeWalkReport", HttpService:JSONEncode(report))
	return report
end
function QA.observe(player: Player): any
	assert(RunService:IsStudio(), "Studio only")
	-- Published attributes come from the running service; command-bar requires can have separate module state.
	local function balance(): any
		local result: any = {
			total = 0,
			lumen = player:GetAttribute("Vessel_lumen"),
			capacity = player:GetAttribute("VesselCapacity"),
		}
		for _, key in { "ash", "verdant", "lumen", "neutral" } do
			local value = player:GetAttribute("Vessel_" .. key)
			if typeof(value) ~= "number" then
				result.available = false
				return result
			end
			result.total += value
		end
		result.available = true
		return result
	end
	local before = balance()
	task.wait(8)
	local after = balance()
	local report: any = {
		before = before,
		after = after,
		seconds = 8,
		evidence = "Published integer vessel attributes; no grant or duplicate service tick",
	}
	if before.available and after.available then
		report.lumenDelta = after.lumen - before.lumen
	end
	print("[Cascade cultivation] " .. HttpService:JSONEncode(report))
	return report
end
function QA.warden(): any
	assert(RunService:IsStudio(), "Studio only")
	local npc = assert(Workspace:FindFirstChild("Pool Warden", true), "PoolWarden missing")
	local root = assert(npc:FindFirstChild("HumanoidRootPart"), "Warden root missing") :: BasePart
	local report: any =
		{ samples = 0, unsupported = 0, minY = math.huge, maxY = -math.huge, seconds = 12 }
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { npc }
	params.RespectCanCollide = true
	local start = root.Position
	for _ = 1, 24 do
		local hit = Workspace:Raycast(root.Position, Vector3.new(0, -8, 0), params)
		report.samples += 1
		if not hit or math.abs(root.Position.Y - hit.Position.Y - 3) > 1 then
			report.unsupported += 1
		end
		report.minY = math.min(report.minY, root.Position.Y)
		report.maxY = math.max(report.maxY, root.Position.Y)
		task.wait(0.5)
	end
	report.displacement = (root.Position - start).Magnitude
	print("[Cascade warden] " .. HttpService:JSONEncode(report))
	return report
end
return QA
