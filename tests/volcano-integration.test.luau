--!strict
-- Composition checks complement executable economy tests. These assert runtime
-- edges that a pure module cannot prove; they are NOT a Studio playtest.
-- Journal contract: Vessel_ash, SolidFire, CinderStep, VolcanoOfferPaid,
-- VolcanoDragonMet are published by CultivationService; VolcanoTrialEnds is
-- temporary service state and must never enter persistence.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local passed, failed = 0, 0
local function check(name: string, condition: boolean)
	if condition then
		passed += 1
	else
		failed += 1
		print("FAIL: " .. name)
	end
end
local function source(path: string): string
	local text = fs.readFile(path)
	text = text:gsub("%-%-%[%[.-%]%]", "")
	return text:gsub("%-%-[^\n]*", "")
end
local function contains(text: string, needle: string): boolean
	return text:find(needle, 1, true) ~= nil
end
local arena = source("src/server/ArenaService.luau")
local boot = source("src/server/init.server.luau")
local service = source("src/server/VolcanoService.luau")
local client = source("src/client/VolcanoClient.client.luau")
local cultivation = source("src/server/CultivationService.luau")
local combat = source("src/server/CombatService.luau")
local nodes = source("src/server/NodeService.luau")
local persistence = source("src/server/PersistenceService.luau")
local progression = source("src/shared/Progression.luau")
local project = serde.decode("json", fs.readFile("default.project.json"))
check("arena constructs adventure geometry", contains(arena, "VolcanoWorld.build("))
check(
	"boot starts expedition after arena",
	(boot:find('startService("ArenaService"', 1, true) or math.huge)
		< (boot:find('startService("VolcanoService"', 1, true) or 0)
)
check(
	"boot advances breathing and trial expiry",
	contains(boot, "VolcanoService.step(now, elapsed)")
)
check(
	"player load also covers first player present before startup",
	contains(boot, "Players:GetPlayers()") and contains(boot, "task.spawn(onPlayerAdded, player)")
)
for _, name in { "VolcanoAction", "VolcanoFeedback" } do
	check(
		name .. " is built into place",
		project.tree.ReplicatedStorage.Remotes[name]["$className"] == "RemoteEvent"
	)
	check(
		name .. " client/server connection",
		contains(service, `WaitForChild("{name}")`) and contains(client, `WaitForChild("{name}")`)
	)
end
local remoteBody = service:match("remote%.OnServerEvent:Connect%((.-)\n\tend%)") or ""
check(
	"remote has narrow action allowlist",
	contains(remoteBody, 'action == "vent" or action == "cinder"')
)
for _, reward in { "refuge", "fissure", "complete_trial", "vent_brazier", "forge", "dragon" } do
	check(
		reward .. " cannot be requested over action remote",
		not contains(remoteBody, '"' .. reward .. '"')
	)
end
check(
	"prompt callbacks retain server station identity",
	contains(service, "act(player, action, object, nil)")
)
check(
	"station distance is server checked",
	contains(service, "root.Position - station.Position")
		and contains(service, "station:IsDescendantOf(Workspace)")
)
check(
	"dead players cannot interact",
	contains(service, "humanoid.Health <= 0")
		and contains(service, "local root = livingRoot(player)")
)
check(
	"server verifies station visibility beyond client prompt flag",
	contains(service, "Workspace:Raycast(") and contains(service, "station.Position")
)
check(
	"expedition writes use single state owner",
	contains(service, "CultivationService.updateState(player")
		and contains(service, "Volcano.act(Config, Progression, state, action)")
)
local updateBody = cultivation:match("function CultivationService%.updateState(.-)\nend") or ""
check(
	"atomic update refuses missing loaded state",
	contains(updateBody, "if not state then") and contains(updateBody, "return false")
)
check(
	"atomic update publishes authoritative result",
	contains(updateBody, "transform(state)") and contains(updateBody, "publish(player)")
)
check(
	"trials bound to living character and timeout",
	contains(service, "trial.character ~= player.Character")
		and contains(service, "now - trial.began > 90")
		and contains(service, "now - trial.began < 6")
)
check(
	"trial timer remains temporary",
	not contains(progression, "trialStarted") and not contains(progression, "VolcanoTrialEnds")
)
for _, attribute in
	{ "Vessel_ash", "SolidFire", "CinderStep", "VolcanoOfferPaid", "VolcanoDragonMet" }
do
	check(
		attribute .. " journal reads published state",
		contains(cultivation:gsub("%s+", ""), `SetAttribute("{attribute}"`)
			and contains(client:gsub("%s+", ""), `GetAttribute("{attribute}")`)
	)
end
check(
	"persistence uses complete state serializer",
	contains(persistence, "Progression.toStore(state)")
)
check(
	"node depletion is called by runtime",
	contains(nodes, "AuraNodes.drain(") or contains(cultivation, "AuraNodes.drain(")
)
local actorBody = combat:match("local function ensureActor(.-)\nend") or ""
check(
	"existing combat actor refreshes shared vessel after expedition spends",
	contains(actorBody, "existing.aura = Progression.vesselTotal(state)")
)
local castBody = combat:match("local function onUseTechnique(.-)\nend") or ""
check(
	"regular cast obtains refreshed actor before spending",
	(castBody:find("ensureActor(player)", 1, true) or math.huge)
		< (castBody:find("Combat.use(", 1, true) or 0)
)
print(`Volcano integration: {passed} passed, {failed} failed`)
if failed > 0 then
	process.exit(1)
end
