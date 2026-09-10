--!strict
--[[
	DataStore persistence for cultivation state.

	At Lowgold pacing a stage is hours of play, so losing a session is not a
	minor annoyance -- it is the difference between a playtest and a demo. This
	is also the system most able to do real harm, so the rules here are:

	- A failed load NEVER overwrites a save. A player whose data could not be
	  read is marked unsaveable for the session and plays on a fresh state, and
	  is told so, rather than silently having their progress replaced.
	- Every store call is wrapped and retried. Throwing out of a PlayerAdded
	  handler would leave a player with no state at all.
	- Stored data is run through Progression.sanitizeState before it is trusted,
	  because saves outlive the config that wrote them.

	DataStores are unavailable in an unpublished place and in Studio without
	"Enable Studio Access to API Services". That is an expected condition, not an
	error: the game runs in memory and says so once.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Progression = require(ReplicatedStorage.Shared.Progression)
local CultivationService = require(script.Parent.CultivationService)

local PersistenceService = {}

local ATTEMPTS = 3
local RETRY_SECONDS = 2

local store: DataStore? = nil
local storeUnavailable = false
local saveable: { [number]: boolean } = {}
local lastSaveAt: { [number]: number } = {}

local function keyFor(userId: number): string
	return `player_{userId}`
end

--[[ Report a store failure once per server rather than once per call. A place
	without API access would otherwise fill the log with the same line. ]]
local function reportUnavailable(context: string, message: string)
	if storeUnavailable then
		return
	end
	storeUnavailable = true
	warn(`[persistence] data store unavailable ({context}): {message}`)
	warn("[persistence] continuing in memory -- progress will not survive this server")
end

local function withRetry<T>(context: string, call: () -> T): (boolean, T?)
	-- Once the store is known to be gone, stop paying the retry delay. In an
	-- unpublished place that would otherwise stall every single join by the full
	-- backoff, which makes playtesting worse for no information.
	if storeUnavailable then
		return false, nil
	end
	for attempt = 1, ATTEMPTS do
		local ok, result = pcall(call)
		if ok then
			return true, result
		end
		if attempt == ATTEMPTS then
			reportUnavailable(context, tostring(result))
			return false, nil
		end
		task.wait(RETRY_SECONDS * attempt)
	end
	return false, nil
end

--[[ Load a player's state. Returns nil when there is nothing stored *or* when
	the read failed -- the caller cannot tell them apart, which is deliberate:
	both mean "start them fresh". The difference is recorded in `saveable`, and
	only a clean read permits a later write. ]]
function PersistenceService.load(player: Player): Progression.State?
	local active = store
	if not active then
		saveable[player.UserId] = false
		return nil
	end

	local ok, raw = withRetry(`load {player.UserId}`, function()
		return active:GetAsync(keyFor(player.UserId))
	end)

	if not ok then
		-- Never write over data we could not read.
		saveable[player.UserId] = false
		return nil
	end

	saveable[player.UserId] = true
	if raw == nil then
		return nil
	end
	return Progression.sanitizeState(Config, raw)
end

function PersistenceService.save(player: Player): boolean
	local active = store
	if not active or saveable[player.UserId] ~= true then
		return false
	end

	local state = CultivationService.getState(player)
	if not state then
		return false
	end

	local record = {
		stageIndex = state.stageIndex,
		tier = state.tier,
		progress = state.progress,
		catalysts = state.catalysts,
		savedAt = os.time(),
	}

	local ok = withRetry(`save {player.UserId}`, function()
		active:SetAsync(keyFor(player.UserId), record)
		return true
	end)

	if ok then
		lastSaveAt[player.UserId] = os.clock()
	end
	return ok
end

function PersistenceService.onPlayerRemoving(player: Player)
	PersistenceService.save(player)
	saveable[player.UserId] = nil
	lastSaveAt[player.UserId] = nil
end

function PersistenceService.tick(now: number)
	local interval = Config.Persistence.autosaveSeconds
	for _, player in Players:GetPlayers() do
		local last = lastSaveAt[player.UserId]
		if not last then
			-- Stagger the first autosave so a full server does not save in
			-- lockstep and burn the request budget in one tick.
			lastSaveAt[player.UserId] = now + math.random() * interval
			continue
		end
		if now - last >= interval then
			PersistenceService.save(player)
		end
	end
end

function PersistenceService.start()
	local ok, opened = pcall(function()
		return DataStoreService:GetDataStore(Config.Persistence.storeName)
	end)
	if ok then
		store = opened
	else
		reportUnavailable("open", tostring(opened))
	end

	-- The server gets a grace period to finish writes on shutdown. Studio play
	-- sessions do not, and would hang on it.
	game:BindToClose(function()
		if RunService:IsStudio() then
			return
		end
		for _, player in Players:GetPlayers() do
			PersistenceService.save(player)
		end
	end)
end

return PersistenceService
