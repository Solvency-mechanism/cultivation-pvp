--!strict
--[[
	Central tuning data for cultivation, refinement and aura nodes.

	All names are placeholders. This module is pure data with no requires, so it
	can be loaded both by Roblox (require(script.Parent.Config)) and by Lune
	tests (require("../src/shared/Config")).
]]

export type Stage = {
	id: string,
	name: string,
	basePower: number,
	senseRange: number,
	perTierProgress: number,
	provingGround: boolean,
	requiresCatalyst: boolean,
}

export type NodeTier = {
	id: string,
	cycleMultiplier: number,
	capacity: number,
	lifetime: number,
	catalystChance: number,
	telegraph: "local" | "regional" | "server",
}

local Config = {}

-- Refinement is the continuous axis *inside* a stage. Stage decides your PvP
-- bracket; refinement decides where you sit within it.
Config.RefinementTiers = 10

-- Tier 1 grants no bonus, tier 10 grants 9 steps. 2% per step caps the
-- intra-bracket power spread at 18%, so a maxed player is meaningfully ahead
-- but skill still decides the fight.
Config.RefinementPowerStep = 0.02

-- Sense range scales faster than power. This is the pressure valve: a veteran
-- out-*finds* a newcomer far more than they out-fight them.
Config.RefinementSenseStep = 0.03

-- Cycling accrual, in refinement progress per second.
Config.BaseCycleRate = 1.0
Config.OfflineCycleFactor = 0.25

-- Advancement never reverses. Losses can drain the refinement bar but can
-- never demote a stage the player has already earned.
Config.AllowStageDemotion = false

--[[
	Deferred design decisions, parked as flags so flipping them is a one-line
	change rather than a refactor.

	contestResolution:
		"presence" -- contested nodes tug-of-war while both sides stand on them
		"clear"    -- a node only yields once one side is wiped off it
	primeSpawnMode:
		"random"    -- rewards being logged in
		"scheduled" -- players plan around a raid-style window
]]
Config.ContestResolution = "presence" :: "presence" | "clear"
Config.PrimeSpawnMode = "random" :: "random" | "scheduled"

-- Ordered low to high. Index is the stage's identity everywhere else.
Config.Stages = {
	{
		id = "foundation",
		name = "Foundation",
		basePower = 10,
		senseRange = 0,
		perTierProgress = 120,
		provingGround = true,
		requiresCatalyst = false,
	},
	{
		id = "copper",
		name = "Copper",
		basePower = 20,
		senseRange = 120,
		perTierProgress = 240,
		provingGround = true,
		requiresCatalyst = false,
	},
	{
		id = "iron",
		name = "Iron",
		basePower = 35,
		senseRange = 180,
		perTierProgress = 480,
		provingGround = true,
		requiresCatalyst = false,
	},
	{
		id = "jade",
		name = "Jade",
		basePower = 55,
		senseRange = 260,
		perTierProgress = 900,
		provingGround = true,
		requiresCatalyst = false,
	},
	{
		id = "lowgold",
		name = "Lowgold",
		basePower = 100,
		senseRange = 400,
		perTierProgress = 9000,
		provingGround = false,
		requiresCatalyst = true,
	},
	{
		id = "highgold",
		name = "Highgold",
		basePower = 180,
		senseRange = 550,
		perTierProgress = 24000,
		provingGround = false,
		requiresCatalyst = true,
	},
	{
		id = "truegold",
		name = "Truegold",
		basePower = 300,
		senseRange = 750,
		perTierProgress = 45000,
		provingGround = false,
		requiresCatalyst = true,
	},
} :: { Stage }

-- Capacity is the anti-zerg valve: a ten-player clan gains nothing from
-- bringing ten bodies to a node that only feeds three.
Config.NodeTiers = {
	common = {
		id = "common",
		cycleMultiplier = 3,
		capacity = 3,
		lifetime = 600,
		catalystChance = 0,
		telegraph = "local",
	},
	rare = {
		id = "rare",
		cycleMultiplier = 8,
		capacity = 3,
		lifetime = 420,
		catalystChance = 0.15,
		telegraph = "regional",
	},
	prime = {
		id = "prime",
		cycleMultiplier = 20,
		capacity = 3,
		lifetime = 300,
		catalystChance = 1.0,
		telegraph = "server",
	},
} :: { [string]: NodeTier }

-- Dynamic node field. This spawner is the content pipeline: with no AI or
-- scripted encounters, what it emits *is* the moment-to-moment game.
Config.Field = {
	maxActiveNodes = 12,
	spawnIntervalSeconds = 20,
	-- How close you must stand to draw from a node.
	captureRadius = 14,
	-- Server tick for awarding cycling progress.
	cycleTickSeconds = 1,
	-- Weighted tier roll. Prime is rare because it is a server-wide event.
	spawnWeights = {
		{ tier = "common", weight = 70 },
		{ tier = "rare", weight = 25 },
		{ tier = "prime", weight = 5 },
	},
}

-- Static aura geography: permanent terrain richness, layered under the
-- dynamic field. Known to everyone, learnable, and what clans hold long term.
Config.StaticRegionMultipliers = {
	barren = 0.5,
	open = 1.0,
	rich = 1.8,
	wellspring = 2.6,
}

return Config
