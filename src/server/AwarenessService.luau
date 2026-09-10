--!strict
--[[
	What each player can feel, and what they get told.

	Two jobs that share one rule set. Sensing is continuous: every tick each
	player is sent the nodes inside their own sense range, nearest first.
	Telegraphs are events: when a node spawns, its tier decides who hears about
	it.

	Both filter server-side. The client is never sent nodes it should not know
	about, because a client that receives them will display them -- the node
	parts themselves are already replicated, so this is about the readout that
	makes sense range legible, not about hiding geometry.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AuraNodes = require(ReplicatedStorage.Shared.AuraNodes)
local Config = require(ReplicatedStorage.Shared.Config)
local Progression = require(ReplicatedStorage.Shared.Progression)
local CultivationService = require(script.Parent.CultivationService)
local NodeService = require(script.Parent.NodeService)

local AwarenessService = {}

type Payload = {
	id: string,
	tier: string,
	region: string,
	x: number,
	y: number,
	z: number,
	distance: number,
	expiresAt: number,
	occupants: number,
	capacity: number,
}

local sensedRemote: RemoteEvent? = nil
local noticeRemote: RemoteEvent? = nil

-- Sending the whole sensed list every tick is wasteful when nothing changed,
-- and node lists change slowly. This is the last signature sent per player.
local lastSignature: { [number]: string } = {}

local function positionOf(player: Player): AuraNodes.Vec3?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	return { x = root.Position.X, y = root.Position.Y, z = root.Position.Z }
end

local function senseRangeOf(player: Player): number?
	local state = CultivationService.getState(player)
	if not state then
		return nil
	end
	return Progression.senseRange(Config, state)
end

function AwarenessService.notify(player: Player, kind: string, text: string)
	if noticeRemote then
		noticeRemote:FireClient(player, kind, text)
	end
end

--[[ Announce a spawn to whoever the tier says should hear it.

	Foundation cultivators have a sense range of zero, so they are told nothing
	but Prime spawns -- which is the intended shape. Being blind until Copper is
	what makes gaining sight feel like the world filling with content. ]]
local function announceSpawn(node: AuraNodes.Node)
	local tier = Config.NodeTiers[node.tier]
	if not tier then
		return
	end

	for _, player in Players:GetPlayers() do
		local senseRange = senseRangeOf(player)
		if not senseRange then
			continue
		end
		local position = positionOf(player)
		local distance = if position then AuraNodes.distanceTo(node, position) else math.huge
		if AuraNodes.shouldAnnounce(Config, node, distance, senseRange) then
			local scope = AuraNodes.telegraphOf(Config, node)
			local text = if scope == "server"
				then `A Prime node has surfaced in the {node.region}.`
				else `You feel a {node.tier} node nearby.`
			AwarenessService.notify(player, scope, text)
		end
	end
end

local function payloadFor(player: Player): ({ Payload }, string)
	local position = positionOf(player)
	local senseRange = senseRangeOf(player)
	if not position or not senseRange then
		return {}, ""
	end

	local now = os.clock()
	local sensed = AuraNodes.sensed(NodeService.getField(), position, senseRange, now)

	local payload: { Payload } = {}
	local signature = {}
	for _, entry in sensed do
		local node = entry.node
		local tier = Config.NodeTiers[node.tier]
		table.insert(payload, {
			id = node.id,
			tier = node.tier,
			region = node.region,
			x = node.position.x,
			y = node.position.y,
			z = node.position.z,
			distance = entry.distance,
			expiresAt = node.expiresAt,
			occupants = node.occupantCount,
			capacity = if tier then tier.capacity else 0,
		})
		-- Distance is bucketed so ordinary walking does not resend the list on
		-- every tick; occupancy is not, because it is the contested signal.
		table.insert(signature, `{node.id}:{math.floor(entry.distance / 10)}:{node.occupantCount}`)
	end

	return payload, table.concat(signature, "|")
end

function AwarenessService.tick()
	if not sensedRemote then
		return
	end
	for _, player in Players:GetPlayers() do
		local payload, signature = payloadFor(player)
		if lastSignature[player.UserId] ~= signature then
			lastSignature[player.UserId] = signature
			sensedRemote:FireClient(player, payload)
		end
	end
end

function AwarenessService.onPlayerRemoving(player: Player)
	lastSignature[player.UserId] = nil
end

function AwarenessService.start()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")

	local sensed = remotes:WaitForChild("Sensed")
	assert(sensed:IsA("RemoteEvent"), "Sensed must be a RemoteEvent")
	sensedRemote = sensed

	local notice = remotes:WaitForChild("Notice")
	assert(notice:IsA("RemoteEvent"), "Notice must be a RemoteEvent")
	noticeRemote = notice

	NodeService.setSpawnedHandler(announceSpawn)
end

return AwarenessService
