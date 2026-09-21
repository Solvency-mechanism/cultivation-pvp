--!strict
-- Immutable collection/equipment rules. Roblox and persistence inject data.
local Treasures = {}
Treasures.Order = { "emberlung", "cascade_heart", "wind_chime", "iron_seed", "stillwater_pearl" }
Treasures.Catalog = {
	emberlung = {
		name = "Emberlung",
		rarity = "Legendary",
		description = "V replaces Vent with directed fire breath: 30 fire mana, 30-stud reach, 8-second cooldown.",
	},
	cascade_heart = {
		name = "Heart of the Cascade",
		rarity = "Legendary",
		description = "Cultivate motionless on the ground for 10 seconds. Your next Swiftstep or Cinder Step heals you and same-team allies within 12 studs and clear sight for 20% maximum health. Walking or damage clears all charge.",
	},
	wind_chime = {
		name = "Wind Chime",
		rarity = "Uncommon",
		description = "+8% movement speed.",
		stat = "speed",
		amount = 0.08,
	},
	iron_seed = {
		name = "Iron Seed",
		rarity = "Uncommon",
		description = "+8% strength.",
		stat = "strength",
		amount = 0.08,
	},
	stillwater_pearl = {
		name = "Stillwater Pearl",
		rarity = "Uncommon",
		description = "+8% cultivation.",
		stat = "cultivation",
		amount = 0.08,
	},
}
export type Collection = { owned: { [string]: boolean }, equipped: { string } }
function Treasures.sanitize(raw: any): Collection
	local result: Collection = { owned = {}, equipped = { "", "", "" } }
	if type(raw) ~= "table" then
		return result
	end
	if type(raw.owned) == "table" then
		for _, id in Treasures.Order do
			if raw.owned[id] == true then
				result.owned[id] = true
			end
		end
	end
	local seen = {}
	if type(raw.equipped) == "table" then
		for slot = 1, 3 do
			local id = raw.equipped[slot]
			if type(id) == "string" and result.owned[id] and not seen[id] then
				result.equipped[slot] = id
				seen[id] = true
			end
		end
	end
	return result
end
function Treasures.has(raw: any, id: string): boolean
	return table.find(Treasures.sanitize(raw).equipped, id) ~= nil
end
function Treasures.grant(raw: any, id: string): (Collection, boolean)
	local result = Treasures.sanitize(raw)
	if not Treasures.Catalog[id] or result.owned[id] then
		return result, false
	end
	result.owned[id] = true
	return result, true
end
function Treasures.equip(raw: any, id: string, slot: number): (Collection, boolean)
	local result = Treasures.sanitize(raw)
	if slot ~= math.floor(slot) or slot < 1 or slot > 3 then
		return result, false
	end
	if id ~= "" and not result.owned[id] then
		return result, false
	end
	for index = 1, 3 do
		if result.equipped[index] == id and id ~= "" then
			result.equipped[index] = ""
		end
	end
	result.equipped[slot] = id
	return result, true
end
function Treasures.modifiers(raw: any): { [string]: number }
	local result: { [string]: number } = { speed = 0, strength = 0, cultivation = 0 }
	for _, id in Treasures.sanitize(raw).equipped do
		local item: any = Treasures.Catalog[id]
		if item and item.stat then
			result[item.stat] = math.min(0.2, result[item.stat] + item.amount)
		end
	end
	return result
end
return Treasures
