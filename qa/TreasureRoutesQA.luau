--!strict
-- Manual Studio runner. No awards, prompt firing, invulnerability, or terrain edits.
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local QA = {}
local running = false
local ORDER = { "emberlung", "cascade_heart", "wind_chime", "iron_seed", "stillwater_pearl" }
local function data()
	local discover =
		assert(Workspace:FindFirstChild("TreasureDiscoveries", true), "Discoveries missing")
	local ember = discover:FindFirstChild("emberlung") :: BasePart
	assert(ember and ember:IsA("BasePart"), "Emberlung missing")
	-- Recover authored frame from its marker; no dependency on a separate service VM.
	local frame = ember.CFrame * CFrame.new(19, -2.6, -25)
	local function v(x: number, y: number, z: number): Vector3
		return frame:PointToWorldSpace(Vector3.new(x, y, z))
	end
	local routes = {
		emberlung = { v(0, 5, 12), v(-8, 4, 17), v(-15, 4, 21), v(-18, 4, 24) },
		cascade_heart = {
			Vector3.new(26.2, 37, 206),
			Vector3.new(19, 38, 206),
			Vector3.new(13, 38, 206),
			Vector3.new(7, 38, 209),
		},
		wind_chime = {
			Vector3.new(0, 3.7, 116),
			Vector3.new(-26, 5, 125),
			Vector3.new(-27.7, 6.7, 130),
			Vector3.new(-22.7, 6, 130),
		},
		iron_seed = { v(19, 4.5, 10), v(32, 4.5, 10), v(37, 4.9, 21), v(35, 4.9, 23) },
		stillwater_pearl = {
			Vector3.new(-36, 24, 174),
			Vector3.new(-31, 24.6, 174),
			Vector3.new(-28, 24.6, 175),
		},
	}
	return discover, routes
end
local function params(): RaycastParams
	local result = RaycastParams.new()
	result.FilterType = Enum.RaycastFilterType.Exclude
	result.RespectCanCollide = true
	local exclude: { Instance } = {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end
	result.FilterDescendantsInstances = exclude
	return result
end
local function sight(from: Vector3, marker: BasePart, rays: RaycastParams): boolean
	local hit = Workspace:Raycast(from, marker.Position - from, rays)
	return hit == nil or hit.Instance == marker
end
function QA.spatial()
	assert(RunService:IsStudio(), "Studio only")
	local discover, routes = data()
	local rays = params()
	local report: any = {
		passed = 0,
		failures = {},
		evidence = "Engine support/headroom/LOS queries; not traversal",
	}
	local function check(ok: boolean, label: string)
		if ok then
			report.passed += 1
		else
			table.insert(report.failures, label)
		end
	end
	for _, id in ORDER do
		local route = routes[id]
		local marker = discover:FindFirstChild(id) :: BasePart
		for step = 2, #route do
			local a, b = route[step - 1], route[step]
			local samples = math.max(1, math.ceil((b - a).Magnitude / 2))
			for index = 0, samples do
				local at = a:Lerp(b, index / samples)
				local label = id .. ":" .. step .. ":" .. index .. " " .. tostring(at)
				local hit =
					Workspace:Raycast(at + Vector3.new(0, 0.4, 0), Vector3.new(0, -7, 0), rays)
				check(hit ~= nil and math.abs(hit.Position.Y - (at.Y - 3)) < 2.6, label .. " floor")
				if hit then
					check(
						Workspace:Raycast(
							hit.Position + Vector3.new(0, 0.15, 0),
							Vector3.new(0, 5, 0),
							rays
						) == nil,
						label .. " headroom"
					)
				end
			end
		end
		check((route[#route] - marker.Position).Magnitude <= 10, id .. " prompt range")
		check(sight(route[#route], marker, rays), id .. " prompt LOS")
	end
	Workspace:SetAttribute("TreasureRouteSpatialReport", HttpService:JSONEncode(report))
	for _, failure in report.failures do
		warn("[Treasure route] " .. failure)
	end
	print("[Treasure spatial] passed=" .. report.passed .. " failed=" .. #report.failures)
	return report
end
function QA.walk(player: Player, onlyId: string?)
	assert(RunService:IsStudio() and not running, "Studio only; one runner at a time")
	local character = assert(player.Character, "Character missing")
	local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart
	assert(
		humanoid
			and root
			and humanoid.Health > 0
			and math.abs(humanoid.WalkSpeed - 16) < 0.01
			and not root.Anchored,
		"Requires living unanchored normal-speed character"
	)
	local discover, routes = data()
	assert(onlyId == nil or routes[onlyId] ~= nil, "Unknown route")
	local report: any = {
		passed = 0,
		failed = 0,
		setupRelocations = 0,
		routes = {},
		evidence = "Real MoveTo contacts; one explicit setup relocation per local approach. No prompts fired.",
	}
	running = true
	local ok, err = pcall(function()
		root:SetNetworkOwner(nil)
		for _, id in ORDER do
			if onlyId and id ~= onlyId then
				continue
			end
			local route = routes[id]
			local marker = discover:FindFirstChild(id) :: BasePart
			root.CFrame = CFrame.new(route[1]) -- disclosed local-entry setup only
			root.AssemblyLinearVelocity = Vector3.zero
			report.setupRelocations += 1
			task.wait(0.5)
			local record: any = { id = id, points = {}, reached = true }
			for index = 2, #route do
				local began = os.clock()
				humanoid:MoveTo(route[index])
				local reached = false
				repeat
					RunService.Heartbeat:Wait()
					local delta = root.Position - route[index]
					reached = Vector3.new(delta.X, 0, delta.Z).Magnitude < 1.35
						and math.abs(delta.Y) < 2.5
						and humanoid.FloorMaterial ~= Enum.Material.Air
				until reached
					or os.clock() - began > 8
					or humanoid.Health <= 0
					or player.Character ~= character
					or Workspace:GetAttribute("TreasureRouteCancel") == true
				table.insert(
					record.points,
					{ index = index, reached = reached, position = tostring(root.Position) }
				)
				if not reached or math.abs(humanoid.WalkSpeed - 16) > 0.01 then
					record.reached = false
					break
				end
			end
			record.distance = (root.Position - marker.Position).Magnitude
			record.lineOfSight = sight(root.Position, marker, params())
			record.promptPresent = marker:FindFirstChild("TreasurePrompt") ~= nil
			record.ok = record.reached
				and record.distance <= 10
				and record.lineOfSight
				and record.promptPresent
			if record.ok then
				report.passed += 1
			else
				report.failed += 1
			end
			table.insert(report.routes, record)
			print("[Treasure walk] " .. HttpService:JSONEncode(record))
			if
				humanoid.Health <= 0
				or player.Character ~= character
				or Workspace:GetAttribute("TreasureRouteCancel") == true
			then
				break
			end
		end
	end)
	if root.Parent then
		humanoid:MoveTo(root.Position)
		root:SetNetworkOwnershipAuto()
	end
	running = false
	report.ok = ok
	report.error = if ok then nil else tostring(err)
	Workspace:SetAttribute("TreasureRouteWalkReport", HttpService:JSONEncode(report))
	print(
		"[Treasure walk summary] passed="
			.. report.passed
			.. " failed="
			.. report.failed
			.. " error="
			.. tostring(report.error)
	)
	return report
end
return QA
