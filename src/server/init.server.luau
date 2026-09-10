--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ArenaService = require(script.ArenaService)
local AwarenessService = require(script.AwarenessService)
local CombatService = require(script.CombatService)
local Config = require(ReplicatedStorage.Shared.Config)
local CultivationService = require(script.CultivationService)
local NodeService = require(script.NodeService)
local PersistenceService = require(script.PersistenceService)

ArenaService.start()
PersistenceService.start()
NodeService.setDrainedHandler(CultivationService.onNodeDrained)
CombatService.start()
AwarenessService.start()

--[[ Joining yields on the data store, so everything downstream of cultivation
	state has to tolerate a player who does not have one yet. CombatService and
	AwarenessService both do -- they skip the player and pick them up on a later
	tick. ]]
local function onPlayerAdded(player: Player)
	local restored = PersistenceService.load(player)
	CultivationService.onPlayerAdded(player, restored)
	CombatService.onPlayerAdded(player)

	if restored then
		AwarenessService.notify(player, "local", "Your cultivation resumes where you left it.")
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player: Player)
	PersistenceService.onPlayerRemoving(player)
	AwarenessService.onPlayerRemoving(player)
	CombatService.onPlayerRemoving(player)
	CultivationService.onPlayerRemoving(player)
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
	NodeService.step(now)
	CultivationService.tick(elapsed, now)
	CombatService.tick(elapsed, now)
	AwarenessService.tick()
	PersistenceService.tick(now)
end)

print(
	`[cultivation] online -- {#Config.Stages} stages, cap at {Config.Stages[#Config.Stages].name}`
)
