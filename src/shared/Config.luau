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

	--[[ Which region a node should *aim* for, as design intent.

		This is a target, not a fact. Placement picks a region by these weights,
		picks one of that region's anchors, scatters inside it, and then asks
		`ArenaService.regionAt` what the resulting point actually is. If a scatter
		throws a node past a lobe edge it is honestly `open`, and geography wins
		the disagreement. Intent lives here; truth lives on the map.

		The previous behaviour was a literal five-element table -- open, open,
		rich, barren, wellspring -- drawn independently of where the node landed,
		so a node tagged `wellspring` routinely sat on the visible Ember Barrens.
		It also made 40% of nodes `open`, which is the one region that is
		affinity-inactive and farms no aura, so two fifths of the field was
		progression-dead.

		`open` ground stays abundant -- it is most of the map, and it is the
		corridors and the travel. What is cut is open *nodes*, because a node is
		the unit of contested value and one with nothing to contest is a decoy.
		If `open` is later promoted to a real farmable aura, this is the one
		number that has to move. ]]
	regionWeights = {
		{ region = "wellspring", weight = 28 },
		{ region = "rich", weight = 30 },
		{ region = "barren", weight = 30 },
		{ region = "open", weight = 12 },
	},
}

--[[ How a region is spoken about. Announcements read "surfaced in the Ember
	Barrens", not "surfaced in the barren" -- a broken template string in the
	most prominent text on screen reads as unfinished more loudly than
	placeholder geometry does, because a grey slab could be a style choice and a
	half-written sentence cannot. ]]
Config.RegionNames = {
	barren = "the Ember Barrens",
	open = "the open field",
	rich = "the Verdant Reach",
	wellspring = "a Wellspring",
}

-- Static aura geography: permanent terrain richness, layered under the
-- dynamic field. Known to everyone, learnable, and what clans hold long term.
Config.StaticRegionMultipliers = {
	barren = 0.5,
	open = 1.0,
	rich = 1.8,
	wellspring = 2.6,
}

--[[ Persistence. Bump storeName rather than migrating when the shape of a
	saved state changes incompatibly; Progression.sanitizeState absorbs the
	compatible drift. ]]
Config.Persistence = {
	storeName = "Cultivation_v1",
	-- A stage is hours of play, so a lost autosave window is cheap; the request
	-- budget is not. Saves also happen on leave and on server shutdown.
	autosaveSeconds = 90,
}

-- Combat resources.
--
-- Health scales with stage but is FLAT inside a stage, while damage scales
-- with refinement. That is deliberate: if both scaled, the 18% refinement
-- spread would compound into a ~64% time-to-kill advantage. Keeping health
-- flat within a bracket holds the real spread at exactly 18%.
Config.Combat = {
	-- Damage is expressed relative to this power value, so time-to-kill stays
	-- constant across brackets while numbers still grow.
	referencePower = 100,
	healthMultiplier = 4.0,
	madraMultiplier = 2.0,
	-- Fraction of the madra pool regenerated per second.
	madraRegenFraction = 0.06,
	-- A death costs this fraction of one refinement tier. The ratchet in
	-- Progression guarantees it can never cost the stage itself.
	deathLossTierFraction = 0.35,
	globalCooldown = 0.4,
	-- Reach per technique kind, in studs. Striker pokes, Ruler blankets,
	-- Forger drops a construct at your feet, Enforcer is self-only.
	ranges = {
		striker = 140,
		ruler = 42,
		forger = 18,
		enforcer = 0,
	},
	respawnSeconds = 5,
	-- Forger constructs damage on an interval rather than continuously, so a
	-- technique's `damage` reads as damage *per tick*. At 2s, caltrops over its
	-- full 10s window is 5 ticks (150) and sentry over 12s is 6 (144) -- around
	-- a third of a Lowgold pool for standing still in a hazard you can walk out
	-- of. Zoning pressure, not a kill button.
	constructTickSeconds = 2.0,
}

--[[
	Shared technique pool. Themed paths are deferred, so every player draws
	from this same pool -- which is exactly the point: it isolates whether the
	combat feels good before build diversity can paper over it.

	Four technique types, three options each, one slot per type. That is 3^4 =
	81 loadouts with no themed content at all. When paths arrive they become a
	restricted, empowered subset of this pool rather than a rewrite.

	kind:
		striker  -- ranged bolt, burst
		enforcer -- self-buff window, melee sustain
		forger   -- persistent construct, zoning
		ruler    -- ambient aura command; scales with terrain richness
]]
export type Technique = {
	id: string,
	name: string,
	kind: "striker" | "enforcer" | "forger" | "ruler",
	madraCost: number,
	cooldown: number,
	windup: number,
	damage: number,
	buffDuration: number,
	damageBuff: number,
	mitigation: number,
	regionScaled: boolean,
}

Config.Techniques = {
	-- Striker
	lance = {
		id = "lance",
		name = "Lance",
		kind = "striker",
		madraCost = 18,
		cooldown = 1.2,
		windup = 0.15,
		damage = 42,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		regionScaled = false,
	},
	volley = {
		id = "volley",
		name = "Volley",
		kind = "striker",
		madraCost = 30,
		cooldown = 2.6,
		windup = 0.35,
		damage = 66,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		regionScaled = false,
	},
	pierce = {
		id = "pierce",
		name = "Pierce",
		kind = "striker",
		madraCost = 44,
		cooldown = 5.0,
		windup = 0.9,
		damage = 128,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		regionScaled = false,
	},

	-- Enforcer
	surge = {
		id = "surge",
		name = "Surge",
		kind = "enforcer",
		madraCost = 32,
		cooldown = 9.0,
		windup = 0.1,
		damage = 0,
		buffDuration = 5.0,
		damageBuff = 0.35,
		mitigation = 0,
		regionScaled = false,
	},
	bulwark = {
		id = "bulwark",
		name = "Bulwark",
		kind = "enforcer",
		madraCost = 28,
		cooldown = 11.0,
		windup = 0.1,
		damage = 0,
		buffDuration = 6.0,
		damageBuff = 0,
		mitigation = 0.40,
		regionScaled = false,
	},
	swiftstep = {
		id = "swiftstep",
		name = "Swiftstep",
		kind = "enforcer",
		madraCost = 22,
		cooldown = 7.0,
		windup = 0.05,
		damage = 0,
		buffDuration = 4.0,
		damageBuff = 0.15,
		mitigation = 0.10,
		regionScaled = false,
	},

	-- Forger
	barrier = {
		id = "barrier",
		name = "Barrier",
		kind = "forger",
		madraCost = 40,
		cooldown = 12.0,
		windup = 0.4,
		damage = 0,
		buffDuration = 8.0,
		damageBuff = 0,
		mitigation = 0.55,
		regionScaled = false,
	},
	caltrops = {
		id = "caltrops",
		name = "Caltrops",
		kind = "forger",
		madraCost = 45,
		cooldown = 10.0,
		windup = 0.5,
		damage = 30,
		buffDuration = 10.0,
		damageBuff = 0,
		mitigation = 0,
		regionScaled = false,
	},
	sentry = {
		id = "sentry",
		name = "Sentry",
		kind = "forger",
		madraCost = 55,
		cooldown = 16.0,
		windup = 0.7,
		damage = 24,
		buffDuration = 12.0,
		damageBuff = 0,
		mitigation = 0,
		regionScaled = false,
	},

	-- Ruler -- these are the terrain-dependent ones. Monstrous in a
	-- wellspring, close to useless on barren ground.
	upheaval = {
		id = "upheaval",
		name = "Upheaval",
		kind = "ruler",
		madraCost = 70,
		cooldown = 14.0,
		windup = 1.4,
		damage = 95,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		regionScaled = true,
	},
	siphon = {
		id = "siphon",
		name = "Siphon",
		kind = "ruler",
		madraCost = 50,
		cooldown = 11.0,
		windup = 0.8,
		damage = 55,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		regionScaled = true,
	},
	tempest = {
		id = "tempest",
		name = "Tempest",
		kind = "ruler",
		madraCost = 85,
		cooldown = 20.0,
		windup = 1.8,
		damage = 140,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		regionScaled = true,
	},
} :: { [string]: Technique }

-- One slot per technique type.
Config.LoadoutSlots = { "striker", "enforcer", "forger", "ruler" }

Config.DefaultLoadout =
	{ striker = "lance", enforcer = "surge", forger = "barrier", ruler = "siphon" }

--[[
	=========================== TUNING PROFILE ===========================

	Everything above this line is the RELEASE tuning: the numbers the shipped
	game is balanced around. Everything below is a named profile that overrides
	some of them, and `Config.Profile` is the single switch that decides whether
	any of it applies.

	This began as a block of bare assignments written for one evening and
	labelled "delete this tomorrow". It outlived the evening, which is what such
	blocks always do, and a block of unlabelled assignments at the bottom of
	Config is how a development curve eventually ships to players by accident.
	So it is a profile now: one flag, obvious at a glance which way it is set,
	announced at boot, and stamped into the release receipt.

	TO SHIP TO PLAYERS: set `Config.Profile = "release"`. That is the whole
	procedure -- nothing below needs deleting, and nothing above ever changed.

	`development` exists to make TESTING fast, not to be balanced. It is not a
	balance ruling and no number in it should be read as one.

	THE TWO PROFILES ARE FOR DIFFERENT JOBS AND YOU MUST NOT MIX THEM UP:

	  development -- THROUGHPUT. Exercise every technique, reach a catalyst,
	                 reach a breakthrough, watch a cast bar, without waiting on
	                 a bar to refill. Use it to find out WHETHER SOMETHING WORKS.

	  release     -- MEASUREMENT. Use it for any number you intend to act on.

	The trap, stated plainly because it is easy to walk into and expensive:
	`madraRegenFraction = 0.60` refills a Lowgold pool in 1.7 seconds, so under
	`development` MADRA STOPS BEING A CONSTRAINT AT ALL and a fighter is limited
	only by cooldowns. A time-to-kill measured there is the cooldown-limited
	FLOOR, not the real fight. Under `release` the pool regenerates 12 madra per
	second, and the gap between that and what a loadout spends is precisely what
	makes an expensive loadout play differently from a cheap one -- Lance at 18
	on a 1.2s cooldown is roughly break-even, Volley at 30 and Pierce are not.
	Under `development` that whole distinction vanishes, and with it the reason
	different loadouts have different time-to-kill.

	So: flip to `release` for the measurement run, take the numbers, flip back.
	And record which profile any number was taken under -- a figure with no
	profile attached is worse than no figure, because somebody will act on it.
]]
Config.Profile = "development" :: "development" | "release"

if Config.Profile == "development" then
	--[[ Refinement. Kept at the values Remi's session actually ran on rather
		than cut further, deliberately: landscape is about to make cycling read
		the ground instead of the node, which moves this curve on its own. Two
		simultaneous changes to the same curve would confound each other, so
		these are re-aimed once that lands and its effect is measured. ]]
	Config.Stages[5].perTierProgress = 350 -- release 9000
	Config.Stages[6].perTierProgress = 950 -- release 24000
	Config.Stages[7].perTierProgress = 1750 -- release 45000

	--[[ Madra regen is the single biggest limit on testing throughput. At the
		release 6%/sec a tester spends most of their time waiting on a pool
		rather than exercising techniques; at 60% the pool refills in under two
		seconds and COOLDOWNS BECOME THE ONLY CONSTRAINT, which is exactly what
		you want when the job is "press all twelve of these and watch what
		happens". This is the number the human asked for by name. ]]
	Config.Combat.madraRegenFraction = 0.60 -- release 0.06

	--[[ Nodes. More primes, more often, because a catalyst is the gate on
		breakthrough and the breakthrough SUCCESS branch has still never
		executed in this project's life. maxActiveNodes stays low so testers
		still collide over the same ground. ]]
	Config.Field.spawnWeights = {
		{ tier = "common", weight = 50 },
		{ tier = "rare", weight = 30 },
		{ tier = "prime", weight = 20 },
	}
	Config.Field.spawnIntervalSeconds = 10 -- release 20
	Config.Field.maxActiveNodes = 7 -- release 12

	--[[ Windups, so all three strikers clear interface's 0.15s cast-bar floor
		and are visibly telegraphed. A bar that lives two frames trains the eye
		to distrust it. These are a legibility fix rather than a testing speed-up
		and they are a candidate to promote into release. ]]
	Config.Techniques.lance.windup = 0.28 -- release 0.15
	Config.Techniques.volley.windup = 0.50 -- release 0.35

	--[[ A separate store, so a 26x-accelerated curve never writes into the
		release save. Kept at the playtest name rather than renamed to something
		tidier for one specific reason: THIS STORE HOLDS THE ONLY EVIDENCE THAT
		PERSISTENCE HAS EVER WORKED. Remi's session wrote to it -- the first
		time the DataStore path has executed at all -- and if any of that group
		rejoins with their tier intact, that is the confirmation we never got.
		Renaming would orphan it for a tidier name, which is a bad trade. ]]
	Config.Persistence.storeName = "Cultivation_playtest_20260910" -- release "Cultivation_v1"
end

return Config
