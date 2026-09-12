--!strict
-- Explicitly invoked Studio QA, never an automatic production script.
-- run(player, optionalRouteName) uses ONE disclosed setup relocation per route,
-- then only Humanoid:MoveTo. No waypoint teleports, speed changes or forced jumps.
-- This proves automated controller contact, not human or physical-device play.
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local Traversal = {}
local running = false
local TIMEOUT = 8
local function coordinates(point: Vector3): { number }
	return {
		math.round(point.X * 100) / 100,
		math.round(point.Y * 100) / 100,
		math.round(point.Z * 100) / 100,
	}
end

function Traversal.run(player: Player, selectedRoute: string?): any
	assert(RunService:IsStudio(), "Traversal QA is Studio-only")
	assert(not running, "A traversal run is already active")
	local character = assert(player.Character, "Player has no character")
	local humanoid = assert(character:FindFirstChildOfClass("Humanoid"), "Humanoid missing")
	local rootInstance = assert(character:FindFirstChild("HumanoidRootPart"), "Root missing")
	assert(rootInstance:IsA("BasePart"), "Root is not a BasePart")
	local root = rootInstance :: BasePart
	assert(humanoid.Health > 0, "Player must be alive")
	local arenaGround = assert(Workspace:FindFirstChild("ArenaWalkable"), "Arena ground missing")
	local ground = assert(arenaGround:FindFirstChild("VolcanoWalkable"), "Volcano ground missing")
	local function part(name: string): BasePart
		local found = assert(ground:FindFirstChild(name, true), "Missing route geometry " .. name)
		assert(found:IsA("BasePart"), name .. " is not a BasePart")
		return found
	end
	local routes: { { name: string, parts: { BasePart } } } = {
		{ name = "spiral_crater", parts = {} },
		{ name = "crater_ascent", parts = {} },
		{ name = "sanctuary_trial", parts = {} },
	}
	for index = 1, 64 do
		table.insert(routes[1].parts, part("VolcanoRamp" .. index))
	end
	for index = 6, 1, -1 do
		table.insert(routes[1].parts, part("VolcanoCraterStair" .. index))
	end
	for index = 1, 6 do
		table.insert(routes[2].parts, part("VolcanoCraterStair" .. index))
	end
	for index = 1, 10 do
		table.insert(routes[3].parts, part("TrialTread" .. index))
	end
	table.insert(routes[3].parts, part("TrialLanding"))
	if selectedRoute then
		local exists = false
		for _, route in routes do
			if route.name == selectedRoute then
				exists = true
			end
		end
		assert(exists, "Unknown route; use spiral_crater, crater_ascent or sanctuary_trial")
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { ground }
	params.RespectCanCollide = true
	local function standingPoint(surface: BasePart, offset: number?): Vector3
		local candidate = surface.CFrame:PointToWorldSpace(Vector3.new(0, 0, offset or 0))
		local hit =
			Workspace:Raycast(candidate + Vector3.new(0, 8, 0), Vector3.new(0, -24, 0), params)
		assert(hit, "No support for waypoint " .. surface.Name)
		local legHeight = if humanoid.RigType == Enum.HumanoidRigType.R6 then 2 else 0
		return hit.Position
			+ Vector3.new(0, humanoid.HipHeight + root.Size.Y / 2 + legHeight + 0.1, 0)
	end
	local report: any = {
		evidence = "Studio Humanoid.MoveTo automated contact; not human traversal or physical device",
		routes = {},
		setupRelocations = 0,
		passed = 0,
		failed = 0,
		walkSpeed = humanoid.WalkSpeed,
		jumpPower = humanoid.JumpPower,
		jumpHeight = humanoid.JumpHeight,
		useJumpPower = humanoid.UseJumpPower,
		rigType = tostring(humanoid.RigType),
		timeoutSeconds = TIMEOUT,
	}
	running = true
	Workspace:SetAttribute("VolcanoTraversalCancel", false)
	Workspace:SetAttribute("VolcanoTraversalStatus", "Running")
	local start = time()
	local ok, err = pcall(function()
		for _, route in routes do
			if selectedRoute and route.name ~= selectedRoute then
				continue
			end
			if player.Character ~= character or humanoid.Health <= 0 then
				report.failed += 1
				report.error = "Character unavailable before next route"
				break
			end
			local result: any =
				{ name = route.name, waypoints = {}, setupRelocations = 1, completed = false }
			table.insert(report.routes, result)
			local setup = standingPoint(route.parts[1], route.parts[1].Size.Z * 0.3)
			root.Anchored = false -- smoke setup may have left the root anchored
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			root.CFrame = CFrame.new(setup) -- the ONLY relocation for this route
			report.setupRelocations += 1
			print(
				`[Volcano traversal setup] {route.name} one explicit relocation to {setup}; WalkSpeed unchanged at {humanoid.WalkSpeed}`
			)
			local settle = time()
			while time() - settle < 0.5 do
				RunService.Heartbeat:Wait()
			end
			for index, surface in route.parts do
				local target = standingPoint(surface)
				local before = root.Position
				local began = time()
				local reached = false
				local reason = "timeout"
				local minDistance = math.huge
				humanoid:MoveTo(target)
				while time() - began < TIMEOUT do
					if Workspace:GetAttribute("VolcanoTraversalCancel") == true then
						reason = "cancelled"
						break
					end
					if player.Character ~= character or humanoid.Health <= 0 then
						reason = "death_or_character_changed"
						break
					end
					local delta = root.Position - target
					local horizontal = Vector3.new(delta.X, 0, delta.Z).Magnitude
					minDistance = math.min(minDistance, horizontal)
					if
						horizontal <= 1.5
						and math.abs(delta.Y) <= 2
						and humanoid.FloorMaterial ~= Enum.Material.Air
					then
						reached = true
						reason = "grounded_arrival"
						break
					end
					if root.Position.Y < target.Y - 16 then
						reason = "fell_below_route"
						break
					end
					RunService.Heartbeat:Wait()
				end
				local step: any = {
					index = index,
					part = surface.Name,
					reached = reached,
					reason = reason,
					elapsedSeconds = math.round((time() - began) * 100) / 100,
					start = coordinates(before),
					target = coordinates(target),
					finish = coordinates(root.Position),
					closestHorizontal = if minDistance < math.huge then minDistance else -1,
					floorMaterial = tostring(humanoid.FloorMaterial),
					health = humanoid.Health,
				}
				table.insert(result.waypoints, step)
				Workspace:SetAttribute(
					"VolcanoTraversalProgress",
					`{route.name} {index}/{#route.parts} {surface.Name}: {reason}`
				)
				print("[Volcano traversal waypoint] " .. HttpService:JSONEncode(step))
				if not reached then
					report.failed += 1
					break
				end
				report.passed += 1
			end
			result.completed = #result.waypoints == #route.parts
				and result.waypoints[#result.waypoints].reached
			humanoid:MoveTo(root.Position)
			if not result.completed then
				break
			end -- preserve first failure; no rescue teleport
		end
	end)
	running = false
	if not ok then
		report.error = tostring(err)
		report.failed += 1
	end
	report.elapsedSeconds = math.round((time() - start) * 100) / 100
	report.status = if report.failed == 0 and #report.routes > 0 then "Passed" else "Failed"
	if humanoid.Parent and root.Parent then
		humanoid:MoveTo(root.Position)
	end
	local json = HttpService:JSONEncode(report)
	Workspace:SetAttribute("VolcanoTraversalStatus", report.status)
	Workspace:SetAttribute("VolcanoTraversalReport", json)
	print("[Volcano traversal report] " .. json)
	return report
end
return Traversal
