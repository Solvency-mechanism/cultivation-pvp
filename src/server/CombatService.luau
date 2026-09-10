--!strict
--[[
	Binds the pure Combat rules to Roblox: actors, the UseTechnique remote, hit
	resolution, constructs, death and respawn.

	Server-authoritative throughout. The client sends a *slot name* and nothing
	else; cost, cooldown, target selection and damage are all resolved here.
	Every rule this applies comes from the Combat module, so this file stays a
	thin binding layer in the same shape as CultivationService.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Combat = require(ReplicatedStorage.Shared.Combat)
local Config = require(ReplicatedStorage.Shared.Config)
local Progression = require(ReplicatedStorage.Shared.Progression)
local CultivationService = require(script.Parent.CultivationService)
local NodeService = require(script.Parent.NodeService)

local CombatService = {}

type Construct = {
	id: string,
	ownerId: number,
	stageIndex: number,
	techId: string,
	position: Vector3,
	radius: number,
	damagePerTick: number,
	expiresAt: number,
	nextTickAt: number,
	part: BasePart,
}

local actors: { [number]: Combat.Actor } = {}
local loadouts: { [number]: { [string]: string } } = {}
local constructs: { Construct } = {}
local dying: { [number]: boolean } = {}
local lastRequestAt: { [number]: number } = {}

local techniqueFiredRemote: RemoteEvent? = nil
local impactRemote: RemoteEvent? = nil
local constructCounter = 0
local constructFolder: Folder? = nil

-- A refused request still costs the server work. The global cooldown already
-- caps legitimate use at one per 0.4s; this only blunts a flood of rejects.
local MIN_REQUEST_INTERVAL = 0.05

local CONSTRUCT_COLOR = Color3.fromRGB(255, 140, 90)

--[[ Techniques whose entire effect is the self-buff Combat.use already applied.
	Listed rather than inferred, so a new construct-backed forger technique
	fails loudly instead of silently doing nothing. ]]
local SELF_BUFF_FORGERS: { [string]: boolean } = { barrier = true }

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function playerFromInstance(instance: Instance): Player?
	local model = instance:FindFirstAncestorWhichIsA("Model")
	while model do
		local found = Players:GetPlayerFromCharacter(model)
		if found then
			return found
		end
		model = model:FindFirstAncestorWhichIsA("Model")
	end
	return nil
end

local function stageIndexOf(player: Player): number?
	local state = CultivationService.getState(player)
	return if state then state.stageIndex else nil
end

local function powerOf(player: Player): number
	local state = CultivationService.getState(player)
	if not state then
		return Config.Combat.referencePower
	end
	return Progression.effectivePower(Config, state)
end

--[[ The caster's terrain richness, which is what Ruler techniques scale on.
	Static aura geography currently only exists underneath nodes, so standing in
	one is the only way to be anywhere but "open" -- which conveniently means the
	terrain-scaled techniques peak exactly where the fights are. ]]
local function regionOf(player: Player): string
	local root = rootOf(player)
	if not root then
		return "open"
	end
	local node = NodeService.nodeAt(root.Position)
	return if node then node.region else "open"
end

--[[ Tell every client that a technique resolved, so they can draw it.

	Presentation only. Nothing here decides an outcome -- the damage is already
	applied by the time this fires -- so a client that ignores or fakes it changes
	nothing but its own screen. ]]
local function broadcastVfx(
	caster: Player,
	techId: string,
	origin: Vector3,
	target: Vector3?,
	hit: boolean
)
	if not techniqueFiredRemote then
		return
	end
	local tech = Config.Techniques[techId]
	techniqueFiredRemote:FireAllClients({
		techId = techId,
		kind = tech.kind,
		casterId = caster.UserId,
		origin = origin,
		target = target,
		hit = hit,
	})
end

local function publish(player: Player)
	local actor = actors[player.UserId]
	if not actor then
		return
	end
	player:SetAttribute("Health", math.floor(actor.health))
	player:SetAttribute("MaxHealth", math.floor(Combat.maxHealth(Config, actor.stageIndex)))
	player:SetAttribute("Madra", math.floor(actor.madra))
	player:SetAttribute("MaxMadra", math.floor(Combat.maxMadra(Config, actor.stageIndex)))
end

--[[ The actor is authoritative; the Humanoid is a readout, so the default health
	bar and death animation reflect it. Nothing reads back from the Humanoid
	except its Died signal, which covers deaths this service did not cause. ]]
local function mirrorHumanoid(player: Player, actor: Combat.Actor)
	local humanoid = humanoidOf(player)
	if not humanoid then
		return
	end
	humanoid.MaxHealth = Combat.maxHealth(Config, actor.stageIndex)
	humanoid.Health = actor.health
end

local function ensureActor(player: Player): Combat.Actor?
	-- No actor exists between death and respawn, so a corpse cannot be hit
	-- again and the dead player cannot spend madra.
	if dying[player.UserId] then
		return nil
	end

	local stageIndex = stageIndexOf(player)
	if not stageIndex then
		return nil
	end

	local existing = actors[player.UserId]
	if existing and existing.stageIndex == stageIndex then
		return existing
	end

	-- A breakthrough changes both pools, so the actor is rebuilt on stage
	-- change. Polling for it here keeps CultivationService from needing to know
	-- this service exists at all.
	local actor = Combat.newActor(Config, tostring(player.UserId), stageIndex)
	actors[player.UserId] = actor
	mirrorHumanoid(player, actor)
	publish(player)
	return actor
end

local function handleDeath(player: Player)
	if dying[player.UserId] then
		return
	end
	dying[player.UserId] = true

	-- Resolved at death rather than captured at spawn, so a player who dies
	-- before their state has loaded is charged nothing instead of being charged
	-- at the wrong stage.
	local actor = actors[player.UserId]
	local stageIndex = if actor then actor.stageIndex else stageIndexOf(player)
	if stageIndex then
		-- Amount comes from Combat, the ratchet lives in Progression, and the
		-- write is routed through CultivationService so state has one owner.
		CultivationService.applyDeathLoss(player, Combat.deathLoss(Config, stageIndex))
	end
	actors[player.UserId] = nil

	local humanoid = humanoidOf(player)
	if humanoid and humanoid.Health > 0 then
		humanoid.Health = 0
	end
end

--[[ Damage from one actor to one player. Cross-bracket engagements are refused
	outright here rather than scaled down. ]]
local function damagePlayer(source: Combat.Actor, target: Player, raw: number, now: number)
	local targetActor = ensureActor(target)
	if not targetActor or targetActor.health <= 0 then
		return
	end
	if not Combat.canEngage(source, targetActor) then
		return
	end

	local result = Combat.applyDamage(Config, targetActor, raw, now)
	if result.dealt <= 0 then
		return
	end

	mirrorHumanoid(target, targetActor)
	publish(target)

	--[[ Every applied hit, from one place, so a Ruler sweep and a construct tick
		land the same feedback a striker bolt does. Presentation only: the damage
		above is already final, and read before death is processed so the body is
		still where it was struck. ]]
	local impactAt = rootOf(target)
	if impactRemote and impactAt then
		impactRemote:FireAllClients({
			attackerId = tonumber(source.id) or 0,
			targetId = target.UserId,
			position = impactAt.Position,
			damage = result.dealt,
			stageIndex = targetActor.stageIndex,
			died = result.died,
		})
	end

	if result.died then
		handleDeath(target)
	end
end

local function ensureConstructFolder(): Folder
	if constructFolder and constructFolder.Parent then
		return constructFolder
	end
	local existing = Workspace:FindFirstChild("Constructs")
	if existing and existing:IsA("Folder") then
		constructFolder = existing
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "Constructs"
	created.Parent = Workspace
	constructFolder = created
	return created
end

--[[ The persistent damaging construct that caltrops and sentry place.

	Damage is snapshotted at cast time, so buffs active when it was placed are
	baked in and buffs gained later are not: a construct is something you left
	behind, not a channel you are still feeding. ]]
local function spawnConstruct(
	owner: Player,
	actor: Combat.Actor,
	techId: string,
	position: Vector3,
	now: number
)
	local tech = Config.Techniques[techId]
	local radius = Config.Combat.ranges.forger
	constructCounter += 1

	local part = Instance.new("Part")
	part.Name = "construct_" .. constructCounter
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Shape = Enum.PartType.Cylinder
	part.Material = Enum.Material.Neon
	part.Color = CONSTRUCT_COLOR
	part.Transparency = 0.6
	part.Size = Vector3.new(1, radius * 2, radius * 2)
	part.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.pi / 2)
	part:SetAttribute("Technique", techId)
	part:SetAttribute("Owner", owner.UserId)
	part.Parent = ensureConstructFolder()

	table.insert(constructs, {
		id = part.Name,
		ownerId = owner.UserId,
		stageIndex = actor.stageIndex,
		techId = techId,
		position = position,
		radius = radius,
		damagePerTick = Combat.outgoingDamage(
			Config,
			actor,
			techId,
			powerOf(owner),
			regionOf(owner),
			now
		),
		expiresAt = now + tech.buffDuration,
		nextTickAt = now + Config.Combat.constructTickSeconds,
		part = part :: BasePart,
	})
end

--[[ Where a cast is pointed.

	The client sends this because it is the one thing the client genuinely knows
	better than the server: where the player is looking. Aiming by the
	character's facing instead reads as broken the moment the camera is free of
	the body.

	This is not a security hole. The server still owns range, cost, cooldown,
	bracket, the raycast itself and therefore every wall between the two of you;
	a lying direction buys nothing a real aimbot would not already have, and
	aimbots cannot be prevented from the server side of a client-authoritative
	camera. What is checked is only that the value is usable. ]]
local function aimOf(caster: Player, supplied: unknown): Vector3
	local root = rootOf(caster)
	local fallback = if root then root.CFrame.LookVector else Vector3.new(0, 0, -1)
	if typeof(supplied) ~= "Vector3" then
		return fallback
	end
	local aim = supplied :: Vector3
	-- Reject NaN and infinities before they reach Raycast, where a bad vector
	-- is an error rather than a miss.
	if aim ~= aim or aim.Magnitude ~= aim.Magnitude then
		return fallback
	end
	if aim.Magnitude < 1e-3 or aim.Magnitude > 1e6 then
		return fallback
	end
	return aim.Unit
end

local function resolveStriker(
	caster: Player,
	actor: Combat.Actor,
	techId: string,
	aim: Vector3,
	now: number
)
	local root = rootOf(caster)
	local character = caster.Character
	if not root or not character then
		return
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }

	local direction = aim * Config.Combat.ranges.striker
	local origin = root.Position
	local hit = Workspace:Raycast(origin, direction, params)
	local landing = if hit then hit.Position else origin + direction

	local target = if hit then playerFromInstance(hit.Instance) else nil
	local struck = target ~= nil and target ~= caster
	-- Broadcast before resolving, so a miss still draws. A shot that shows
	-- nothing when it misses reads as a broken button.
	broadcastVfx(caster, techId, origin, landing, struck)

	if not struck or not target then
		return
	end

	local raw = Combat.outgoingDamage(Config, actor, techId, powerOf(caster), regionOf(caster), now)
	damagePlayer(actor, target, raw, now)
end

local function resolveRuler(caster: Player, actor: Combat.Actor, techId: string, now: number)
	local root = rootOf(caster)
	local character = caster.Character
	if not root or not character then
		return
	end

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }

	-- Region is read once for the whole cast, so a Ruler technique scales by
	-- where the caster stands rather than where each victim happens to be.
	local raw = Combat.outgoingDamage(Config, actor, techId, powerOf(caster), regionOf(caster), now)

	broadcastVfx(caster, techId, root.Position, nil, false)

	local seen: { [number]: boolean } = {}
	local parts = Workspace:GetPartBoundsInRadius(root.Position, Config.Combat.ranges.ruler, params)
	for _, part in parts do
		local target = playerFromInstance(part)
		if target and target ~= caster and not seen[target.UserId] then
			seen[target.UserId] = true
			damagePlayer(actor, target, raw, now)
		end
	end
end

--[[ Land a technique after its windup. Cost and cooldown were paid at cast; this
	is only the effect, and it is dropped if the caster died during the
	telegraph. ]]
local function resolveEffect(caster: Player, actor: Combat.Actor, techId: string, aim: Vector3)
	if actors[caster.UserId] ~= actor or actor.health <= 0 then
		return
	end

	local tech = Config.Techniques[techId]
	local now = os.clock()

	if tech.kind == "striker" then
		resolveStriker(caster, actor, techId, aim, now)
	elseif tech.kind == "ruler" then
		resolveRuler(caster, actor, techId, now)
	elseif tech.kind == "enforcer" then
		-- Self-only. Combat.use already applied the buff.
		local root = rootOf(caster)
		if root then
			broadcastVfx(caster, techId, root.Position, nil, true)
		end
		publish(caster)
	elseif tech.kind == "forger" then
		local root = rootOf(caster)
		if root then
			broadcastVfx(caster, techId, root.Position, nil, true)
		end
		if SELF_BUFF_FORGERS[techId] then
			publish(caster)
		elseif root then
			spawnConstruct(caster, actor, techId, root.Position, now)
		end
	end
end

local function onUseTechnique(player: Player, slot: unknown, suppliedAim: unknown)
	local now = os.clock()
	local last = lastRequestAt[player.UserId]
	if last and now - last < MIN_REQUEST_INTERVAL then
		return
	end
	lastRequestAt[player.UserId] = now

	local actor = ensureActor(player)
	if not actor then
		return
	end

	local loadout = loadouts[player.UserId]
	if not loadout then
		return
	end

	local techId = Combat.resolveSlot(Config, loadout, slot)
	if not techId then
		return
	end

	local result = Combat.use(Config, actor, techId, now)
	if not result.ok then
		return
	end

	publish(player)

	-- Aim is sampled at cast, not at resolution: a long windup is a commitment,
	-- and letting it track the camera through the telegraph would erase the
	-- counterplay the windup is there to buy.
	local aim = aimOf(player, suppliedAim)

	local tech = Config.Techniques[techId]
	if tech.windup > 0 then
		task.delay(tech.windup, function()
			resolveEffect(player, actor, techId, aim)
		end)
	else
		resolveEffect(player, actor, techId, aim)
	end
end

local function onCharacterAdded(player: Player)
	dying[player.UserId] = nil
	actors[player.UserId] = nil

	-- Connected before the actor is built, and independently of whether it can
	-- be: cultivation state may still be loading when the character spawns, and
	-- a character with no death handler never respawns cleanly.
	local humanoid = humanoidOf(player)
	if humanoid then
		humanoid.Died:Connect(function()
			-- Covers deaths this service did not cause, so falling off the map
			-- costs the same refinement that losing a fight does.
			handleDeath(player)
		end)
	end

	ensureActor(player)
end

function CombatService.onPlayerAdded(player: Player)
	local loadout = table.clone(Config.DefaultLoadout)
	loadouts[player.UserId] = loadout
	-- Published so the client can label its keys. The loadout itself stays
	-- server-side; this is a readout, and the client still sends only a slot.
	for _, slot in Config.LoadoutSlots do
		player:SetAttribute("Slot_" .. slot, loadout[slot])
	end
	player.CharacterAdded:Connect(function()
		onCharacterAdded(player)
	end)
	if player.Character then
		onCharacterAdded(player)
	end
end

function CombatService.onPlayerRemoving(player: Player)
	actors[player.UserId] = nil
	loadouts[player.UserId] = nil
	dying[player.UserId] = nil
	lastRequestAt[player.UserId] = nil
	for i = #constructs, 1, -1 do
		if constructs[i].ownerId == player.UserId then
			constructs[i].part:Destroy()
			table.remove(constructs, i)
		end
	end
end

local function stepConstructs(now: number)
	for i = #constructs, 1, -1 do
		local construct = constructs[i]
		if now >= construct.expiresAt then
			construct.part:Destroy()
			table.remove(constructs, i)
			continue
		end
		if now < construct.nextTickAt then
			continue
		end
		construct.nextTickAt = now + Config.Combat.constructTickSeconds

		local owner = Players:GetPlayerByUserId(construct.ownerId)
		local ownerActor = if owner then actors[owner.UserId] else nil
		if not ownerActor then
			continue
		end

		local seen: { [number]: boolean } = {}
		local parts = Workspace:GetPartBoundsInRadius(construct.position, construct.radius)
		for _, part in parts do
			local target = playerFromInstance(part)
			if target and target.UserId ~= construct.ownerId and not seen[target.UserId] then
				seen[target.UserId] = true
				damagePlayer(ownerActor, target, construct.damagePerTick, now)
			end
		end
	end
end

function CombatService.tick(deltaSeconds: number, now: number)
	for _, player in Players:GetPlayers() do
		local actor = ensureActor(player)
		if actor and actor.health > 0 then
			Combat.regen(Config, actor, deltaSeconds)
			publish(player)
		end
	end
	stepConstructs(now)
end

function CombatService.start()
	Players.RespawnTime = Config.Combat.respawnSeconds

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local fired = remotes:WaitForChild("TechniqueFired")
	assert(fired:IsA("RemoteEvent"), "TechniqueFired must be a RemoteEvent")
	techniqueFiredRemote = fired

	local impact = remotes:WaitForChild("Impact")
	assert(impact:IsA("RemoteEvent"), "Impact must be a RemoteEvent")
	impactRemote = impact

	local useTechnique = remotes:WaitForChild("UseTechnique")
	assert(useTechnique:IsA("RemoteEvent"), "UseTechnique must be a RemoteEvent")

	useTechnique.OnServerEvent:Connect(function(player: Player, slot: unknown, aim: unknown)
		onUseTechnique(player, slot, aim)
	end)
end

return CombatService
