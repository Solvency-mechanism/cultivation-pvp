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

local TIER_COLOR: { [string]: Color3 } = {
	common = Color3.fromRGB(120, 190, 255),
	rare = Color3.fromRGB(170, 120, 255),
	prime = Color3.fromRGB(255, 195, 90),
}

local TIER_SIZE: { [string]: number } = {
	common = 6,
	rare = 8,
	prime = 11,
}

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

local function buildPart(node: AuraNodes.Node): BasePart
	local size = TIER_SIZE[node.tier] or 6
	local part = Instance.new("Part")
	part.Name = node.id
	part.Anchored = true
	part.CanCollide = false
	part.Shape = Enum.PartType.Ball
	part.Material = Enum.Material.Neon
	part.Size = Vector3.new(size, size, size)
	part.Color = TIER_COLOR[node.tier] or Color3.new(1, 1, 1)
	part.Transparency = 0.35
	part.Position = Vector3.new(node.position.x, node.position.y, node.position.z)
	part:SetAttribute("Tier", node.tier)
	part:SetAttribute("Region", node.region)
	part:SetAttribute("ExpiresAt", node.expiresAt)
	part.Parent = ensureFolder()
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

function NodeService.setDrainedHandler(handler: (AuraNodes.Node) -> ())
	onDrained = handler
end

function NodeService.step(now: number)
	for _, node in field do
		if AuraNodes.isExpired(node, now) and onDrained then
			onDrained(node)
		end
	end

	if now - lastSpawn >= Config.Field.spawnIntervalSeconds then
		lastSpawn = now
		AuraNodes.step(Config, field, now, math.random, nextId, placer)
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
