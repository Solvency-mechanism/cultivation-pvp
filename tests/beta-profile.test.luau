--!strict
--[[ The checked-in profile is a restricted beta candidate: it must retain the
	throughput affordances testers need, while never sharing save data with either
	the historical development playtest or the eventual public release. ]]
local fs = require("@lune/fs")
local process = require("@lune/process")
local Config = require("../src/shared/Config")

local passed, failed = 0, 0
local function check(name: string, condition: boolean)
	if condition then
		passed += 1
	else
		failed += 1
		print("FAIL: " .. name)
	end
end

check("active profile is beta", Config.Profile == "beta")
check("development is a tester profile", Config.isTesterProfile("development"))
check("beta is a tester profile", Config.isTesterProfile("beta"))
check("release is not a tester profile", not Config.isTesterProfile("release"))
check("unknown profile is not a tester profile", not Config.isTesterProfile("unknown"))
check("beta keeps fast Lowgold progression", Config.Stages[5].perTierProgress == 180)
check("beta keeps fast aura regeneration", Config.Combat.auraRegenFraction == 0.60)
check("beta allows cross-bracket tester combat", Config.Combat.crossBracket == "notice")
check(
	"beta keeps tester node cadence",
	Config.Field.spawnIntervalSeconds == 10 and Config.Field.maxActiveNodes == 7
)
check(
	"beta keeps visible tester windups",
	Config.Techniques.lance.windup == 0.28 and Config.Techniques.volley.windup == 0.50
)
check(
	"beta store is isolated from development and release",
	Config.Persistence.storeName == "Cultivation_beta_20260920"
		and Config.Persistence.storeName ~= "Cultivation_playtest_20260910"
		and Config.Persistence.storeName ~= "Cultivation_v1"
)

local nodeService = fs.readFile("src/server/NodeService.luau")
check(
	"node telemetry follows the tester-profile boundary",
	nodeService:find("Config.isTesterProfile(Config.Profile)", 1, true) ~= nil
)

local launcher = fs.readFile("play.ps1")
check(
	"beta launcher bypasses the generic work-slice prompt",
	launcher:find('if ($branch -ne "main" -and $prof -ne "beta")', 1, true) ~= nil
)
check(
	"beta launcher retains the final deployment verdict",
	launcher:find("final clean+matching-origin verdict decides deployability", 1, true) ~= nil
)

print(`Beta profile: {passed} passed, {failed} failed`)
if failed > 0 then
	process.exit(1)
end
