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
			or p.Name:match("^VolcanoTunnelFloor")
			or p.Name == "SanctuaryEntry"
			or p.Name == "FissureFloor"
			or p.Name:match("^RefugePath")
			or p.Name == "RefugeFloor"
			or p.Name:match("^TrialTread")
			or p.Name == "TrialLanding"
			or p.Name == "CinderShortcutLanding"
			or p.Name == "ShortcutDescent"
		then
			for step = -4, 4 do
				local point = p.CFrame * Vector3.new(0, 0, p.Size.Z * step / 10)
				sample(`route {p.Name}[{step}]`, point + Vector3.new(0, 4, 0))
			end
		end
	end
	probe:Destroy()
	local summary =
		`{passed} engine spatial checks passed; {#failures} failed. Raycast support and exact part overlap; not character traversal.`
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
