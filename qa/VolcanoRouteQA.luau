--!strict
-- Real-engine spatial probes. These do not move a character or prove traversal.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local VolcanoRouteQA = {}

function VolcanoRouteQA.run()
	assert(RunService:IsStudio(), "Route QA is Studio-only")
	local decor = assert(Workspace:FindFirstChild("ArenaDecor"), "ArenaDecor missing")
	local root = assert(decor:FindFirstChild("VolcanoExperience"), "VolcanoExperience missing")
	local arenaGround = assert(Workspace:FindFirstChild("ArenaWalkable"), "ArenaWalkable missing")
	local ground = assert(arenaGround:FindFirstChild("VolcanoWalkable"), "VolcanoWalkable missing")
	local passed = 0
	local coverage: { [string]: number } =
		{ originalSpiral = 0, craterStairs = 0, authoredRoutes = 0, caveBoundary = 0 }
	local failures: { string } = {}
	local function check(ok: boolean, detail: string)
		if ok then
			passed += 1
		else
			table.insert(failures, detail)
		end
	end
	local floorParams = RaycastParams.new()
	floorParams.FilterType = Enum.RaycastFilterType.Include
	floorParams.FilterDescendantsInstances = { ground }
	floorParams.RespectCanCollide = true
	local exclusions: { Instance } = { arenaGround }
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclusions, player.Character)
		end
	end
	local probe = Instance.new("Part")
	probe.Name = "VolcanoRouteBodyProbe"
	probe.Size = Vector3.new(1.6, 3.6, 1.6)
	probe.Anchored = true
	probe.CanCollide = false
	probe.CanTouch = false
	probe.CanQuery = false
	probe.Transparency = 1
	probe.Parent = Workspace
	table.insert(exclusions, probe)
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = exclusions
	overlap.RespectCanCollide = true
	local function sample(label: string, origin: Vector3)
		local hit = Workspace:Raycast(origin, Vector3.new(0, -10, 0), floorParams)
		check(hit ~= nil, `{label}: no walkable support below {origin}`)
		if not hit then
			return
		end
		check(hit.Normal.Y >= 0.5, `{label}: steep floor normal {hit.Normal} at {hit.Position}`)
		probe.CFrame = CFrame.new(hit.Position + Vector3.new(0, 2.7, 0))
		local collisions = Workspace:GetPartsInPart(probe, overlap)
		local names: { string } = {}
		for _, p in collisions do
			table.insert(names, p:GetFullName())
		end
		check(
			#collisions == 0,
			`{label}: body at {probe.Position} obstructed by {table.concat(names, ", ")}`
		)
	end
	for _, p in root:GetDescendants() do
		if p:IsA("BasePart") and p:GetAttribute("VolcanoAction") then
			sample("marker " .. p.Name, p.Position + Vector3.new(0, 2, 0))
		end
	end
	-- The full fissure is sampled through its shell opening; trial treads and
	-- shortcut platforms are checked against dragon solids and mountain facets.
	for _, p in ground:GetDescendants() do
		if not p:IsA("BasePart") then
			continue
		end
		if
			p.Name == "AshPilgrimRoad"
			or p.Name:match("^VolcanoRamp%d+$")
			or p.Name:match("^VolcanoCraterStair%d+$")
			or p.Name:match("^VolcanoTunnelFloor")
			or p.Name == "SanctuaryEntry"
			or p.Name == "FissureFloor"
			or p.Name:match("^RefugePath")
			or p.Name == "RefugeFloor"
			or p.Name:match("^TrialTread")
			or p.Name == "TrialLanding"
			or p.Name == "CinderShortcutLanding"
			or p.Name == "ShortcutDescent"
			or p.Name == "DragonAudiencePath"
		then
			local category = if p.Name:match("^VolcanoRamp%d+$")
				then "originalSpiral"
				elseif p.Name:match("^VolcanoCraterStair%d+$") then "craterStairs"
				else "authoredRoutes"
			coverage[category] += 1
			for step = -4, 4 do
				local point = p.CFrame * Vector3.new(0, 0, p.Size.Z * step / 10)
				sample(`route {p.Name}[{step}]`, point + Vector3.new(0, 4, 0))
			end
		end
	end
	check(
		coverage.originalSpiral == 64,
		`original spiral coverage: expected 64 slabs, found {coverage.originalSpiral}`
	)
	check(
		coverage.craterStairs == 6,
		`crater stair coverage: expected 6 steps, found {coverage.craterStairs}`
	)
	-- Visual enclosure probes use CanQuery, separately from physical clearance.
	-- They catch visible backside/head leaks even when the black cave intentionally
	-- has noncolliding scenic walls. They do not claim exterior ground traversal.
	local offer = root:FindFirstChild("DragonOffer", true)
	local head = root:FindFirstChild("Head", true)
	local centre = root:GetAttribute("Centre")
	check(
		offer ~= nil
			and offer:IsA("BasePart")
			and head ~= nil
			and head:IsA("BasePart")
			and typeof(centre) == "Vector3",
		"cave boundary frame/head missing"
	)
	if
		offer
		and offer:IsA("BasePart")
		and head
		and head:IsA("BasePart")
		and typeof(centre) == "Vector3"
	then
		local frame = CFrame.new(centre) * offer.CFrame.Rotation
		local headAt = frame:PointToObjectSpace(head.Position)
		-- The rear black slab is a scenic pedestal below/behind the sculpture,
		-- not a path through its neck. Require that intent in production metadata
		-- AND a physical audience boundary; merely dropping failed probes is not
		-- sufficient evidence. This checks walking clearance, not jump prevention.
		local caveFloor = ground:FindFirstChild("DragonCaveFloor", true)
		check(
			caveFloor ~= nil
				and caveFloor:GetAttribute("VolcanoScenicFloor") == true
				and caveFloor:GetAttribute("VolcanoVisitorMaxZ") == 29,
			"cave floor lacks explicit visitor/scenic boundary contract"
		)
		for _, z in { 18, 22, 26, 28 } do
			for _, x in { -6, 0, 6 } do
				sample(`visitor audience x{x} z{z}`, frame:PointToWorldSpace(Vector3.new(x, 5, z)))
			end
		end
		local boundaryParams = RaycastParams.new()
		boundaryParams.FilterType = Enum.RaycastFilterType.Include
		boundaryParams.FilterDescendantsInstances = { root, ground }
		boundaryParams.RespectCanCollide = true
		for _, x in { -20, -10, 0, 10, 20 } do
			local start = frame:PointToWorldSpace(Vector3.new(x, 3, 29))
			local hit = Workspace:Raycast(
				start,
				frame:VectorToWorldSpace(Vector3.new(0, 0, 6)),
				boundaryParams
			)
			check(
				hit ~= nil and hit.Instance:GetAttribute("VolcanoVisitorBoundary") == true,
				`visitor boundary at x{x} does not prevent walking behind audience: {if hit
					then hit.Instance.Name
					else "no collision"}`
			)
		end
		local visualParams = RaycastParams.new()
		visualParams.FilterType = Enum.RaycastFilterType.Include
		visualParams.FilterDescendantsInstances = { root, ground }
		visualParams.RespectCanCollide = false
		for _, y in { 8, 24, 45 } do
			for _, side in { -1, 1 } do
				local origin = frame:PointToWorldSpace(Vector3.new(side * 160, y, headAt.Z))
				local target = frame:PointToWorldSpace(Vector3.new(0, y, headAt.Z))
				local hit = Workspace:Raycast(origin, target - origin, visualParams)
				coverage.caveBoundary += 1
				check(
					hit ~= nil
						and (
							hit.Instance:GetAttribute("VolcanoCaveOwned") == true
							or hit.Instance.Name:find("Cave", 1, true) ~= nil
							or hit.Instance.Name:find("VolcanoFacet", 1, true) ~= nil
						),
					`cave exterior side {side} height {y}: first visible surface {if hit
						then hit.Instance:GetFullName()
						else "none"}`
				)
			end
			local origin = frame:PointToWorldSpace(Vector3.new(0, y, 180))
			local target = frame:PointToWorldSpace(Vector3.new(0, y, headAt.Z))
			local hit = Workspace:Raycast(origin, target - origin, visualParams)
			coverage.caveBoundary += 1
			check(
				hit ~= nil
					and (
						hit.Instance:GetAttribute("VolcanoCaveOwned") == true
						or hit.Instance.Name:find("Cave", 1, true) ~= nil
						or hit.Instance.Name:find("VolcanoFacet", 1, true) ~= nil
					),
				`cave rear height {y}: first visible surface {if hit
					then hit.Instance:GetFullName()
					else "none"}`
			)
		end
	end
	probe:Destroy()
	local summary =
		`{passed} engine spatial checks passed; {#failures} failed. Spiral {coverage.originalSpiral}/64, stairs {coverage.craterStairs}/6, boundary rays {coverage.caveBoundary}/9. Studio geometry only, not character traversal.`
	Workspace:SetAttribute("VolcanoRouteQASummary", summary)
	Workspace:SetAttribute("VolcanoRouteQAStatus", if #failures == 0 then "Passed" else "Failed")
	Workspace:SetAttribute("VolcanoRouteQAFailures", table.concat(failures, "\n"))
	print("[Volcano route QA] " .. summary)
	for _, failure in failures do
		warn("[Volcano route QA] " .. failure)
	end
	return { passed = passed, failed = #failures, summary = summary, failures = failures }
end

return VolcanoRouteQA
