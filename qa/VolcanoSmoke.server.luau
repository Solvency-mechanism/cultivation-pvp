--!strict
-- Excluded from default.project.json. Studio-only smoke of REAL service entry points.
-- Relocations below are explicit QA setup, not traversal or physical-device proof.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")
assert(RunService:IsStudio(), "Volcano QA must never run outside Studio")
local Server = ServerScriptService:WaitForChild("Server")
local CultivationService = require(Server:WaitForChild("CultivationService"))
local VolcanoService = require(Server:WaitForChild("VolcanoService"))
local Progression = require(ReplicatedStorage.Shared.Progression)
local passed = 0
local details: { string } = {}
local function check(condition: boolean, name: string)
	assert(condition, name)
	passed += 1
	table.insert(details, name)
	Workspace:SetAttribute("VolcanoQASummary", `{passed} passed · {name}`)
end

local function run()
	Workspace:SetAttribute("VolcanoQAStatus", "Running")
	local deadline = time() + 60
	local player: Player? = nil
	while time() < deadline do
		player = Players:GetPlayers()[1]
		if
			player
			and CultivationService.getState(player)
			and Workspace:GetAttribute("VolcanoEpoch")
		then
			break
		end
		task.wait(0.2)
	end
	assert(player, "Player did not join within 60 seconds")
	local subject = player :: Player
	local characterDeadline = time() + 15
	while not subject.Character and time() < characterDeadline do
		task.wait(0.2)
	end
	local character = assert(subject.Character, "Character did not spawn within 15 seconds")
	local root = character:WaitForChild("HumanoidRootPart", 15) :: BasePart
	assert(root, "Character root missing")
	local routeModule = ServerScriptService:FindFirstChild("VolcanoRouteQA")
	if routeModule and routeModule:IsA("ModuleScript") then
		local routeResult = require(routeModule).run()
		assert(
			routeResult.failed == 0,
			routeResult.summary .. " " .. table.concat(routeResult.failures, " | ")
		)
	end
	local stations: { [string]: BasePart } = {}
	for _, object in Workspace:GetDescendants() do
		if object:IsA("BasePart") then
			local action = object:GetAttribute("VolcanoAction")
			if typeof(action) == "string" then
				stations[action] = object
			end
		end
	end
	for _, name in
		{ "forge", "purify", "dragon", "fissure", "trial_start", "trial_finish", "light_brazier" }
	do
		assert(stations[name], `Station missing: {name}`)
	end
	local function state(): any
		return assert(CultivationService.getState(subject), "Cultivation state missing")
	end
	local function edit(transform: (any) -> ())
		assert(
			CultivationService.updateState(subject, function(old)
				local nextState = Progression.toStore(old)
				transform(nextState)
				return nextState
			end),
			"State setup failed"
		)
	end
	local function move(position: Vector3)
		root.CFrame = CFrame.new(position)
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
	local function stationAction(name: string)
		task.wait(0.4)
		local station = stations[name]
		move(station.Position + Vector3.new(4, 3, 0))
		VolcanoService.interact(subject, name, station, nil)
	end
	local platform = Instance.new("Part")
	platform.Name = "QAOnlyPhysicsPlatform"
	platform.Anchored = true
	platform.Size = Vector3.new(70, 2, 70)
	platform.Position = Vector3.new(251, 180, -145)
	platform.Parent = Workspace
	local stand = platform.Position + Vector3.new(0, 4, 0)
	edit(function(s)
		s.core.raw = { ash = 240, verdant = 0, lumen = 0, neutral = 0 }
		s.progress = 0
		s.expedition = { solidFire = 0, cinderStep = false, dragonMet = false, discoveries = {} }
	end)
	move(stand)
	local before = state().core.raw.ash
	VolcanoService.interact(subject, "forge", stations.forge, nil)
	check(
		state().core.raw.ash == before and state().expedition.solidFire == 0,
		"far forge rejected"
	)
	stationAction("forge")
	check(state().expedition.solidFire == 30, "real forge creates 30 solid")
	stationAction("purify")
	check(state().progress >= 10, "real purification advances")
	stationAction("fissure")
	local solid = state().expedition.solidFire
	check(state().expedition.discoveries.fissure == true, "discovery recorded")
	stationAction("fissure")
	check(state().expedition.solidFire == solid, "repeat discovery pays nothing")
	task.wait(0.4)
	move(stand)
	before = state().core.raw.ash
	local priorPosition = root.Position
	VolcanoService.interact(subject, "cinder", nil, Vector3.xAxis)
	check(
		state().core.raw.ash == before and (root.Position - priorPosition).Magnitude < 0.1,
		"locked Cinder rejected"
	)
	stationAction("dragon")
	check(
		state().expedition.discoveries.offerPaid == true
			and state().expedition.solidFire == solid - 30,
		"dragon consumes one offering"
	)
	stationAction("dragon")
	check(state().expedition.solidFire == solid - 30, "dragon does not charge twice")
	stationAction("trial_start")
	stationAction("trial_finish")
	check(not state().expedition.cinderStep, "too-fast trial refused")
	task.wait(6.2)
	stationAction("trial_finish")
	check(state().expedition.cinderStep, "timed spatial trial unlocks Cinder")
	task.wait(0.4)
	move(stand)
	edit(function(s)
		s.core.raw.ash = 100
	end)
	VolcanoService.interact(subject, "cinder", nil, Vector3.xAxis)
	check(
		state().core.raw.ash == 75 and (root.Position - stand).Magnitude > 10,
		"Cinder spends 25 and moves through clear space"
	)
	task.wait(0.4)
	before = state().core.raw.ash
	priorPosition = root.Position
	VolcanoService.interact(subject, "cinder", nil, Vector3.xAxis)
	check(
		state().core.raw.ash == before and (root.Position - priorPosition).Magnitude < 0.1,
		"Cinder cooldown rejects repeated intent"
	)
	task.wait(6.2)
	move(stand)
	local wall = Instance.new("Part")
	wall.Name = "QAOnlyCinderWall"
	wall.Anchored = true
	wall.Size = Vector3.new(1, 12, 16)
	wall.Position = stand + Vector3.new(4, 0, 0)
	wall.Parent = Workspace
	before = state().core.raw.ash
	VolcanoService.interact(subject, "cinder", nil, Vector3.xAxis)
	check(
		state().core.raw.ash == before and (root.Position - stand).Magnitude < 0.1,
		"wall blocks Cinder before charging"
	)
	wall:Destroy()
	task.wait(0.4)
	move(stations.light_brazier.Position + Vector3.new(4, 3, 0))
	edit(function(s)
		s.core.raw.ash = 100
	end)
	VolcanoService.interact(subject, "vent", nil, Vector3.xAxis)
	check(
		state().core.raw.ash == 80 and state().expedition.discoveries.brazier,
		"paid Vent lights brazier without surcharge"
	)
	stationAction("light_brazier")
	check(
		stations.light_brazier:GetAttribute("Lit") == true,
		"returning discovery relights brazier"
	)
	local lights = 0
	for _, item in stations.light_brazier:GetChildren() do
		if item:IsA("PointLight") then
			lights += 1
		end
	end
	check(lights == 1, "brazier light does not duplicate")
	move(stations.dragon.Position + Vector3.new(0, 5, 5))
	root.Anchored = true -- Scenic inspection only after physics/service tests.
	platform:Destroy()
	Workspace:SetAttribute("VolcanoQAStatus", "Passed")
	Workspace:SetAttribute(
		"VolcanoQASummary",
		`{passed} checks passed · QA relocated character; traversal not proven`
	)
	Workspace:SetAttribute("VolcanoQADetails", table.concat(details, "\n"))
	print(
		`[volcano-qa] PASS {passed} checks. Real services and Roblox collision queries; explicit QA relocations, not player traversal.`
	)
end

task.spawn(function()
	local ok, problem = pcall(run)
	if not ok then
		Workspace:SetAttribute("VolcanoQAStatus", "Failed")
		Workspace:SetAttribute("VolcanoQASummary", `{passed} passed; FAILED: {tostring(problem)}`)
		warn(`[volcano-qa] FAIL after {passed}: {tostring(problem)}`)
	end
end)
