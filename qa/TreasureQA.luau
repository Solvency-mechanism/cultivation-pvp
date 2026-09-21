--!strict
-- Explicit isolated Studio lab. Invoked by QA-only server BindableFunction.
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Server = game:GetService("ServerScriptService"):WaitForChild("Server")
local HttpService = game:GetService("HttpService")
local Cultivation = require(Server.CultivationService)
local Service = require(Server.TreasureService)
local CombatService = require(Server.CombatService)
local Progression = require(ReplicatedStorage.Shared.Progression)
local Treasures = require(ReplicatedStorage.Shared.Treasures)
local Config = require(ReplicatedStorage.Shared.Config)
local QA = {}
local running = false
function QA.run(player: Player): any
	assert(
		RunService:IsStudio() and RunService:IsServer() and not running,
		"Studio server only; one run at a time"
	)
	local saved = assert(
		Cultivation.getState(player),
		"Run via TreasureQACommand bridge after player state loads"
	)
	saved = Progression.sanitizeState(Config, Progression.toStore(saved))
	local character = assert(player.Character, "Character missing")
	local root = assert(character:FindFirstChild("HumanoidRootPart"), "Root missing") :: BasePart
	local humanoid = assert(character:FindFirstChildOfClass("Humanoid"), "Humanoid missing")
	local originalFrame, originalAnchored = root.CFrame, root.Anchored
	local report: any = {
		passed = 0,
		failed = 0,
		checks = {},
		evidence = "Isolated Studio service lab with temporary player-state seeding; local serialization only, not backend save acceptance",
	}
	local lab = Instance.new("Folder")
	lab.Name = "TreasureQALab"
	lab.Parent = Workspace
	local registered: { Model } = {}
	local function check(ok: boolean, name: string)
		table.insert(report.checks, { name = name, ok = ok })
		if ok then
			report.passed += 1
		else
			report.failed += 1
		end
		print(`[Treasure QA check] {if ok then "PASS" else "FAIL"} {name}`)
	end
	local function state(): any
		return assert(Cultivation.getState(player), "State disappeared")
	end
	local function collection(): any
		return Treasures.sanitize(state().treasures)
	end
	local function seed(owned: any, equipped: any, fire: number?)
		Cultivation.updateState(player, function(current)
			local nextState = Progression.sanitizeState(Config, Progression.toStore(current))
			nextState.treasures = Treasures.sanitize({ owned = owned, equipped = equipped })
			nextState.core.raw = { ash = fire or 200, verdant = 0, lumen = 0, neutral = 0 }
			nextState.expedition.cinderStep = true
			return nextState
		end)
		Service.resetCharge(player)
		Service.step(os.clock(), 0)
		CombatService.tick(0, os.clock())
	end
	local function request(payload: any)
		task.wait(0.25)
		Service.handle(player, payload)
	end
	local function part(name: string, size: Vector3, position: Vector3): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.Position = position
		p.Anchored = true
		p.Parent = lab
		return p
	end
	local base = Vector3.new(600, 12, 600)
	running = true
	local ok, err = pcall(function()
		part("Support", Vector3.new(90, 1, 90), base - Vector3.new(0, 3.5, 0))
		root.Anchored = false
		root.CFrame = CFrame.new(base)
		root.AssemblyLinearVelocity = Vector3.zero
		task.wait(0.5)
		seed({}, {})
		local marker = part("LabDiscovery", Vector3.one, base + Vector3.new(4, 0, 0))
		marker.CanCollide = false
		marker:SetAttribute("TreasureDiscovery", true)
		marker:SetAttribute("TreasureId", "wind_chime")
		Service.discover(player, marker)
		check(collection().owned.wind_chime == true, "near discovery grants via real service")
		local count = 0
		for _ in collection().owned do
			count += 1
		end
		Service.discover(player, marker)
		local after = 0
		for _ in collection().owned do
			after += 1
		end
		check(count == after, "duplicate discovery does not grant again")
		seed({}, {})
		marker.Position = base + Vector3.new(30, 0, 0)
		Service.discover(player, marker)
		check(not collection().owned.wind_chime, "far discovery rejected")
		marker.Position = base + Vector3.new(6, 0, 0)
		local wall = part("Occluder", Vector3.new(1, 8, 8), base + Vector3.new(3, 0, 0))
		Service.discover(player, marker)
		check(not collection().owned.wind_chime, "wall discovery rejected")
		wall:Destroy()
		local all = {}
		for _, id in Treasures.Order do
			all[id] = true
		end
		seed(all, {})
		local baseSpeed = humanoid.WalkSpeed
		request({ action = "equip", id = "wind_chime", slot = 3 })
		CombatService.tick(0, os.clock())
		check(
			collection().equipped[3] == "wind_chime" and humanoid.WalkSpeed > baseSpeed,
			"slot3 equip applies movement modifier"
		)
		local stored = Progression.toStore(state())
		local restored = Progression.sanitizeState(Config, stored)
		check(
			restored.treasures.equipped[1] == "" and restored.treasures.equipped[3] == "wind_chime",
			"sparse slot3 survives local store roundtrip"
		)
		request({ action = "equip", id = "wind_chime", slot = 1 })
		check(
			collection().equipped[1] == "wind_chime" and collection().equipped[3] == "",
			"moving equipped item stays unique"
		)
		request({ action = "equip", id = "emberlung", slot = 4 })
		check(collection().equipped[4] == nil, "fourth slot rejected")
		request({ action = "equip", id = "unknown", slot = 2 })
		check(collection().equipped[2] == "", "unknown/unowned rejected")
		request({ action = "unequip", slot = 1 })
		CombatService.tick(0, os.clock())
		check(math.abs(humanoid.WalkSpeed - baseSpeed) < 0.1, "unequip restores movement modifier")
		seed(all, { "emberlung", "cascade_heart", "" }, 200)
		local target = Instance.new("Model")
		target.Name = "TreasureQATarget"
		target.Parent = lab
		local targetRoot =
			part("HumanoidRootPart", Vector3.new(3, 5, 3), base + Vector3.new(0, 0, -15))
		targetRoot.Parent = target
		local targetActor = assert(
			CombatService.registerCombatant(target, state().stageIndex, "dummy"),
			"Target registration failed"
		)
		table.insert(registered, target)
		local health = targetActor.health
		task.wait(0.25)
		local fire = state().core.raw.ash
		Service.handle(player, { action = "power", direction = Vector3.new(0, 0, -1) })
		check(
			math.abs(state().core.raw.ash - (fire - 30)) < 0.01,
			"breath atomically spends30 actual fire"
		)
		check(targetActor.health < health, "directed breath damages real registered target")
		local ready = player:GetAttribute("TreasurePowerReadyAt")
		check(
			typeof(ready) == "number" and ready > Workspace:GetServerTimeNow(),
			"accepted breath publishes cooldown"
		)
		fire = state().core.raw.ash
		request({ action = "power", direction = Vector3.new(0, 0, -1) })
		check(state().core.raw.ash >= fire, "cooldown rejects repeat spend")
		request({ action = "unequip", slot = 1 })
		check(collection().equipped[1] == "emberlung", "combat lock rejects swaps")
		task.wait(10.2)
		seed(all, { "emberlung", "cascade_heart", "" }, 0)
		request({ action = "power", direction = Vector3.new(0, 0, -1) })
		check(
			(player:GetAttribute("TreasurePowerReadyAt") or 0) <= Workspace:GetServerTimeNow(),
			"insufficient fire does not start cooldown"
		)
		seed(all, { "", "cascade_heart", "" }, 200)
		for _ = 1, 3 do
			CombatService.volcanoHeat(player, 0.1)
		end
		task.wait(0.2)
		-- Real normal cultivation ticks supply charge; no manual onCultivate calls.
		local began = time()
		local nextDiagnostic = began
		repeat
			task.wait(0.25)
			if time() >= nextDiagnostic then
				nextDiagnostic = time() + 1
				print("[Treasure Heart diagnostic] " .. HttpService:JSONEncode({
					elapsed = time() - began,
					position = tostring(root.Position),
					velocity = tostring(root.AssemblyLinearVelocity),
					move = tostring(humanoid.MoveDirection),
					floor = tostring(humanoid.FloorMaterial),
					sit = humanoid.Sit,
					health = humanoid.Health,
					charge = player:GetAttribute("TreasureCharge"),
					equipped = player:GetAttribute("TreasuresEquipped"),
					characterMatches = player.Character == character,
				}))
			end
		until (player:GetAttribute("TreasureCharge") or 0) >= 1 or time() - began > 14
		check(
			(player:GetAttribute("TreasureCharge") or 0) >= 1,
			"stationary actual cultivation ticks fully charge Heart"
		)
		local beforeStep = root.Position
		local healthBeforeStep = humanoid.Health
		local authoritativeBeforeStep = player:GetAttribute("Health") :: number
		local client = assert(
			ReplicatedStorage:FindFirstChild("TreasureQAClient"),
			"QA client relay missing"
		) :: RemoteEvent
		client:FireClient(player, "cinder", Vector3.xAxis)
		task.wait(0.6)
		local authoritativeAfterStep = player:GetAttribute("Health") :: number
		local healDelta = authoritativeAfterStep - authoritativeBeforeStep
		print("[Treasure Heart heal] " .. HttpService:JSONEncode({
			before = authoritativeBeforeStep,
			after = authoritativeAfterStep,
			humanoidBefore = healthBeforeStep,
			humanoidAfter = humanoid.Health,
			delta = healDelta,
			maxHealth = humanoid.MaxHealth,
			chargeAfter = player:GetAttribute("TreasureCharge"),
		}))
		check((root.Position - beforeStep).Magnitude > 2, "real Cinder Step action succeeded")
		check(
			(player:GetAttribute("TreasureCharge") or 0) < 1
				and math.abs(healDelta - humanoid.MaxHealth * 0.2) <= 1,
			"successful dash consumes charge and heals authoritative health exactly20%"
		)
		Service.resetCharge(player)
		task.wait(3.2)
		check(
			(player:GetAttribute("TreasureCharge") or 0) > 0,
			"Heart recharges through ordinary ticks"
		)
		root.CFrame += Vector3.new(2, 0, 0)
		task.wait(1.2)
		check((player:GetAttribute("TreasureCharge") or 0) < 0.2, "movement resets charge")
		report.multiplayerHealing =
			"Not exercised by one-player lab; same-team and hostility require separate player coverage"
	end)
	report.ok = ok and report.failed == 0
	report.error = if ok then nil else tostring(err)
	for _, model in registered do
		CombatService.unregisterCombatant(model)
	end
	Service.resetCharge(player)
	Cultivation.updateState(player, function()
		return saved
	end)
	-- Restore health through the same bounded heal implementation, then original pose.
	for _ = 1, 5 do
		CombatService.treasureHeal(player)
	end
	root.CFrame = originalFrame
	root.Anchored = originalAnchored
	root.AssemblyLinearVelocity = Vector3.zero
	lab:Destroy()
	running = false
	Service.step(os.clock(), 0)
	CombatService.tick(0, os.clock())
	local compact = table.clone(report)
	compact.checks = nil
	print("[Treasure QA] " .. HttpService:JSONEncode(compact))
	Workspace:SetAttribute("TreasureQAReport", HttpService:JSONEncode(report))
	return compact
end
return QA
