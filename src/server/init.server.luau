--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ArenaService = require(script.ArenaService)
local AwarenessService = require(script.AwarenessService)
local CombatService = require(script.CombatService)
local Config = require(ReplicatedStorage.Shared.Config)
local CultivationService = require(script.CultivationService)
local DummyService = require(script.DummyService)
local NodeService = require(script.NodeService)
local PersistenceService = require(script.PersistenceService)
local PresenceService = require(script.PresenceService)

--[[ Fault-isolated startup.

	On the first Studio run a single unwritable property in ArenaService threw
	and took every service after it with it -- no persistence, no combat, no
	awareness, and no PlayerAdded handler, from one line. A service that cannot
	start should be loud and survivable, not silently fatal to the rest. ]]
local function startService(name: string, start: () -> ())
	-- pcall's result arity follows its callee, and these return nothing, so the
	-- error value has to be asked for explicitly.
	local protectedStart = start :: () -> any
	local ok, err = pcall(protectedStart)
	if not ok then
		warn(`[boot] {name} failed to start: {err}`)
	end
	return ok
end

startService("ArenaService", ArenaService.start)
startService("PersistenceService", PersistenceService.start)
NodeService.setDrainedHandler(CultivationService.onNodeDrained)

--[[ Capacity refusal was completely silent: a player standing inside a full
	node earned bare-ground rate with no explanation and nothing to tell them
	why. `CultivationService` cannot call `AwarenessService` directly --
	`AwarenessService` already requires `CultivationService`, so the reverse
	require would be a cycle -- so this is the same injected-handler shape
	`setDrainedHandler` above already uses. `CultivationService.tick` itself
	debounces so this only fires on the transition into refused, not once a
	tick for as long as the player stands there. ]]
local NODE_REFUSAL_MESSAGES: { [string]: string } = {
	at_capacity = "This node already feeds three.",
	expired = "That node has drained.",
}
CultivationService.setRefusalHandler(function(player: Player, reason: string)
	AwarenessService.notify(player, "refused", NODE_REFUSAL_MESSAGES[reason] or reason)
end)

--[[ leaderstats: Roblox's built-in player list, for the same "advancement is
	public and contested" reason PresenceService's own header already gives --
	that pitch was only true of the one opponent standing in front of you.
	CombatService owns the kill moment and PresenceService owns the tally;
	neither requires the other, same shape as the refusal handler above. ]]
CombatService.setKillHandler(function(killer: Player)
	PresenceService.recordKill(killer)
end)

startService("CombatService", CombatService.start)

--[[ Dummies are a testing instrument, not content, but they are wired exactly
	like everything else on purpose: a dummy that went through its own start,
	its own tick or its own damage path would stop being a measuring instrument
	and become a second thing to debug.

	This line is here because it was missing. DummyService was complete, correct
	and 8,513 bytes of dead code -- nothing required it, so `start` never ran,
	the chat hook was never connected, and every /dummy command fell on the
	floor. Nothing caught it: 362 assertions passed, selene was clean and rojo
	built fine, because AN UNREFERENCED MODULE IS PERFECTLY VALID LUAU and a
	module that is never required cannot fail a suite that never requires it. ]]
startService("DummyService", DummyService.start)
startService("AwarenessService", AwarenessService.start)

--[[ Joining yields on the data store, so everything downstream of cultivation
	state has to tolerate a player who does not have one yet. CombatService and
	AwarenessService both do -- they skip the player and pick them up on a later
	tick. ]]
--[[ Each step isolated, for the reason given at the tick loop below: these run
	in order in one handler, so a throw in an early step silently denies the
	player every later one. A player who joined and got no cultivation state, no
	actor and no nameplate is a player with no game, and the join path is the
	one that has never run for a *second* player at all. Load failing should
	cost that player their saved progress, not their entire session. ]]
local function step(name: string, player: Player, run: () -> ())
	local protectedRun = run :: () -> any
	local ok, err = pcall(protectedRun)
	if not ok then
		warn(`[player] {name} failed for {player.Name}: {err}`)
	end
end

local function onPlayerAdded(player: Player)
	local restored = nil
	step("PersistenceService.load", player, function()
		restored = PersistenceService.load(player)
	end)
	step("CultivationService.onPlayerAdded", player, function()
		CultivationService.onPlayerAdded(player, restored)
	end)
	step("CombatService.onPlayerAdded", player, function()
		CombatService.onPlayerAdded(player)
	end)
	step("PresenceService.onPlayerAdded", player, function()
		PresenceService.onPlayerAdded(player)
	end)

	if restored then
		AwarenessService.notify(player, "local", "Your cultivation resumes where you left it.")
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player: Player)
	step("PersistenceService.onPlayerRemoving", player, function()
		PersistenceService.onPlayerRemoving(player)
	end)
	step("PresenceService.onPlayerRemoving", player, function()
		PresenceService.onPlayerRemoving(player)
	end)
	step("AwarenessService.onPlayerRemoving", player, function()
		AwarenessService.onPlayerRemoving(player)
	end)
	step("CombatService.onPlayerRemoving", player, function()
		CombatService.onPlayerRemoving(player)
	end)
	step("CultivationService.onPlayerRemoving", player, function()
		CultivationService.onPlayerRemoving(player)
	end)
end)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

--[[ Breakthrough. The rule lives in CultivationService.tryAdvance; this only
	turns its refusal reason into something a player can read, because "nothing
	happened" is the worst possible answer to pressing the button. ]]
local BREAKTHROUGH_MESSAGES: { [string]: string } = {
	no_state = "Your cultivation has not settled yet.",
	at_cap = "Truegold is the summit. There is nothing above it.",
	not_at_ceiling = "Your refinement has not reached this stage's ceiling.",
	needs_catalyst = "You need a catalyst. They come only from Prime nodes.",
}

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local breakthrough = remotes:WaitForChild("Breakthrough") :: RemoteEvent
breakthrough.OnServerEvent:Connect(function(player: Player)
	local ok, reason = CultivationService.tryAdvance(player)
	if ok then
		local state = CultivationService.getState(player)
		local name = if state then Config.Stages[state.stageIndex].name else "the next stage"
		AwarenessService.notify(player, "server", `You break through to {name}.`)
		return
	end
	AwarenessService.notify(player, "refused", BREAKTHROUGH_MESSAGES[reason] or reason)
end)

--[[ Fault-isolated ticking, for the same reason startup is fault-isolated.

	`startService` above exists because one unwritable property in ArenaService
	threw on the first Studio run and took every service after it with it. The
	tick loop had the identical shape and had not learned the lesson: these six
	calls run in order in one callback, so anything that throws in an early one
	silently skips every later one. A persistent fault in cultivation would mean
	combat, awareness, presence and persistence simply never run again -- for
	everyone in the server, not just the player who triggered it.

	That matters most for exactly the code that has never been exercised. Every
	two-player path in this game is unverified, and a fault that only appears
	with a second player in the server is the most likely kind there is right
	now. This does not fix such a fault; it contains it to its own subsystem and
	writes it down, instead of letting it take the session with it.

	Warnings are throttled per subsystem because a fault that recurs every tick
	would otherwise bury the output window in the noise of its own reporting,
	and the output window is the only diagnostic anyone has during a session. ]]
local WARN_INTERVAL = 5
local lastWarnAt: { [string]: number } = {}

local function tickService(name: string, now: number, run: () -> ())
	-- pcall's result arity follows its callee, and these return nothing, so the
	-- error value has to be asked for explicitly.
	local protectedRun = run :: () -> any
	local ok, err = pcall(protectedRun)
	if ok then
		return
	end
	local last = lastWarnAt[name]
	if not last or now - last >= WARN_INTERVAL then
		lastWarnAt[name] = now
		warn(`[tick] {name} failed: {err}`)
	end
end

local accumulator = 0
RunService.Heartbeat:Connect(function(delta: number)
	accumulator += delta
	local tickLength = Config.Field.cycleTickSeconds
	if accumulator < tickLength then
		return
	end
	local elapsed = accumulator
	accumulator = 0

	local now = os.clock()
	tickService("NodeService", now, function()
		NodeService.step(now)
	end)
	tickService("CultivationService", now, function()
		CultivationService.tick(elapsed, now)
	end)
	tickService("CombatService", now, function()
		CombatService.tick(elapsed, now)
	end)
	tickService("DummyService", now, function()
		DummyService.tick(now)
	end)
	tickService("AwarenessService", now, AwarenessService.tick)
	tickService("PresenceService", now, PresenceService.tick)
	tickService("PersistenceService", now, function()
		PersistenceService.tick(now)
	end)
end)

--[[ The build fingerprint, printed at boot so which code is running is a fact
	in the log rather than something read off a HUD.

	Today this cost most of an afternoon. Studio silently ignores
	`-localProjectFile` and runs its own cached document, giving no error, so
	every session ran the morning build while the file on disk was current --
	and the only way anyone noticed was spotting a wrong number in a screenshot.
	A pixel read is a bad instrument for "am I running my own code"; a line in
	the output window is a good one.

	The per-tier figure is the fingerprint because it is the value the tuning
	profile changes most visibly (350 in development against a release 9000), so
	it distinguishes one from the other at a glance.

	The profile itself is announced through `warn` rather than `print` when it is
	anything but release. A development profile is a correct and useful thing to
	be running -- right up until it is running in front of players, at which
	point it is the most expensive mistake available, because every number in it
	is deliberately wrong for balance. Output-window yellow is cheap insurance
	against the one build nobody meant to ship. ]]
local lowgold = Config.Stages[5]
print(
	`[cultivation] online -- {#Config.Stages} stages, cap at {Config.Stages[#Config.Stages].name}`
)
print(`[cultivation] build check -- {lowgold.name} tier = {lowgold.perTierProgress} progress`)

if Config.Profile == "release" then
	print("[cultivation] profile: release")
else
	warn(
		`[cultivation] PROFILE: {string.upper(Config.Profile)} -- tuning is deliberately wrong for balance. NOT FOR PLAYERS.`
	)
end
