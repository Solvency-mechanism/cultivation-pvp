--!strict
local process = require("@lune/process")
local Treasures = require("../src/shared/Treasures")
local Progression = require("../src/shared/Progression")
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
local collection = Treasures.sanitize(nil)
check(
	"legacy collection has exactly three empty slots",
	#collection.equipped == 3 and collection.equipped[3] == ""
)
for _, id in Treasures.Order do
	local previous = collection
	local granted, fresh = Treasures.grant(collection, id)
	check(id .. " first discovery grants", fresh and granted.owned[id] == true)
	check(id .. " discovery does not mutate input", previous.owned[id] == nil)
	local repeated, again = Treasures.grant(granted, id)
	check(id .. " repeated discovery is idempotent", not again and repeated.owned[id] == true)
	collection = granted
	local equipped, equippedOk = Treasures.equip(collection, id, 3)
	check(
		id .. " can occupy sparse slot three",
		equippedOk and equipped.equipped[1] == "" and equipped.equipped[3] == id
	)
	local moved = Treasures.equip(equipped, id, 1)
	check(
		id .. " moving slots cannot duplicate",
		moved.equipped[1] == id and moved.equipped[3] == ""
	)
	local state = Progression.newState()
	state.treasures = equipped
	local restored = Progression.sanitizeState(Config, Progression.toStore(state))
	check(
		id .. " catalog whitelist round trips sparse slot",
		restored.treasures ~= nil
			and restored.treasures.owned[id] == true
			and restored.treasures.equipped[3] == id
	)
	local accrued = Progression.accrueAura(Config, restored, "ash", 10)
	local spent = Progression.spendAura(accrued, 1)
	local lost = Progression.applyLoss(Config, spent, 1)
	local processed = Progression.process(Config, accrued).state
	local advanced = Progression.addProgress(Config, accrued, 1).state
	for _, changed in { accrued, spent, lost, processed, advanced } do
		check(
			id .. " clone preserves isolated equipment",
			changed.treasures ~= nil
				and restored.treasures ~= nil
				and changed.treasures.equipped[3] == id
				and changed.treasures.equipped ~= restored.treasures.equipped
				and changed.treasures.owned ~= restored.treasures.owned
		)
	end
	check(
		id .. " ordinary progression retains collection",
		lost.treasures ~= nil and lost.treasures.equipped[3] == id
	)
	if lost.treasures then
		lost.treasures.owned[id] = nil
	end
	check(
		id .. " progression clone isolates ownership",
		restored.treasures ~= nil and restored.treasures.owned[id] == true
	)
end
for _, slot in { -1, 0, 4, 1.5, math.huge, 0 / 0 } do
	local _, ok = Treasures.equip(collection, "emberlung", slot)
	check("invalid slot rejected " .. tostring(slot), not ok)
end
local _, unowned = Treasures.equip(Treasures.sanitize(nil), "emberlung", 1)
check("unowned item cannot equip", not unowned)
local malformed = Treasures.sanitize({
	owned = { emberlung = true, invalid = true, iron_seed = 1 },
	equipped = { "emberlung", "emberlung", "invalid", "cascade_heart" },
})
check(
	"untrusted ownership filtered",
	malformed.owned.invalid == nil and malformed.owned.iron_seed == nil
)
check(
	"duplicate and unknown equipment filtered",
	malformed.equipped[1] == "emberlung"
		and malformed.equipped[2] == ""
		and malformed.equipped[3] == ""
)
local selected = Treasures.equip(collection, "wind_chime", 1)
selected = Treasures.equip(selected, "iron_seed", 2)
selected = Treasures.equip(selected, "stillwater_pearl", 3)
local mods = Treasures.modifiers(selected)
check(
	"three distinct modifiers apply",
	mods.speed == 0.08 and mods.strength == 0.08 and mods.cultivation == 0.08
)
local duplicates = Treasures.modifiers({
	owned = { wind_chime = true },
	equipped = { "wind_chime", "wind_chime", "wind_chime" },
})
check("corrupt duplicate cannot stack", duplicates.speed == 0.08)
local clear = Treasures.equip(selected, "", 2)
check(
	"unequip preserves slot positions",
	clear.equipped[1] == "wind_chime"
		and clear.equipped[2] == ""
		and clear.equipped[3] == "stillwater_pearl"
)
check("unequipped modifiers removed", Treasures.modifiers(clear).strength == 0)
print(`Treasures: {passed} passed, {failed} failed`)
if failed > 0 then
	process.exit(1)
end
