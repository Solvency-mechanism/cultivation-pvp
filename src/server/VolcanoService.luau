--!strict
-- Server-owned expedition interactions. Clients choose an action, never a reward or position.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local Volcano = require(ReplicatedStorage.Shared.Volcano)
local Progression = require(ReplicatedStorage.Shared.Progression)
local Config = require(ReplicatedStorage.Shared.Config)
local CultivationService = require(script.Parent.CultivationService)
local CombatService = require(script.Parent.CombatService)

local VolcanoService = {}
local feedback: RemoteEvent? = nil
local lastRequest: { [Player]: number } = {}
local cooldowns: { [Player]: { [string]: number } } = {}
local trials: { [Player]: { began: number, character: Model } } = {}
local braziers: { BasePart } = {}
local hazards: { BasePart } = {}
local lastHazard = 0
local elapsed = 0
local lastPublish = -1
local started = false

local function visible(root: BasePart, target: BasePart): boolean
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { root.Parent :: Instance, target }
	params.RespectCanCollide = true
	return Workspace:Raycast(root.Position, target.Position - root.Position, params) == nil
end

local function lightBrazier(station: BasePart)
	local seal = Workspace:FindFirstChild("VolcanoAshSeal", true)
	if seal and seal:IsA("BasePart") then
		seal.Transparency = 1
		seal.CanCollide = false
		seal.CanQuery = false
	end
	station:SetAttribute("Lit", true)
	station.Material = Enum.Material.Neon
	station.Color = Color3.fromRGB(255, 152, 55)
	local light = station:FindFirstChildOfClass("PointLight") or Instance.new("PointLight")
	light.Name = "BrazierLight"
	light.Color = station.Color
	light.Range = 24
	light.Brightness = 2
	light.Parent = station
end

local function tell(player: Player, message: string)
	if feedback then
		feedback:FireClient(player, message)
	end
end

local function livingRoot(player: Player): BasePart?
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if
		not humanoid
		or humanoid.Health <= 0
		or humanoid.Sit
		or not root
		or not root:IsA("BasePart")
	then
		return nil
	end
	return root
end

local function apply(player: Player, action: string): boolean
	local result: Volcano.Result? = nil
	CultivationService.updateState(player, function(state)
		local nextState, outcome = Volcano.act(Config, Progression, state, action)
		result = outcome
		return nextState
	end)
	if result then
		tell(player, result.message)
		return result.ok
	end
	return false
end

local function flare(position: Vector3, size: Vector3)
	local part = Instance.new("Part")
	part.Name = "FirePulse"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(255, 128, 42)
	part.Transparency = 0.65
	part.Shape = Enum.PartType.Ball
	part.Size = size
	part.Position = position
	part.Parent = Workspace
	Debris:AddItem(part, 0.25)
end

local function act(player: Player, action: string, station: BasePart?, direction: any)
	local now = Workspace:GetServerTimeNow()
	if now - (lastRequest[player] or -math.huge) < 0.3 then
		return
	end
	lastRequest[player] = now
	local root = livingRoot(player)
	if not root then
		return
	end
	if station then
		if
			not station:IsDescendantOf(Workspace)
			or (root.Position - station.Position).Magnitude > 14
			or not visible(root, station)
		then
			return
		end
	elseif action ~= "cinder" and action ~= "vent" then
		return -- Station actions only originate in a server prompt callback.
	end
	if action == "light_brazier" and station then
		local state = CultivationService.getState(player)
		if state and state.expedition.discoveries.brazier then
			lightBrazier(station)
			tell(player, "The brazier remembers your fire. The ash parts again.")
			return
		end
	end
	if action == "gather" then
		tell(
			player,
			"Stand on the ember ground to cultivate automatically. The exhale strengthens its fire aura."
		)
		return
	elseif action == "trial_start" then
		local state = CultivationService.getState(player)
		if not state or not state.expedition.discoveries.offerPaid then
			tell(player, "Bring 30 solid fire mana to the dragon before attempting its trial.")
			return
		end
		trials[player] = { began = now, character = root.Parent :: Model }
		player:SetAttribute("VolcanoTrialEnds", now + 90)
		tell(
			player,
			"Trial begun: climb to the far trial stone within 90 seconds. No technique is required."
		)
		return
	elseif action == "trial_finish" then
		local trial = trials[player]
		if
			not trial
			or trial.character ~= player.Character
			or now - trial.began < 6
			or now - trial.began > 90
		then
			tell(
				player,
				"Begin at the lower trial stone, then follow the climb to this stone within 90 seconds."
			)
			return
		end
		trials[player] = nil
		player:SetAttribute("VolcanoTrialEnds", nil)
		apply(player, "complete_trial")
		return
	elseif action == "refuge" and not Volcano.phase(elapsed).exhaling then
		tell(player, "The markings are dark. Watch this alcove when the mountain exhales.")
		return
	end
	if action == "cinder" or action == "vent" then
		if not CombatService.canVolcanoAct(player) then
			return
		end
		local playerCooldowns = cooldowns[player] or {}
		cooldowns[player] = playerCooldowns
		if now < (playerCooldowns[action] or 0) then
			tell(player, "Let your fire settle before using that again.")
			return
		end
		local forward = root.CFrame.LookVector
		if
			typeof(direction) == "Vector3"
			and direction.X == direction.X
			and direction.Z == direction.Z
		then
			local flat = Vector3.new(direction.X, 0, direction.Z)
			if flat.Magnitude > 0.1 and flat.Magnitude < math.huge then
				forward = flat.Unit
			end
		end
		forward = Vector3.new(forward.X, 0, forward.Z).Unit
		local distance = 16
		if action == "cinder" then
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { root.Parent :: Instance }
			params.RespectCanCollide = true
			local hit =
				Workspace:Blockcast(root.CFrame, Vector3.new(4, 5, 3), forward * distance, params)
			if hit then
				distance = math.max(0, hit.Distance - 1)
			end
			if distance < 2 then
				tell(player, "There is no clear space for Cinder Step.")
				return
			end
		end
		if not apply(player, action) then
			return
		end
		playerCooldowns[action] = now
			+ (if action == "cinder" then Volcano.Config.cinderCooldown else 4)
		player:SetAttribute(
			if action == "cinder" then "CinderReadyAt" else "VentReadyAt",
			playerCooldowns[action]
		)
		flare(
			root.Position,
			if action == "vent" then Vector3.new(10, 7, 10) else Vector3.new(4, 4, 4)
		)
		if action == "cinder" then
			CombatService.beginVolcanoAction(player)
			root.CFrame += forward * distance
		else
			CombatService.volcanoVent(player, root.Position, forward)
			for _, brazier in braziers do
				if
					(root.Position - brazier.Position).Magnitude <= 12 and visible(root, brazier)
				then
					lightBrazier(brazier)
					apply(player, "vent_brazier")
				end
			end
		end
		return
	end
	if apply(player, action) and action == "light_brazier" and station then
		lightBrazier(station)
	end
end

-- Server-only entry point shared by actual prompts/remotes and the excluded
-- Studio QA harness. Clients cannot supply stations through the remote.
VolcanoService.interact = act

local labels = {
	light_brazier = { "Awaken · 10 fire", "Ash-choked brazier" },
	refuge = { "Read the illuminated marks", "Cultivator's refuge" },
	fissure = { "Search", "Hidden fissure" },
	dragon = { "Speak / Offer 30 solid fire", "The mountain's keeper" },
	trial_start = { "Begin 90-second trial", "Lower trial stone" },
	trial_finish = { "Complete trial", "Upper trial stone" },
	purify = { "Purify 40 mana → 10 advancement", "Purification basin" },
	forge = { "Forge 40 fire → 30 solid", "Dragon's forge" },
	gather = { "Learn to cultivate", "Fire aura source" },
}

function VolcanoService.start()
	if started then
		return
	end
	started = true
	Workspace:SetAttribute("VolcanoEpoch", Workspace:GetServerTimeNow())
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	feedback = remotes:WaitForChild("VolcanoFeedback") :: RemoteEvent
	local remote = remotes:WaitForChild("VolcanoAction") :: RemoteEvent
	remote.OnServerEvent:Connect(function(player, action, direction)
		if typeof(action) == "string" and (action == "vent" or action == "cinder") then
			VolcanoService.interact(player, action, nil, direction)
		end
	end)
	for _, object in Workspace:GetDescendants() do
		if object:IsA("BasePart") then
			if object:GetAttribute("VolcanoHazard") then
				table.insert(hazards, object)
			end
			local action = object:GetAttribute("VolcanoAction")
			if typeof(action) == "string" and labels[action] then
				if action == "light_brazier" then
					table.insert(braziers, object)
				end
				local prompt = Instance.new("ProximityPrompt")
				prompt.Name = "VolcanoPrompt"
				prompt.ActionText = labels[action][1]
				prompt.ObjectText = labels[action][2]
				prompt.MaxActivationDistance = 11
				prompt.HoldDuration = 0.4
				prompt.RequiresLineOfSight = true
				prompt.Parent = object
				prompt.Triggered:Connect(function(player)
					VolcanoService.interact(player, action, object, nil)
				end)
			end
		end
	end
	Players.PlayerRemoving:Connect(function(player)
		lastRequest[player] = nil
		cooldowns[player] = nil
		trials[player] = nil
	end)
end

function VolcanoService.step(_now: number, _dt: number)
	elapsed = Workspace:GetServerTimeNow()
		- (Workspace:GetAttribute("VolcanoEpoch") or Workspace:GetServerTimeNow())
	local phase = Volcano.phase(elapsed)
	if elapsed - lastPublish < 0.2 then
		return
	end
	lastPublish = elapsed
	Workspace:SetAttribute("VolcanoPhase", phase.name)
	Workspace:SetAttribute("VolcanoExhaling", phase.exhaling)
	Workspace:SetAttribute("VolcanoIntensity", phase.intensity)
	local untilBreath = (Volcano.Config.exhaleStart - phase.elapsed) % Volcano.Config.cycleSeconds
	Workspace:SetAttribute("VolcanoNextBreath", Workspace:GetServerTimeNow() + untilBreath)
	local hazardActive = phase.exhaling and phase.elapsed >= Volcano.Config.exhaleStart + 3
	Workspace:SetAttribute("VolcanoHazardActive", hazardActive)
	if hazardActive and elapsed - lastHazard >= 1 then
		lastHazard = elapsed
		for _, player in Players:GetPlayers() do
			local root = livingRoot(player)
			if root then
				for _, hazard in hazards do
					local delta = hazard.CFrame:PointToObjectSpace(root.Position)
					if
						math.abs(delta.X) < hazard.Size.X / 2 + 1
						and math.abs(delta.Z) < hazard.Size.Z / 2 + 1
						and delta.Y >= 0
						and delta.Y < 9
					then
						CombatService.volcanoHeat(player, 0.06)
						break
					end
				end
			end
		end
	end
	for player, trial in trials do
		if
			not livingRoot(player)
			or trial.character ~= player.Character
			or Workspace:GetServerTimeNow() - trial.began > 90
		then
			trials[player] = nil
			player:SetAttribute("VolcanoTrialEnds", nil)
		end
	end
end

return VolcanoService
