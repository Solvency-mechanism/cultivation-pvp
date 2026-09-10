--!strict
--[[
	Owns the live aura node field and its physical representation.

	All field rules live in the pure AuraNodes module; this service only binds
	them to Workspace parts, player positions and the clock.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AuraNodes = require(ReplicatedStorage.Shared.AuraNodes)
local Config = require(ReplicatedStorage.Shared.Config)

local NodeService = {}

local field: { AuraNodes.Node } = {}
local parts: { [string]: BasePart } = {}
local folder: Folder? = nil
local counter = 0
local lastSpawn = 0

--[[ A node used to be one translucent ball lying on the ground, which read as
	a decal rather than an object -- no glow, no vertical element, no motion, on
	the game's own core resource.

	It is now built out of five pieces, and the split is the point:

	- a *dark* core with a neon shell around it, so the two-material contrast
	  carries "something is here" at any distance, on any ground, by value
	  rather than by hue;
	- a floating core, so it reads as suspended rather than painted on;
	- a ground ring drawn at exactly `Config.Field.captureRadius`, so the ring
	  is not decoration -- it is the distance you have to be inside to draw from
	  the node, which the HUD otherwise only tells you as a number;
	- a column of rising motes and a pulse that expands off the ring, which is
	  the only motion a node has and is what stops it reading as scenery;
	- a silhouette that grows by tier: three low shards for common, a crown of
	  six for rare, and for Prime a ring of pillars under a three-hundred-stud
	  shaft of light that can be seen from anywhere on the map.

	Everything animates client-side -- particles and beams -- so this costs the
	server nothing per frame and nothing can outlive the part it hangs off. ]]
type TierVisual = {
	color: Color3,
	core: number,
	hover: number,
	column: number,
	shards: number,
	shardHeight: number,
	rate: number,
	light: number,
	shaft: number,
}

--[[ Hues match the client's sense-panel rows: the colour of a line in the HUD
	and the colour of the thing it is pointing at have to be the same colour or
	the panel is a second thing to learn. ]]
local TIER_VISUAL: { [string]: TierVisual } = {
	common = {
		color = Color3.fromRGB(105, 195, 255),
		core = 4.6,
		hover = 3.4,
		column = 17,
		shards = 3,
		shardHeight = 7,
		rate = 9,
		light = 0,
		shaft = 0,
	},
	rare = {
		color = Color3.fromRGB(185, 115, 255),
		core = 6.6,
		hover = 5.4,
		column = 32,
		shards = 6,
		shardHeight = 14,
		rate = 18,
		light = 38,
		shaft = 0,
	},
	prime = {
		color = Color3.fromRGB(255, 190, 75),
		core = 9.4,
		hover = 8.2,
		column = 50,
		shards = 8,
		shardHeight = 26,
		rate = 34,
		light = 60,
		shaft = 300,
	},
}

-- The dark half of the contrast pair. Every node piece is either this or neon.
local NODE_DARK = Color3.fromRGB(14, 13, 18)
local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"

local function nextId(): string
	counter += 1
	return `node_{counter}`
end

--[[ Placeholder placement. Real maps should seed this from tagged spawn
	anchors so static aura geography actually means something. ]]
local function placer(_tierId: string): (AuraNodes.Vec3, string)
	local radius = 220
	local angle = math.random() * math.pi * 2
	local dist = math.sqrt(math.random()) * radius
	local regions = { "open", "open", "rich", "barren", "wellspring" }
	return {
		x = math.cos(angle) * dist,
		y = 4,
		z = math.sin(angle) * dist,
	},
		regions[math.random(1, #regions)]
end

local function ensureFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local existing = Workspace:FindFirstChild("AuraNodes")
	if existing and existing:IsA("Folder") then
		folder = existing
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "AuraNodes"
	created.Parent = Workspace
	folder = created
	return created
end

--[[ Nodes are a readout of field state, not physical objects. Leaving any
	piece of one queryable would let a common node body-block every Striker
	technique, and leaving it collidable would let players fence each other out
	of the thing they are fighting over. ]]
local function makeVisual(part: BasePart, parent: Instance)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
end

local function newBall(
	diameter: number,
	position: Vector3,
	color: Color3,
	transparency: number
): Part
	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(diameter, diameter, diameter)
	ball.Position = position
	ball.Color = color
	ball.Transparency = transparency
	ball.Material = if transparency > 0 then Enum.Material.Neon else Enum.Material.Slate
	return ball
end

--[[ A flat disc. Part.Shape = Cylinder runs its axis along local X, so the
	quarter turn about Z is what lays it down. ]]
local function newDisc(radius: number, thickness: number, center: Vector3): Part
	local disc = Instance.new("Part")
	disc.Shape = Enum.PartType.Cylinder
	disc.Size = Vector3.new(thickness, radius * 2, radius * 2)
	disc.CFrame = CFrame.new(center) * CFrame.Angles(0, 0, math.pi / 2)
	return disc
end

--[[ The rising column. Motes leave the ring and climb past the core, which is
	the difference between a node that is lit and a node that is *running*. ]]
local function addColumn(root: BasePart, spec: TierVisual, groundOffset: number)
	local base = Instance.new("Attachment")
	base.Position = Vector3.new(0, groundOffset, 0)
	base.Parent = root

	local top = Instance.new("Attachment")
	top.Position = Vector3.new(0, spec.column, 0)
	top.Parent = root

	local beam = Instance.new("Beam")
	beam.Attachment0 = base
	beam.Attachment1 = top
	beam.Width0 = spec.core * 0.9
	beam.Width1 = spec.core * 0.25
	beam.FaceCamera = true
	beam.LightInfluence = 0
	beam.Color = ColorSequence.new(spec.color)
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.45),
		NumberSequenceKeypoint.new(0.55, 0.72),
		NumberSequenceKeypoint.new(1, 1),
	})
	beam.Parent = root

	local motes = Instance.new("ParticleEmitter")
	motes.Texture = SPARKLE
	motes.Color = ColorSequence.new(spec.color)
	motes.LightEmission = 1
	motes.LightInfluence = 0
	motes.Rate = spec.rate
	motes.Lifetime = NumberRange.new(1.4, 2.4)
	motes.Speed = NumberRange.new(spec.column * 0.35, spec.column * 0.6)
	motes.SpreadAngle = Vector2.new(14, 14)
	motes.Acceleration = Vector3.new(0, 3, 0)
	motes.EmissionDirection = Enum.NormalId.Top
	motes.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.3, spec.core * 0.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	motes.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	motes.Parent = base

	--[[ The pulse. One particle a second, born at the ring and expanding to it,
		which gives the node a heartbeat at roughly the cadence of the cycling
		tick without the server having to drive a single frame of it. ]]
	local pulse = Instance.new("ParticleEmitter")
	pulse.Texture = SPARKLE
	pulse.Color = ColorSequence.new(spec.color)
	pulse.LightEmission = 1
	pulse.LightInfluence = 0
	pulse.Rate = 1
	pulse.Lifetime = NumberRange.new(1, 1)
	pulse.Speed = NumberRange.new(0, 0)
	pulse.Orientation = Enum.ParticleOrientation.FacingCameraWorldUp
	pulse.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, spec.core),
		NumberSequenceKeypoint.new(1, Config.Field.captureRadius * 2),
	})
	pulse.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	pulse.Parent = base
end

local function buildPart(node: AuraNodes.Node): BasePart
	local spec = TIER_VISUAL[node.tier] or TIER_VISUAL.common
	local anchor = Vector3.new(node.position.x, node.position.y, node.position.z)
	local centre = anchor + Vector3.new(0, spec.hover, 0)
	-- Distance from the floating core down to the ground, for the pieces that
	-- have to sit on it.
	local groundOffset = -(centre.Y - 0.35)

	--[[ The root is the dark half of the core, and it keeps the node's identity:
		its name, its attributes and a position that still answers for where the
		node is. Everything else hangs off it and dies with it. ]]
	local part = newBall(spec.core, centre, NODE_DARK, 0)
	part.Name = node.id
	part:SetAttribute("Tier", node.tier)
	part:SetAttribute("Region", node.region)
	part:SetAttribute("ExpiresAt", node.expiresAt)
	makeVisual(part, ensureFolder())

	local shell = newBall(spec.core * 1.5, centre, spec.color, 0.3)
	shell.Name = "Shell"
	makeVisual(shell, part)

	local halo = newBall(spec.core * 2.6, centre, spec.color, 0.86)
	halo.Name = "Halo"
	makeVisual(halo, part)

	if spec.light > 0 then
		local light = Instance.new("PointLight")
		light.Color = spec.color
		light.Range = spec.light
		light.Brightness = 2.6
		light.Parent = shell
	end

	-- The ring *is* the capture radius, so the reach of the node is something
	-- you can see from outside it rather than a number in a panel.
	local reach = Config.Field.captureRadius
	local ringBed = newDisc(reach + 1.6, 0.6, Vector3.new(centre.X, 0.22, centre.Z))
	ringBed.Name = "RingBed"
	ringBed.Color = NODE_DARK
	ringBed.Material = Enum.Material.Slate
	makeVisual(ringBed, part)

	local ring = newDisc(reach, 0.6, Vector3.new(centre.X, 0.3, centre.Z))
	ring.Name = "Ring"
	ring.Color = spec.color
	ring.Material = Enum.Material.Neon
	ring.Transparency = 0.35
	makeVisual(ring, part)

	local eye = newDisc(reach * 0.55, 0.6, Vector3.new(centre.X, 0.36, centre.Z))
	eye.Name = "RingEye"
	eye.Color = NODE_DARK
	eye.Material = Enum.Material.Slate
	eye.Transparency = 0.25
	makeVisual(eye, part)

	-- Tier silhouette: shards standing on the ring, tipped in neon above rare.
	for index = 1, spec.shards do
		local angle = (index / spec.shards) * math.pi * 2
		local foot = Vector3.new(
			centre.X + math.cos(angle) * (reach * 0.82),
			0,
			centre.Z + math.sin(angle) * (reach * 0.82)
		)
		local height = spec.shardHeight
		local shard = Instance.new("Part")
		shard.Size = Vector3.new(2.4, height, 2.4)
		shard.CFrame = CFrame.new(foot + Vector3.new(0, height / 2 - 1, 0))
			* CFrame.Angles(0, -angle, 0)
			* CFrame.Angles(0, 0, 0.13)
		shard.Color = NODE_DARK
		shard.Material = Enum.Material.Slate
		shard.Name = `Shard{index}`
		makeVisual(shard, part)

		if spec.shaft > 0 or spec.shards > 3 then
			local tip = Instance.new("Part")
			tip.Size = Vector3.new(1.8, height * 0.3, 1.8)
			tip.CFrame = shard.CFrame * CFrame.new(0, height * 0.5, 0)
			tip.Color = spec.color
			tip.Material = Enum.Material.Neon
			tip.Name = `ShardTip{index}`
			makeVisual(tip, part)
		end
	end

	--[[ Prime is a server-wide event, so it has to be legible as one from two
		hundred studs away. The shaft is that promise kept: it is why you walk
		somewhere, and it is visible before the announcement has finished. ]]
	if spec.shaft > 0 then
		local shaft = newDisc(5, spec.shaft, Vector3.new(centre.X, spec.shaft / 2, centre.Z))
		shaft.Name = "PrimeShaft"
		shaft.Color = spec.color
		shaft.Material = Enum.Material.Neon
		shaft.Transparency = 0.68
		makeVisual(shaft, part)

		local flare =
			newDisc(13, spec.shaft * 0.72, Vector3.new(centre.X, spec.shaft * 0.36, centre.Z))
		flare.Name = "PrimeFlare"
		flare.Color = spec.color
		flare.Material = Enum.Material.Neon
		flare.Transparency = 0.9
		makeVisual(flare, part)
	end

	addColumn(part, spec, groundOffset)
	return part
end

function NodeService.getField(): { AuraNodes.Node }
	return field
end

function NodeService.nodeAt(position: Vector3): AuraNodes.Node?
	local radius = Config.Field.captureRadius
	local best: AuraNodes.Node? = nil
	local bestDist = math.huge
	for _, node in field do
		local delta = position - Vector3.new(node.position.x, node.position.y, node.position.z)
		local dist = delta.Magnitude
		if dist <= radius and dist < bestDist then
			best = node
			bestDist = dist
		end
	end
	return best
end

--[[ Called just before a node is culled. Occupants who held it to the end are
	the ones eligible for its catalyst -- which is what turns a Prime spawn
	into a timed defence fight rather than a tap-and-leave. ]]
local onDrained: ((AuraNodes.Node) -> ())? = nil
local onSpawned: ((AuraNodes.Node) -> ())? = nil

function NodeService.setDrainedHandler(handler: (AuraNodes.Node) -> ())
	onDrained = handler
end

--[[ Fired once per node, when it first appears. Telegraphs hang off this: the
	tier decides who is told, and Prime telling everyone is what makes the
	economy contested. ]]
function NodeService.setSpawnedHandler(handler: (AuraNodes.Node) -> ())
	onSpawned = handler
end

function NodeService.step(now: number)
	for _, node in field do
		if AuraNodes.isExpired(node, now) and onDrained then
			onDrained(node)
		end
	end

	if now - lastSpawn >= Config.Field.spawnIntervalSeconds then
		lastSpawn = now
		-- step() culls expired nodes before it appends, so the list can be
		-- shorter afterwards even though something spawned. Comparing ids is the
		-- only reading of "new" that survives that.
		local before: { [string]: boolean } = {}
		for _, node in field do
			before[node.id] = true
		end
		AuraNodes.step(Config, field, now, math.random, nextId, placer)
		if onSpawned then
			for _, node in field do
				if not before[node.id] then
					onSpawned(node)
				end
			end
		end
	else
		for i = #field, 1, -1 do
			if AuraNodes.isExpired(field[i], now) then
				table.remove(field, i)
			end
		end
	end

	local alive: { [string]: boolean } = {}
	for _, node in field do
		alive[node.id] = true
		if not parts[node.id] then
			parts[node.id] = buildPart(node)
		end
	end

	for id, part in parts do
		if not alive[id] then
			part:Destroy()
			parts[id] = nil
		end
	end
end

return NodeService
