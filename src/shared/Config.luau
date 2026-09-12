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

--[[ ======================= AURA TYPES (owner: roster) =======================

	The seam between the Core and the Map, as data. Exactly four, and it stays
	four: new ground maps ONTO one of these, never adds a fifth. A fixed record
	rather than a map keyed by string, so a typo is a compile error caught by
	tests/compile.test rather than a silent zero forever.

	color is r g b integers, never a Color3 -- src/shared stays Lune-loadable.
	The values are first-pass; interface owns whether they read on the vessel
	bar and hands roster the numbers to land. regionHint is prose for a reader,
	not a key anything joins on: the join is Config.RegionAura below. ]]
export type AuraType = {
	name: string,
	color: { r: number, g: number, b: number },
	regionHint: string,
}

Config.AuraTypes = {
	ash = { name = "Ash", color = { r = 255, g = 120, b = 60 }, regionHint = "the Ember Barrens" },
	verdant = {
		name = "Verdant",
		color = { r = 90, g = 200, b = 110 },
		regionHint = "the Verdant Reach",
	},
	lumen = { name = "Lumen", color = { r = 120, g = 200, b = 255 }, regionHint = "a Wellspring" },
	neutral = {
		name = "Neutral",
		color = { r = 200, g = 200, b = 200 },
		regionHint = "open ground",
	},
} :: { ash: AuraType, verdant: AuraType, lumen: AuraType, neutral: AuraType }

--[[ ============ REGION AURA (map team appends; roster owns these lines) ============

	Which aura a region's ground accrues. Read by exactly one pure function once
	the Core lands, so no prose ever performs this mapping again. Every key in
	Config.RegionNames must appear here and every value must be a key of
	Config.AuraTypes -- asserted in tests/combat.test.

	open accrues neutral at 1.0x through StaticRegionMultipliers, not nothing:
	neutral is spendable and processable but flavourless, so a fight on the
	plaza is not a fight lost by attrition, while committed ground stays the
	only way to BECOME something. The header comment on Field.regionWeights
	that called open "affinity-inactive" is superseded by this table.

	MAP TEAM: add one line per new biome below the marker. Never rename a key;
	region ids are frozen strings. ]]
Config.RegionAura = {
	barren = "ash",
	rich = "verdant",
	wellspring = "lumen",
	open = "neutral",
	-- map team: new biomes below this line --
} :: { [string]: "ash" | "verdant" | "lumen" | "neutral" }

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
	auraMultiplier = 2.0,
	-- Fraction of the aura pool regenerated per second.
	auraRegenFraction = 0.06,
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
	--[[ Cross-bracket combat, per bracket-tone.md. "refuse" (release):
		Combat.canEngage's silent refusal at damageCombatant, now voiced --
		combat is refused and the attacker is told why. "notice" (development
		override below): the hit lands unscaled and the attacker gets a
		placeholder-marked, deliberately unflattering line instead of a wall.
		The ratchet, the intra-bracket spread and canEngage itself are
		unchanged in both modes -- this decides what happens AFTER canEngage
		disagrees, not whether it can. ]]
	crossBracket = "refuse" :: "refuse" | "notice",
	-- Forger constructs damage on an interval rather than continuously, so a
	-- technique's `damage` reads as damage *per tick*. At 2s, caltrops over its
	-- full 10s window is 5 ticks (150) and sentry over 12s is 6 (144) -- around
	-- a third of a Lowgold pool for standing still in a hazard you can walk out
	-- of. Zoning pressure, not a kill button. The tick that lands exactly on
	-- expiry does fire: `Combat.stepConstructTimer` decides tick before
	-- expiry, so a round duration delivers `duration / tick` ticks and no
	-- construct below needs to pad past a multiple to get its last one.
	constructTickSeconds = 2.0,
}

--[[ ========================= THE CORE (owner: roster) =========================

	The resource that remembers what you cultivated. Nothing reads these yet;
	they are the vocabulary the Core team builds against, landed first so both
	teams unblock on one contract. Three quantities, kept distinct on purpose:
	the VESSEL (raw aura, typed, one shared capacity), the CORE (what you have
	processed, permanent), and the spendable pool -- which IS the vessel.

	capacityMultiplier -- vessel capacity is Combat.auraCapacity(stage) times
		this: 1200 at Lowgold. Sized by TIME TO FILL, not by the ability pool --
		pegged to the pool (200) a wellspring prime at 52 aura/s filled it in
		3.8 s and processing became a button to mash every four seconds. At 6:
		a wellspring prime fills it in 23 s (a decision made a couple of times
		during a drain fight), a common node on rich ground in 3.7 min (a
		rhythm, not a chore), and twenty casts of the default loadout spend
		about half of it (the pool keeps a fight role and ground-as-regen keeps
		its teeth). Costs stay where they are; "not prohibitive" is the bigger
		vessel, not cheaper techniques.
	processYield -- progress granted per point of aura processed. At this
		capacity the 2.0 s channel is under 1% of a common node's fill time, so
		1.0 holds the development time-to-tier table within 2% at common and
		rare nodes: a point of aura is a point of progress. A prime being fast
		is a prime being a prime.
	processSeconds -- the channel, through the existing cast machinery, so a
		hit interrupts it and it is not done mid-fight.
	processFloor -- processing is unavailable below this fraction of capacity,
		so there is nothing to mash.
	passiveFraction -- the fraction of today's cycling progress that still flows
		without processing. 0 so the human feels the pure mechanic first: every
		point of progress flows through a decision. If that reads as a chore
		the number moves, not the design; the commissioned design's candidate
		is 0.25.
	floorTrickleFraction -- region-independent vessel refill, as a fraction of
		capacity per second, so nobody is ever softlocked on bare ground: 2.4
		aura/s at Lowgold, a Lance every seven or eight seconds. A floor exists
		so nobody is stuck, not so bare ground competes with a lobe -- at 0.01
		against a 1200 vessel it was a Lance every 1.5 s on the plaza, which
		blunts the one thing ground-as-regen is for. ]]
Config.Core = {
	capacityMultiplier = 6,
	processYield = 1.0,
	processSeconds = 2.0,
	processFloor = 0.25,
	passiveFraction = 0,
	floorTrickleFraction = 0.002,
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
	- Constructs tick every constructTickSeconds, tick-before-expiry, so a
	  round duration delivers exactly duration / tick ticks.
	- Windup on an enforcer only delays the presentation; the buff is live at
	  press. moveSpeed is mirrored to the Humanoid for ANY kind that carries
	  it, and Combat.moveSpeedOf is highest-wins, so a value below
	  baseWalkSpeed is a self-slow only while no faster override is live.

	Frostbolt's fields (targeting, castTime, interruptible, projectile,
	slow) are the seam for lock-and-cast channelled techniques. targeting,
	castTime and interruptible are carried uniformly -- "aim", 0 and false on
	every technique that is not one -- the same way moveSpeed is carried at
	0. projectile and slow are optional: they are dispatch payloads that only
	mean something on a technique whose resolver reads them, and a default
	would have to invent a semantics for every existing striker. Config
	holds the data; CombatService dispatches on it the way it already
	dispatches on kind.

	moveSpeed is the absolute Humanoid.WalkSpeed to hold for buffDuration
	seconds, 0 meaning "not applicable" -- every non-strider technique carries
	it at 0 the same way a striker carries mitigation at 0, for one uniform
	shape rather than an optional field only three entries have.
]]
--[[ The gating-metadata contract, COMBAT_VISION (k). Nothing reads it yet;
	every technique carries `{ kind = "always" }` so that when earned level,
	aura depth and Paths arrive they gate a technique by editing one field
	rather than by adding one. An always-true gate on everything that has not
	earned a real one is the contract, not a placeholder. ]]
export type UnlockRequirement =
	{ kind: "always" }
	| { kind: "auraDepth", aura: "ash" | "verdant" | "lumen", threshold: number }
	| { kind: "tier", tier: number }
	| { kind: "path", path: string }

export type Technique = {
	id: string,
	name: string,
	kind: "striker" | "enforcer" | "forger" | "ruler" | "strider",
	auraCost: number,
	cooldown: number,
	windup: number,
	damage: number,
	buffDuration: number,
	damageBuff: number,
	mitigation: number,
	moveSpeed: number,
	regionScaled: boolean,
	targeting: "aim" | "lock",
	castTime: number,
	interruptible: boolean,
	projectile: string?,
	slow: { walkSpeed: number, duration: number }?,
	unlockRequirement: UnlockRequirement,
}

Config.Techniques = {
	-- Striker
	lance = {
		id = "lance",
		name = "Lance",
		kind = "striker",
		auraCost = 18,
		cooldown = 1.2,
		windup = 0.15,
		damage = 42,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 0,
		regionScaled = false,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
	},
	volley = {
		id = "volley",
		name = "Volley",
		kind = "striker",
		auraCost = 30,
		cooldown = 2.6,
		windup = 0.35,
		damage = 66,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 0,
		regionScaled = false,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
	},
	pierce = {
		id = "pierce",
		name = "Pierce",
		kind = "striker",
		auraCost = 44,
		cooldown = 5.0,
		windup = 0.9,
		damage = 128,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 0,
		regionScaled = false,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
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
		auraCost = 28,
		cooldown = 2.0,
		windup = 0.32,
		damage = 50,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 0,
		regionScaled = true,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
	},
	--[[ WHEN you fire: through their attack, not on their cooldown. The
		self-buff block fires at press, so 45% mitigation covers the 0.55s
		windup and 0.65s after it. Every other striker's windup is its most
		dangerous moment; this one's is its safest. A Brace player casts while
		being shot; a Pierce player waits for the opponent's cooldown. Not
		assemblable from Bulwark, which is six seconds on eleven -- this is
		1.2s tied to every cast on three. ]]
	brace = {
		id = "brace",
		name = "Brace",
		kind = "striker",
		auraCost = 32,
		cooldown = 3.0,
		windup = 0.55,
		damage = 72,
		buffDuration = 1.2,
		damageBuff = 0,
		mitigation = 0.45,
		moveSpeed = 0,
		regionScaled = false,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
	},
	--[[ WHO you fire at: only someone who cannot leave. 1.6s is a longer
		telegraph than every ruler but Tempest, and every strider in the pool
		escapes it -- so it lands on a target mid-Tempest windup, standing in
		their own Bastion, or cycling a node they will not give up, and on
		nobody else. 220 is over half a Lowgold pool. A Verdict player's
		entire skill is target selection; a Lance player fires at anyone. ]]
	verdict = {
		id = "verdict",
		name = "Verdict",
		kind = "striker",
		auraCost = 60,
		cooldown = 14.0,
		windup = 1.6,
		damage = 220,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 0,
		regionScaled = false,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
	},
	--[[ Instant aim versus a guaranteed hit after a commitment you can be
		knocked out of. The first lock-and-cast technique: pick a target, hold
		three seconds, and if you are still standing, still in range and still
		have line of sight when the channel completes, a homing bolt leaves
		that cannot be aimed away from. Any hit taken during the channel
		breaks it. On arrival it halves the target's WalkSpeed for three
		seconds -- the same target Verdict wants and Cataclysm needs.

		A Frostbolt player fires only when the opponent cannot reach them
		for three seconds -- from outside their range, from a corner, while
		they are busy; a Lance player fires whenever the reticle is on
		someone. The cast bar is castTime; windup is 0 by the one-timer rule
		and the pool invariant that enforces it.

		Priced by that same rule's other half: a harder hit never commits
		SHORTER, so the longest commit in the striker pool must also be its
		heaviest hit or the assertion refuses it. That floor is right --
		three seconds interruptible by any hit is the most expensive commit
		in the game -- so this sits just above Verdict, and the two stay
		distinct on everything else: Verdict is aimed, dodgeable and cannot be
		interrupted; Frostbolt is locked, undodgeable and can. ]]
	frostbolt = {
		id = "frostbolt",
		name = "Frostbolt",
		kind = "striker",
		auraCost = 60,
		cooldown = 12.0,
		windup = 0,
		damage = 230,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 0,
		regionScaled = false,
		targeting = "lock",
		castTime = 3.0,
		interruptible = true,
		unlockRequirement = { kind = "always" },
		projectile = "homing",
		slow = { walkSpeed = 8, duration = 3.0 },
	},

	--[[ PROJECTILE VARIATIONS -- the roster as an instrument. Each of these
		differs from Frostbolt in a DIFFERENT field, so a failure names the
		field. The set and its falsifiable checks live in
		.agent-reports/projectile-variations.md; argue with it by edit. ]]

	--[[ The execute: twice Frostbolt's channel and it CANNOT be interrupted
		-- `interruptible = false` is read in damageCombatant, so a hit taken
		mid-channel does nothing to the bar. Only range, line of sight or the
		target's death can stop it, and there is no projectile: the damage is
		hitscan at completion. A Rime player fires it at someone who has
		nowhere to go; a Frostbolt player fires it at someone who cannot
		reach them. Six seconds is the longest commit in the pool, so by the
		commit-ordering rule it is also the heaviest hit. Tests: the
		uninterruptible flag, a long channel, a channel with no projectile. ]]
	rime = {
		id = "rime",
		name = "Rime",
		kind = "striker",
		auraCost = 90,
		cooldown = 20.0,
		windup = 0,
		damage = 320,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 0,
		regionScaled = false,
		targeting = "lock",
		castTime = 6.0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
	},
	--[[ The snare: Frostbolt's shape at a twelfth of the commit and a tenth
		of the damage, for the slow rather than the hit. A quarter-second
		lock channel, a homing bolt, WalkSpeed 6 for two seconds on arrival
		-- taken to set up Rime, or to land Glacier on a target that cannot
		sidestep it. 0.1 is UNDER interface's 0.15 floor on purpose: it is the
		named sub-floor channel (interface.test's SUB_FLOOR_CHANNELS lists it
		by id, so the next one fails until added deliberately), and asking
		what a 0.1s channel would show found a HUD bug before this entry
		existed -- an interrupted sub-floor channel drew nothing at all, no
		bar and no snap, fixed at f04dd38. What it exposes now is the snap:
		interface's fixed 0.35s break outlasts the channel it interrupts,
		because the snap is the event of the break, not the time spent in
		red. Tests: a sub-floor channel, a quick homing bolt, a load-bearing
		slow, and that snap. Priced by the rule, which constrains the
		HEAVIER technique: every striker that hits harder must commit at
		least 0.1 -- and Chill and Shard commit 0.15 and 0 at 20, so this
		hits 20 too: the lightest tier, for the slow and not the hit. ]]
	hoarfrost = {
		id = "hoarfrost",
		name = "Hoarfrost",
		kind = "striker",
		auraCost = 20,
		cooldown = 5.0,
		windup = 0,
		damage = 20,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 0,
		regionScaled = false,
		targeting = "lock",
		castTime = 0.1,
		interruptible = true,
		unlockRequirement = { kind = "always" },
		projectile = "homing",
		slow = { walkSpeed = 6, duration = 2.0 },
	},
	--[[ The skillshot poke: aim, instant, a straight bolt along the sampled
		aim, no slow, no channel. The first technique whose telegraph is the
		FLIGHT rather than a bar -- windup 0, no cast bar at all, and you
		dodge the bolt, which is what skillshot means; interface's telegraph
		rule accepts a projectile as the second shape of telegraph. Cheap and
		spammable; punishes a predictable approach, loses to a juke. A Shard
		player leads the target; a Lance player puts the reticle on them.
		Tests: aim + projectile on the instant path, and the hit X sitting on
		the reticle -- the concentricity check, on a keyboard. Priced by the
		rule: commit 0 is the shortest in the pool, so nothing lighter may
		commit longer -- it matches Chill at 20 rather than out-hitting it. ]]
	shard = {
		id = "shard",
		name = "Shard",
		kind = "striker",
		auraCost = 14,
		cooldown = 0.9,
		windup = 0,
		damage = 20,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 0,
		regionScaled = false,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
		projectile = "straight",
	},
	--[[ The setup hit: aim, instant, hitscan, and a slow -- no projectile, no
		channel. Proves the slow is separable from both: it rides
		resolveStriker's hit through applySlowIfAny (combat's item 1), the
		same call a channel's landing makes. Trades damage for WalkSpeed 10
		for three seconds -- the opener before a Glacier or a Rime. Windup
		0.15 is the smallest bar interface draws, and it is drawn: an
		instant hitscan with neither bar nor bolt is exactly what the
		telegraph rule exists to refuse. A Chill player opens with it; a
		Lance player never slows anyone. ]]
	chill = {
		id = "chill",
		name = "Chill",
		kind = "striker",
		auraCost = 16,
		cooldown = 4.0,
		windup = 0.15,
		damage = 20,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 0,
		regionScaled = false,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
		slow = { walkSpeed = 10, duration = 3.0 },
	},
	--[[ The charged skillshot: Frostbolt's commitment with no lock. An aim
		channel -- the aim is sampled at press and stored on the cast, and
		completion fires a straight bolt along THAT aim, not where the
		camera points 1.5s later (the windup rule, extended to channels).
		You commit to a line, not a person: a dash sideways beats it where
		nothing beats Frostbolt but a hit. A Glacier player fires it down a
		corridor at someone who has to come through; a Frostbolt player
		fires it at someone who cannot reach them. Tests: aim-channel
		completion with no target id, along the stored aim; interrupt mid-
		channel snaps the bar and launches nothing. Priced by the rule:
		between Pierce at 0.9 and Verdict at 1.6. ]]
	glacier = {
		id = "glacier",
		name = "Glacier",
		kind = "striker",
		auraCost = 44,
		cooldown = 8.0,
		windup = 0,
		damage = 160,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 0,
		regionScaled = false,
		targeting = "aim",
		castTime = 1.5,
		interruptible = true,
		unlockRequirement = { kind = "always" },
		projectile = "straight",
	},

	--[[ FAMILIES ON THE AURA LATTICE -- one per aura, so that when aura
		farming and unlockRequirement arrive they find content pre-aligned
		with ground that already exists. ash / Ember Barrens: attrition and
		denial. verdant / Verdant Reach: tether and sustain. lumen /
		Wellspring: reveal and pierce. Frost stays the un-aligned starter set.
		The set is at .agent-reports/families.md; entries land here as the
		server can dispatch them, data-only ones first. ]]

	--[[ ASH -- scorch, the chase-ender. A charged skillshot whose hit makes
		the target unable to run: a straight bolt along the aim held at cast,
		and on arrival WalkSpeed 12 for four seconds. Glacier is the corridor
		punish -- a line, no slow; Scorch is what you take when the fight is
		a pursuit. Both projectile kinds land through applySlowIfAny, so the
		slow on a straight bolt is data today. ]]
	scorch = {
		id = "scorch",
		name = "Scorch",
		kind = "striker",
		auraCost = 40,
		cooldown = 6.0,
		windup = 0,
		damage = 100,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 0,
		regionScaled = false,
		targeting = "aim",
		castTime = 0.8,
		interruptible = true,
		unlockRequirement = { kind = "always" },
		projectile = "straight",
		slow = { walkSpeed = 12, duration = 4.0 },
	},
	--[[ VERDANT -- thornlash, the aim snare. Cheap, fast, and the reason to
		take it is the slow, not the 34: WalkSpeed 9 for two seconds on a
		straight bolt, so a runner who is hit stops being a runner. Shard is
		the poke you spam at an approach; Thornlash is what you fire at a
		back. Windup 0.15 rather than 0 so it prices above the 20 tier under
		the commit-ordering rule; the bar is one frame past the floor and
		the flight is the real telegraph. ]]
	thornlash = {
		id = "thornlash",
		name = "Thornlash",
		kind = "striker",
		auraCost = 20,
		cooldown = 1.6,
		windup = 0.15,
		damage = 34,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 0,
		regionScaled = false,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
		projectile = "straight",
		slow = { walkSpeed = 9, duration = 2.0 },
	},

	-- Enforcer
	surge = {
		id = "surge",
		name = "Surge",
		kind = "enforcer",
		auraCost = 32,
		cooldown = 9.0,
		windup = 0.1,
		damage = 0,
		buffDuration = 5.0,
		damageBuff = 0.35,
		mitigation = 0,
		moveSpeed = 0,
		regionScaled = false,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
	},
	bulwark = {
		id = "bulwark",
		name = "Bulwark",
		kind = "enforcer",
		auraCost = 28,
		cooldown = 11.0,
		windup = 0.1,
		damage = 0,
		buffDuration = 6.0,
		damageBuff = 0,
		mitigation = 0.40,
		moveSpeed = 0,
		regionScaled = false,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
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
		auraCost = 30,
		cooldown = 12.0,
		windup = 0.1,
		damage = 0,
		buffDuration = 6.0,
		damageBuff = 0.50,
		mitigation = -0.35,
		moveSpeed = 0,
		regionScaled = false,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
	},
	--[[ ASH -- wildfire, the posture for fighting while MOVING. Faster
		(WalkSpeed 21), harder-hitting (+25%) and glassier (+15% taken) for
		five seconds: the kiting posture. Abandon is the same bargain for a
		player who stands and trades; Wildfire is for one who does not stop.
		moveSpeed is kind-agnostic since 90acec2, and highest-wins: a live
		Windstride at 24 outruns it, which is fine -- the sustain is the
		sustain, this is the fight inside it. ]]
	wildfire = {
		id = "wildfire",
		name = "Wildfire",
		kind = "enforcer",
		auraCost = 30,
		cooldown = 11.0,
		windup = 0.1,
		damage = 0,
		buffDuration = 5.0,
		damageBuff = 0.25,
		mitigation = -0.15,
		moveSpeed = 21,
		regionScaled = false,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
	},
	--[[ VERDANT -- ironroot, tank in PLACE: the exact inverse of strider.
		70% mitigation at half WalkSpeed for four seconds. An Ironroot player
		decides the fight happens HERE and gives up the ability to leave it;
		a Bulwark player stays mobile. Known and accepted: moveSpeedOf is
		highest-wins, so a live strider buff un-roots you and keeps the
		mitigation -- pressing Windstride mid-Ironroot is a choice, not a
		bug. Held since wave one for the moveSpeed un-gate; joins verdant. ]]
	ironroot = {
		id = "ironroot",
		name = "Ironroot",
		kind = "enforcer",
		auraCost = 34,
		cooldown = 12.0,
		windup = 0.1,
		damage = 0,
		buffDuration = 4.0,
		damageBuff = 0,
		mitigation = 0.70,
		moveSpeed = 8,
		regionScaled = false,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
	},

	-- Forger
	barrier = {
		id = "barrier",
		name = "Barrier",
		kind = "forger",
		auraCost = 40,
		cooldown = 12.0,
		windup = 0.4,
		damage = 0,
		buffDuration = 8.0,
		damageBuff = 0,
		mitigation = 0.55,
		moveSpeed = 0,
		regionScaled = false,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
	},
	caltrops = {
		id = "caltrops",
		name = "Caltrops",
		kind = "forger",
		auraCost = 45,
		cooldown = 10.0,
		windup = 0.5,
		damage = 30,
		buffDuration = 10.0,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 0,
		regionScaled = false,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
	},
	sentry = {
		id = "sentry",
		name = "Sentry",
		kind = "forger",
		auraCost = 55,
		cooldown = 16.0,
		windup = 0.7,
		damage = 24,
		buffDuration = 12.0,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 0,
		regionScaled = false,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
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
		that is the resolver's shape, not a bug. ]]
	bastion = {
		id = "bastion",
		name = "Bastion",
		kind = "forger",
		auraCost = 50,
		cooldown = 14.0,
		windup = 0.5,
		damage = 18,
		buffDuration = 8.0,
		damageBuff = 0,
		mitigation = 0.35,
		moveSpeed = 0,
		regionScaled = false,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
	},

	-- Ruler -- these are the terrain-dependent ones. Monstrous in a
	-- wellspring, close to useless on barren ground.
	upheaval = {
		id = "upheaval",
		name = "Upheaval",
		kind = "ruler",
		auraCost = 70,
		cooldown = 14.0,
		windup = 1.4,
		damage = 95,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 0,
		regionScaled = true,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
	},
	siphon = {
		id = "siphon",
		name = "Siphon",
		kind = "ruler",
		auraCost = 50,
		cooldown = 11.0,
		windup = 0.8,
		damage = 55,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 0,
		regionScaled = true,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
	},
	tempest = {
		id = "tempest",
		name = "Tempest",
		kind = "ruler",
		auraCost = 85,
		cooldown = 20.0,
		windup = 1.8,
		damage = 140,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 0,
		regionScaled = true,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
	},
	--[[ The ruler that works in the Barrens. Flat 45 everywhere: loses to
		Siphon on rich (99) and wellspring (143), wins on barren (27) and
		matches it on open. A Pulse player takes fights on poor ground -- a
		contested Barrens node, the open corridors -- where a Siphon player's
		ruler slot is switched off; a Siphon player picks the ground first and
		the fight second. The first ruler whose decision is about where NOT
		to need rich ground. ]]
	pulse = {
		id = "pulse",
		name = "Pulse",
		kind = "ruler",
		auraCost = 40,
		cooldown = 8.0,
		windup = 0.6,
		damage = 45,
		buffDuration = 0,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 0,
		regionScaled = false,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
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
		auraCost = 20,
		cooldown = 4.0,
		windup = 0.05,
		damage = 0,
		buffDuration = 0.25,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 80,
		regionScaled = false,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
	},
	swiftstep = {
		id = "swiftstep",
		name = "Swiftstep",
		kind = "strider",
		auraCost = 22,
		cooldown = 7.0,
		windup = 0.05,
		damage = 0,
		buffDuration = 2.5,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 32,
		regionScaled = false,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
	},
	windstride = {
		id = "windstride",
		name = "Windstride",
		kind = "strider",
		auraCost = 30,
		cooldown = 12.0,
		windup = 0.1,
		damage = 0,
		buffDuration = 12.0,
		damageBuff = 0,
		mitigation = 0,
		moveSpeed = 24,
		regionScaled = false,
		targeting = "aim",
		castTime = 0,
		interruptible = false,
		unlockRequirement = { kind = "always" },
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
	`auraRegenFraction = 0.60` refills a Lowgold pool in 1.7 seconds, so under
	`development` AURA STOPS BEING A CONSTRAINT AT ALL and a fighter is limited
	only by cooldowns. A time-to-kill measured there is the cooldown-limited
	FLOOR, not the real fight. Under `release` the pool regenerates 12 aura per
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

	--[[ Aura regen is the single biggest limit on testing throughput. At the
		release 6%/sec a tester spends most of their time waiting on a pool
		rather than exercising techniques; at 60% the pool refills in under two
		seconds and COOLDOWNS BECOME THE ONLY CONSTRAINT, which is exactly what
		you want when the job is "press all twelve of these and watch what
		happens". This is the number the human asked for by name. ]]
	Config.Combat.auraRegenFraction = 0.60 -- release 0.06

	--[[ Cross-bracket combat, per bracket-tone.md. The human's own words
		called this temporary; it stays behind the profile rather than
		becoming a design change nobody asked for. Two friends at different
		stages can fight tonight, with a placeholder-marked line saying so on
		every hit rather than a silent wall. Release keeps the bracket design
		the ratchet and the intra-bracket spread depend on. ]]
	Config.Combat.crossBracket = "notice" -- release "refuse"

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
