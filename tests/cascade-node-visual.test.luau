--!strict
local process = require("@lune/process")
local Visual = require("../src/shared/CascadeNodeVisual")
local passed, failed = 0, 0
local function check(name: string, condition: boolean)
	if condition then
		passed += 1
	else
		failed += 1
		print("FAIL: " .. name)
	end
end
for _, region in { "open", "rich", "barren" } do
	check(region .. " never gets Cascade presentation", not Visual.isScoped(region, true))
end
check("missing biome root excludes compact nodes", not Visual.isScoped("wellspring", false))
check("all Wellspring ground qualifies when Cascade exists", Visual.isScoped("wellspring", true))
check("unknown region stays unchanged", not Visual.isScoped("unknown", true))
local colorToken = {}
local base = {
	color = colorToken,
	core = 9.4,
	hover = 8.2,
	column = 50,
	shards = 8,
	shardHeight = 26,
	rate = 34,
	light = 60,
	shaft = 300,
	captureRadius = 14,
}
local lastCore, lastShards = 0, 0
for _, tier in { "common", "rare", "prime" } do
	check(
		tier .. " outside scope returns original exact style",
		Visual.select(base, tier, false) == base
	)
	local selected = Visual.select(base, tier, true)
	check(tier .. " gets a separate specification", selected ~= base)
	check(tier .. " retains tier color", selected.color == colorToken)
	check(tier .. " has no shaft or light", selected.shaft == 0 and selected.light == 0)
	check(
		tier .. " bounded low silhouette",
		selected.core <= 3.6
			and selected.hover <= 0.8
			and selected.column <= 8
			and selected.shardHeight <= 4
			and selected.shards <= 4
	)
	check(tier .. " bounded particle rate", selected.rate <= 5)
	check(
		tier .. " remains distinguishable by size and count",
		selected.core > lastCore and selected.shards > lastShards
	)
	check(tier .. " unrelated capture data preserved", selected.captureRadius == 14)
	check(tier .. " broad disc is barely tinted", selected.ringTransparency >= 0.95)
	check(
		tier .. " opaque floor overlays removed",
		selected.ringBedTransparency == 1 and selected.ringEyeTransparency == 1
	)
	check(tier .. " capture perimeter remains visible", selected.perimeter == true)
	check(
		tier .. " field ring defaults remain untouched",
		base.ringTransparency == nil and base.perimeter == nil
	)
	lastCore, lastShards = selected.core, selected.shards
	selected.core = 999
	check(
		tier .. " output mutation cannot change global original",
		base.core == 9.4 and base.shaft == 300 and base.light == 60 and base.shards == 8
	)
end
local first = Visual.select(base, "prime", true)
first.shards = 999
check("selected copies cannot corrupt next node", Visual.select(base, "prime", true).shards == 4)
check("unknown tier uses safe common presentation", Visual.select(base, "unknown", true).core == 2)
print(`Cascade node visuals: {passed} passed, {failed} failed`)
if failed > 0 then
	process.exit(1)
end
