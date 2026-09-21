--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local Treasures = require(ReplicatedStorage.Shared.Treasures)
local CultivationService = require(script.Parent.CultivationService)
local CombatService = require(script.Parent.CombatService)
local TreasureService = {}
local requests: { [Player]: number } = {}
local cooldowns: { [Player]: number } = {}
local charge: { [Player]: number } = {}
local positions: { [Player]: Vector3 } = {}
local published: { [Player]: string } = {}
local feedback: RemoteEvent? = nil
local function tell(player: Player, ok: boolean, message: string, discovered: string?)
	if feedback then
		feedback:FireClient(player, { ok = ok, message = message, discovered = discovered })
	end
end
local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	return if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then root else nil
end
local function publish(player: Player)
	local state = CultivationService.getState(player)
	if not state then
		return
	end
	local collection = Treasures.sanitize(state.treasures)
	local owned = {}
	for _, id in Treasures.Order do
		if collection.owned[id] then
			table.insert(owned, id)
		end
	end
	local encoded = HttpService:JSONEncode({ owned, collection.equipped })
	if published[player] ~= encoded then
		published[player] = encoded
		player:SetAttribute("TreasuresOwned", HttpService:JSONEncode(owned))
		player:SetAttribute("TreasuresEquipped", HttpService:JSONEncode(collection.equipped))
	end
	player:SetAttribute("TreasureCharge", (charge[player] or 0) / 10)
end
function TreasureService.resetCharge(player: Player)
	charge[player] = 0
	positions[player] = nil
	player:SetAttribute("TreasureCharge", 0)
end
function TreasureService.onCultivate(player: Player, dt: number)
	local state = CultivationService.getState(player)
	local root = rootOf(player)
	if not state or not root or not Treasures.has(state.treasures, "cascade_heart") then
		TreasureService.resetCharge(player)
		return
	end
	local previous: Vector3? = positions[player]
	positions[player] = root.Position
	local character = root.Parent
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local still = previous ~= nil
		and (root.Position - previous).Magnitude < 0.3
		and root.AssemblyLinearVelocity.Magnitude < 1
		and humanoid ~= nil
		and humanoid.MoveDirection.Magnitude < 0.05
		and humanoid.FloorMaterial ~= Enum.Material.Air
		and not humanoid.Sit
	charge[player] = if still then math.min(10, (charge[player] or 0) + math.min(dt, 1)) else 0
	publish(player)
end
function TreasureService.onDash(player: Player)
	local state = CultivationService.getState(player)
	if
		state
		and (charge[player] or 0) >= 10
		and Treasures.has(state.treasures, "cascade_heart")
		and rootOf(player)
	then
		TreasureService.resetCharge(player)
		CombatService.treasureHeal(player)
		local root = rootOf(player)
		if feedback and root then
			feedback:FireAllClients({ effect = "cascade_wave", origin = root.Position })
		end
		tell(player, true, "The Heart releases a restorative wave.")
	end
end
function TreasureService.discover(player: Player, marker: BasePart)
	if typeof(marker) ~= "Instance" or not marker:IsA("BasePart") then
		return
	end
	local root = rootOf(player)
	local id = marker:GetAttribute("TreasureId")
	if
		not root
		or not marker:IsDescendantOf(Workspace)
		or marker:GetAttribute("TreasureDiscovery") ~= true
		or typeof(id) ~= "string"
		or not Treasures.Catalog[id]
		or (root.Position - marker.Position).Magnitude > 10
	then
		return
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { root.Parent :: Instance }
	params.RespectCanCollide = true
	local hit = Workspace:Raycast(root.Position, marker.Position - root.Position, params)
	if hit and hit.Instance ~= marker then
		return
	end
	local granted = false
	CultivationService.updateState(player, function(state)
		state = table.clone(state)
		local collection, fresh = Treasures.grant(state.treasures, id)
		state.treasures = collection
		granted = fresh
		return state
	end)
	publish(player)
	tell(
		player,
		granted,
		if granted
			then "Discovered " .. Treasures.Catalog[id].name .. ". Equip it in your collection."
			else "Already in your collection.",
		if granted then id else nil
	)
end
function TreasureService.handle(player: Player, payload: any)
	if type(payload) ~= "table" then
		return
	end
	local now = os.clock()
	if now < (requests[player] or 0) then
		return
	end
	requests[player] = now + 0.2
	local state = CultivationService.getState(player)
	if not state or not rootOf(player) then
		return
	end
	if payload.action == "equip" or payload.action == "unequip" then
		if not CombatService.treasureCanSwap(player) then
			tell(player, false, "Change treasures outside combat.")
			return
		end
		local slot = payload.slot
		local id = if payload.action == "unequip" then "" else payload.id
		if
			type(slot) ~= "number"
			or slot ~= slot
			or math.abs(slot) == math.huge
			or type(id) ~= "string"
		then
			return
		end
		local changed = false
		CultivationService.updateState(player, function(current)
			current = table.clone(current)
			local collection, ok = Treasures.equip(current.treasures, id, slot)
			changed = ok
			current.treasures = collection
			return current
		end)
		if changed then
			TreasureService.resetCharge(player)
		end
		tell(
			player,
			changed,
			if changed
				then "Treasure slots updated."
				else "Choose an owned treasure and one of three slots."
		)
		publish(player)
	elseif payload.action == "power" then
		local direction = payload.direction
		if
			typeof(direction) ~= "Vector3"
			or direction.Magnitude ~= direction.Magnitude
			or direction.Magnitude < 0.01
			or direction.Magnitude == math.huge
		then
			return
		end
		if
			not Treasures.has(state.treasures, "emberlung")
			or not CombatService.canVolcanoAct(player)
			or now < (cooldowns[player] or 0)
		then
			tell(player, false, "Emberlung is not ready.")
			return
		end
		if state.core.raw.ash < 30 then
			tell(player, false, "Emberlung needs 30 fire mana.")
			return
		end
		local paid = false
		CultivationService.updateState(player, function(current)
			current = table.clone(current)
			current.core = table.clone(current.core)
			current.core.raw = table.clone(current.core.raw)
			if current.core.raw.ash >= 30 then
				current.core.raw.ash -= 30
				paid = true
			end
			return current
		end)
		if not paid then
			return
		end
		cooldowns[player] = now + 8
		player:SetAttribute("TreasurePowerReadyAt", Workspace:GetServerTimeNow() + 8)
		local accepted = CombatService.treasureBreath(player, direction.Unit)
		local root = rootOf(player)
		if accepted and feedback and root then
			feedback:FireAllClients({
				effect = "emberlung",
				origin = root.Position,
				direction = direction.Unit,
			})
		end
		tell(player, true, "Emberlung exhales.")
	end
end
function TreasureService.onVent(player: Player, direction: any): boolean
	local state = CultivationService.getState(player)
	if not state or not Treasures.has(state.treasures, "emberlung") then
		return false
	end
	TreasureService.handle(player, { action = "power", direction = direction })
	return true
end
function TreasureService.step(_now: number, _dt: number)
	for _, player in Players:GetPlayers() do
		if not rootOf(player) then
			TreasureService.resetCharge(player)
		end
		publish(player)
	end
end
function TreasureService.start()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local action = remotes:WaitForChild("TreasureAction") :: RemoteEvent
	feedback = remotes:WaitForChild("TreasureFeedback") :: RemoteEvent
	action.OnServerEvent:Connect(TreasureService.handle)
	local function register(object: Instance)
		if
			not object:IsA("BasePart")
			or object:GetAttribute("TreasureDiscovery") ~= true
			or object:FindFirstChild("TreasurePrompt")
		then
			return
		end
		local id = object:GetAttribute("TreasureId")
		if typeof(id) ~= "string" or not Treasures.Catalog[id] then
			return
		end
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "TreasurePrompt"
		prompt.ActionText = "Discover treasure"
		prompt.ObjectText = Treasures.Catalog[id].name
		prompt.MaxActivationDistance = 10
		prompt.HoldDuration = 0.6
		prompt.RequiresLineOfSight = true
		prompt.Parent = object
		prompt.Triggered:Connect(function(player)
			TreasureService.discover(player, object)
		end)
	end
	for _, object in Workspace:GetDescendants() do
		register(object)
	end
	Workspace.DescendantAdded:Connect(register)
	Players.PlayerRemoving:Connect(function(player)
		requests[player] = nil
		cooldowns[player] = nil
		charge[player] = nil
		positions[player] = nil
		published[player] = nil
	end)
end
return TreasureService
