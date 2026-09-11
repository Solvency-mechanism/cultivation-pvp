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
	-- Forger drops a construct at your feet, Enforcer and Strider are
	-- self-only.
	ranges = {
		striker = 140,
		ruler = 42,
		forger = 18,
		enforcer = 0,
		strider = 0,
	},
	-- Humanoid.WalkSpeed a character reverts to once no strider buff is
	-- live. Roblox's own engine default, named here so both the server and
	-- the client's local prediction revert to the same number rather than
	-- each hardcoding 16 independently.
	baseWalkSpeed = 16,
	respawnSeconds = 5,
	-- Forger constructs damage on an interval rather than continuously, so a
	-- technique's `damage` reads as damage *per tick*. At 2s, caltrops over its
	-- 10s window lands 4 ticks (120) and sentry over 12s lands 5 (120), not
	-- the 5 and 6 a division suggests: `stepConstructs` expires a construct
	-- before checking whether it is due to tick, so the tick that would fall
	-- exactly on expiry never fires. Either way it is around a third of a
	-- Lowgold pool for standing still in a hazard you can walk out of. Zoning
	-- pressure, not a kill button.
	constructTickSeconds = 2.0,
}

--[[
	Shared technique pool. Themed paths are deferred, so every player draws
	from this same pool -- which is exactly the point: it isolates whether the
	combat feels good before build diversity can paper over it.

	Five technique types, one slot per type, and the pool per type is being
	expanded so that build diversity becomes testable. The bar for an entry is
	not "more damage" or "cheaper" -- it is that a player who takes it does
	something DIFFERENT from a player who takes the alternative in that slot:
	stands somewhere else, fires at a different moment, gives something up.
	Balance is explicitly not a design input at this stage; strong options are
	a gating problem for the earned-level and affinity systems that come later,
	not a reason to flatten them now. When paths arrive they become a
	restricted, empowered subset of this pool rather than a rewrite.

	kind:
		striker  -- ranged bolt, burst
		enforcer -- self-buff window, melee sustain
		forger   -- persistent construct, zoning
		ruler    -- ambient aura command; scales with terrain richness
		strider  -- self-only WalkSpeed override, spans burst/mid/sustain travel

	How the fields are actually consumed, from the resolvers rather than from
	their names -- because several designs below lean on it:

	- The self-buff block in Combat.use fires for ANY kind when buffDuration >
	  0 and at least one of damageBuff / mitigation / moveSpeed is positive.
	  It fires at press, before the windup, so a striker's own bolt benefits
	  from its own damageBuff. Negative mitigation or damageBuff are honoured
	  as self-costs, provided one of the three is positive so the block fires.
	- regionScaled multiplies outgoing damage for any kind, not only ruler.
	- A forger not listed in CombatService's SELF_BUFF_FORGERS spawns a
	  construct; if it also carries positive mitigation it self-buffs too.
	  buffDuration is then read twice: the construct's lifetime and the buff's.
	- Constructs tick every constructTickSeconds and are expired BEFORE the
	  tick check on the step they lapse, so a duration that is an exact
	  multiple of the tick loses its last tick. Durations below sit a half
	  second past a multiple on purpose.
	- Windup on an enforcer only delays the presentation; the buff is live at
	  press. moveSpeed is mirrored to the Humanoid only for strider today.

	moveSpeed is the absolute Humanoid.WalkSpeed to hold for buffDuration
	seconds, 0 meaning "not applicable" -- every non-strider technique carries
	it at 0 the same way a striker carries mitigation at 0, for one uniform
	shape rather than an optional field only three entries have.
]]
export type Technique = {
	id: string,
	name: string,
	kind: "striker" | "enforcer" | "forger" | "ruler" | "strider",
	madraCost: number,
	cooldown: number,
	windup: number,
	damage: number,
	buffDuration: number,
	damageBuff: number,
	mitigation: number,
	moveSpeed: number,
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
		moveSpeed = 0,
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
		moveSpeed = 0,
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
		moveSpeed = 0,
		regionScaled = false,
	},
	--[[ WHERE you fire from. A bolt drawn from the ground under the caster:
		barren 25, open 50, rich 90, wellspring 130. A wellspring Draught
		out-hits Pierce on a 2.0s cooldown; a barren one is worse than Lance.
		The only striker that defends a node from OUTSIDE it -- a ruler waits
		until the intruder is inside 42 studs, this reaches them at 140 while
		they are still crossing open ground. A Draught player fights from
		rich ground and shoots outward; a Lance player does not care where
		they stand. The windup sits between Lance and Volley in BOTH tuning
		profiles, which the windup-by-damage assertion requires. ]]
	draught = {
		id = "draught",
		name = "Draught",
		kind = "striker",
		madraCost = 28,
		cooldown = 2.0,
		windup = 0.32,
		damage = 50,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 0,
		regionScaled = true,
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
		moveSpeed = 0,
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
		moveSpeed = 0,
		regionScaled = false,
	},
	--[[ WHO is the aggressor. For six seconds you deal +50% and TAKE +35%.
		Negative mitigation is honoured by Combat.mitigationOf (a -0.35 target
		takes 135 from 100 raw) and stacks multiplicatively with everything
		else, so Abandon under a Barrier nets 1 - (1.35 * 0.45) = 39% -- the
		two fight each other honestly. An Abandon player presses it when THEY
		are initiating and the opponent has just spent their burst; a Bulwark
		player presses it when they are being initiated on. The first enforcer
		that is a liability if you misjudge the moment. ]]
	abandon = {
		id = "abandon",
		name = "Abandon",
		kind = "enforcer",
		madraCost = 30,
		cooldown = 12.0,
		windup = 0.1,
		damage = 0,
		buffDuration = 6.0,
		damageBuff = 0.50,
		mitigation = -0.35,
		moveSpeed = 0,
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
		moveSpeed = 0,
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
		moveSpeed = 0,
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
		moveSpeed = 0,
		regionScaled = false,
	},
	--[[ Stand IN it or leave it. Both forger branches at once: not listed in
		SELF_BUFF_FORGERS, so it spawns a construct, and it carries positive
		mitigation, so Combat.use self-buffs at press. buffDuration is read
		twice -- the ring's lifetime and the buff's -- which reads as "while
		the ring stands, you are hardened". 18 x 4 ticks = 72 to anyone
		standing in it; 35% mitigation on you for the same window. A Bastion
		player drops the ring and steps INTO it to fight hardened at melee
		range; a Sentry player drops the ring and backs away from it. The
		mitigation is live 0.5s before the ring appears (press vs windup) --
		that is the resolver's shape, not a bug. 8.5 rather than 8.0 so the
		fourth tick actually lands; see constructTickSeconds. ]]
	bastion = {
		id = "bastion",
		name = "Bastion",
		kind = "forger",
		madraCost = 50,
		cooldown = 14.0,
		windup = 0.5,
		damage = 18,
		buffDuration = 8.5,
		damageBuff = 0,
		mitigation = 0.35,
		moveSpeed = 0,
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
		moveSpeed = 0,
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
		moveSpeed = 0,
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
		moveSpeed = 0,
		regionScaled = true,
	},

	--[[ Strider -- self-only WalkSpeed override, no damage path of its own.
		Three techniques spanning one axis (burst / mid / sustain) rather than
		three flavors of one thing, per the human's own framing of the gap:
		an instant flash is a great juke and bad travel, a persistent boost is
		the reverse, and the choice between them has to be real. Built out of
		Humanoid.WalkSpeed first for all three, including the burst -- it is
		the cheap, honest implementation, and only escalates to a client-
		predicted impulse if a moving-dummy test says WalkSpeed alone doesn't
		read as a juke. Available to everyone from the start: no aura gating,
		no unlock threshold, that axis deferred entire. ]]
	lunge = {
		id = "lunge",
		name = "Lunge",
		kind = "strider",
		madraCost = 20,
		cooldown = 4.0,
		windup = 0.05,
		damage = 0,
		buffDuration = 0.25,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 80,
		regionScaled = false,
	},
	swiftstep = {
		id = "swiftstep",
		name = "Swiftstep",
		kind = "strider",
		madraCost = 22,
		cooldown = 7.0,
		windup = 0.05,
		damage = 0,
		buffDuration = 2.5,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 32,
		regionScaled = false,
	},
	windstride = {
		id = "windstride",
		name = "Windstride",
		kind = "strider",
		madraCost = 30,
		cooldown = 12.0,
		windup = 0.1,
		damage = 0,
		buffDuration = 12.0,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 24,
		regionScaled = false,
	},
} :: { [string]: Technique }

-- One slot per technique type.
Config.LoadoutSlots = { "striker", "enforcer", "forger", "ruler", "strider" }

Config.DefaultLoadout = {
	striker = "lance",
	enforcer = "surge",
	forger = "barrier",
	ruler = "siphon",
	strider = "swiftstep",
}

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
	--[[ Refinement, re-aimed against MEASURED rates rather than guessed ones.

		These were deliberately held at Remi's session values while cycling
		still read the node, because making cycling read the GROUND moves this
		curve by itself and two simultaneous changes would have confounded each
		other. That landed and was measured, so this is the re-aim.

		What the ground change actually did: bare ground was previously always
		350s per tier, because off-node returned `open` unconditionally. It is
		now a 5.2x spread -- 135s in a Wellspring, 700s in the Barrens. And the
		average multiplier on a spawned node rose 12% (1.38 -> 1.55), because
		the old rolled table put 40% of nodes on `open` and the derived
		distribution puts 11%.

		THE TARGET THIS IS AIMED AT: a tester on a MEDIOCRE path -- a common
		node on open ground, the 3x case -- should reach the Lowgold ceiling in
		about ten minutes, so a breakthrough is routinely reachable inside a
		test session rather than being a thing we keep failing to exercise. Ten
		tiers at 60s each is 600s, so the per-tier figure is 3 x 60 = 180.

		What that buys at the extremes: a Wellspring Prime is 3.5s per tier, so
		the ceiling in under a minute if a tester wants it. Barren bare ground
		is 360s, which is slow -- but that is somebody standing in the worst
		square on the map doing nothing, and the spread IS the design now. ]]
	Config.Stages[5].perTierProgress = 180 -- release 9000
	Config.Stages[6].perTierProgress = 490 -- release 24000
	Config.Stages[7].perTierProgress = 900 -- release 45000

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
