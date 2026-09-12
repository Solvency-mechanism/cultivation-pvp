--!strict
--[[
	Aura node field: spawning, occupancy, decay and cycle rates.

	Pure and deterministic -- randomness is injected as an rng function so the
	spawner can be tested exactly. Positions are plain {x,y,z} tables rather
	than Vector3 so this module loads under Lune as well as Roblox.
]]

export type Vec3 = { x: number, y: number, z: number }

export type Node = {
	id: string,
	tier: string,
	position: Vec3,
	region: string,
	spawnedAt: number,
	expiresAt: number,
	occupants: { [string]: boolean },
	occupantCount: number,
	drained: boolean,
	reserve: number,
	drainedBy: { [string]: number },
}

export type Sensed = {
	node: Node,
	distance: number,
}

export type Rng = () -> number

local AuraNodes = {}

local function tierData(config: any, tierId: string)
	local tier = config.NodeTiers[tierId]
	assert(tier ~= nil, `unknown node tier "{tierId}"`)
	return tier
end

--[[ Weighted tier roll. rng() must return a value in [0, 1). ]]
function AuraNodes.rollTier(config: any, rng: Rng): string
	local weights = config.Field.spawnWeights
	local total = 0
	for _, entry in weights do
		total += entry.weight
	end

	local pick = rng() * total
	local cumulative = 0
	for _, entry in weights do
		cumulative += entry.weight
		if pick < cumulative then
			return entry.tier
		end
	end
	-- Only reachable on floating point drift at the very top of the range.
	return weights[#weights].tier
end

--[[ Which region a spawn should aim for. Same shape as `rollTier`.

	This is *intent only*. The caller picks an anchor in this region, scatters
	inside it, and then asks the map what the resulting point actually is -- so a
	scatter that lands past a lobe edge is honestly `open`. Region is a property
	of the ground; this function only decides where to go looking. ]]
function AuraNodes.rollRegion(config: any, rng: Rng): string
	local weights = config.Field.regionWeights
	local total = 0
	for _, entry in weights do
		total += entry.weight
	end

	local pick = rng() * total
	local cumulative = 0
	for _, entry in weights do
		cumulative += entry.weight
		if pick < cumulative then
			return entry.region
		end
	end
	-- Only reachable on floating point drift at the very top of the range.
	return weights[#weights].region
end

function AuraNodes.create(
	config: any,
	id: string,
	tierId: string,
	position: Vec3,
	region: string,
	now: number
): Node
	local tier = tierData(config, tierId)
	return {
		id = id,
		tier = tierId,
		position = position,
		region = region,
		spawnedAt = now,
		expiresAt = now + tier.lifetime,
		occupants = {},
		occupantCount = 0,
		drained = false,
		reserve = tier.drainReserve,
		drainedBy = {},
	}
end

function AuraNodes.isExpired(node: Node, now: number): boolean
	return node.drained or now >= node.expiresAt
end

function AuraNodes.isFull(config: any, node: Node): boolean
	return node.occupantCount >= tierData(config, node.tier).capacity
end

--[[ Returns ok, reason. Capacity is the anti-zerg valve, so refusal here is a
	load-bearing design behaviour rather than an error case. ]]
function AuraNodes.addOccupant(
	config: any,
	node: Node,
	userId: string,
	now: number
): (boolean, string?)
	if AuraNodes.isExpired(node, now) then
		return false, "expired"
	end
	if node.occupants[userId] then
		return false, "already_occupying"
	end
	if AuraNodes.isFull(config, node) then
		return false, "at_capacity"
	end
	node.occupants[userId] = true
	node.occupantCount += 1
	return true, nil
end

function AuraNodes.removeOccupant(node: Node, userId: string): boolean
	if not node.occupants[userId] then
		return false
	end
	node.occupants[userId] = nil
	node.occupantCount -= 1
	return true
end

-- No real faction system exists yet, so every occupant is their own faction
-- -- isContested/contestedBy's own `factionOf(id) or id` fallback -- which
-- makes AuraNodes.drain's contest check already correct today (more than
-- one distinct occupant is contested) with no change needed once teams do.
local function noFactionSystem(): string?
	return nil
end

--[[ The prime drain fight. `reserve` starts at the tier's `drainReserve`
	(commons small, primes large -- roster's pricing) and is spent down by
	whoever stands on the node, crediting each occupant's own contribution
	into `drainedBy` as it goes. `drained = true` the instant reserve hits
	zero -- the first place this field is ever set. An unoccupied node never
	drains: this is deliberately a no-op when occupantCount is 0, so an
	abandoned node still only ages out via `expiresAt`, exactly as before
	this existed. That is the compatibility guarantee, not a fallback bolted
	on afterward -- a node nobody holds was never a fight to begin with.

	Priced in the same unit and at the same rate accrual already uses:
	`cycleRate` IS the drain rate per occupant, so a node's reserve is
	literally the aura it would otherwise have handed out. No second rate to
	keep in sync with the first. ]]
function AuraNodes.drain(config: any, node: Node, dt: number)
	if node.drained or node.occupantCount <= 0 then
		return
	end

	local rate = AuraNodes.cycleRate(config, node, node.region, true)
	-- Contested nodes drain slower -- a stretch goal per the human's own
	-- ruling: with occupants draining occupantCount times faster, sharing
	-- had no cost, and this turns "more of us drains it quicker" into a
	-- stand-off instead.
	if AuraNodes.isContested(node, noFactionSystem) then
		rate *= config.Field.contestedDrainFactor
	end

	local perOccupant = rate * dt
	node.reserve = math.max(0, node.reserve - perOccupant * node.occupantCount)

	for userId in node.occupants do
		node.drainedBy[userId] = (node.drainedBy[userId] or 0) + perOccupant
	end

	if node.reserve <= 0 then
		node.drained = true
	end
end

--[[ Refinement progress per second for one occupant.

	Every occupant up to capacity draws the full rate -- the cap alone limits
	the group, so a trio is not punished for being a trio. Static region
	richness multiplies on top of the node's own tier. ]]
function AuraNodes.canClaimDrain(config: any, node: Node, userId: string): boolean
	return node.drained
		and node.occupants[userId] == true
		and (node.drainedBy[userId] or 0) >= config.NodeTiers[node.tier].drainReserve * 0.1
end

function AuraNodes.cycleRate(config: any, node: Node?, region: string, online: boolean): number
	local rate = config.BaseCycleRate
	if node then
		rate *= tierData(config, node.tier).cycleMultiplier
	end
	rate *= config.StaticRegionMultipliers[region] or 1.0
	if not online then
		rate *= config.OfflineCycleFactor
	end
	return rate
end

function AuraNodes.rollCatalyst(config: any, tierId: string, rng: Rng): boolean
	local chance = tierData(config, tierId).catalystChance
	if chance <= 0 then
		return false
	end
	if chance >= 1 then
		return true
	end
	return rng() < chance
end

function AuraNodes.telegraphOf(config: any, node: Node): string
	return tierData(config, node.tier).telegraph
end

--[[ Straight-line distance from a point to a node. ]]
function AuraNodes.distanceTo(node: Node, position: Vec3): number
	local dx = node.position.x - position.x
	local dy = node.position.y - position.y
	local dz = node.position.z - position.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--[[ The nodes a cultivator can feel from where they stand, nearest first.

	This is what makes sense range a mechanic rather than a number on a HUD.
	Range scales faster than power with refinement, so a veteran's real edge is
	finding nodes before anyone else can. Expired nodes are never sensed. ]]
function AuraNodes.sensed(
	nodes: { Node },
	position: Vec3,
	senseRange: number,
	now: number
): { Sensed }
	local found: { Sensed } = {}
	for _, node in nodes do
		if not AuraNodes.isExpired(node, now) then
			local distance = AuraNodes.distanceTo(node, position)
			if distance <= senseRange then
				table.insert(found, { node = node, distance = distance })
			end
		end
	end
	table.sort(found, function(left, right)
		return left.distance < right.distance
	end)
	return found
end

--[[ Whether a spawn is announced to one player.

	Local nodes are never announced -- you find those by sensing. Regional ones
	reach whoever could already sense them, so the announcement is a convenience
	rather than new information. Server scope, which only Prime carries, reaches
	everyone regardless of range: that is what turns a Prime spawn into a
	server-wide event, and it is the reason there is no safe grind. ]]
function AuraNodes.shouldAnnounce(
	config: any,
	node: Node,
	distance: number,
	senseRange: number
): boolean
	local scope = AuraNodes.telegraphOf(config, node)
	if scope == "server" then
		return true
	end
	if scope == "regional" then
		return distance <= senseRange
	end
	return false
end

--[[ Presence-based contest: a node is contested while more than one faction
	stands on it, and yields to whoever holds it uncontested. The "clear"
	variant is a deferred decision parked in Config. ]]
function AuraNodes.contestedBy(node: Node, factionOf: (string) -> string?): { [string]: number }
	local tally: { [string]: number } = {}
	for userId in node.occupants do
		local faction = factionOf(userId) or userId
		tally[faction] = (tally[faction] or 0) + 1
	end
	return tally
end

function AuraNodes.isContested(node: Node, factionOf: (string) -> string?): boolean
	local seen: string? = nil
	for userId in node.occupants do
		local faction = factionOf(userId) or userId
		if seen == nil then
			seen = faction
		elseif seen ~= faction then
			return true
		end
	end
	return false
end

--[[ Advance the field by one spawn opportunity. Mutates and returns the list
	so the caller can drive it from a heartbeat. ]]
function AuraNodes.step(
	config: any,
	nodes: { Node },
	now: number,
	rng: Rng,
	nextId: () -> string,
	placer: (string) -> (Vec3, string)
): { Node }
	for i = #nodes, 1, -1 do
		if AuraNodes.isExpired(nodes[i], now) then
			table.remove(nodes, i)
		end
	end

	if #nodes < config.Field.maxActiveNodes then
		local tierId = AuraNodes.rollTier(config, rng)
		local position, region = placer(tierId)
		table.insert(nodes, AuraNodes.create(config, nextId(), tierId, position, region, now))
	end

	return nodes
end

return AuraNodes
