--!strict
-- Real authored builder under Lune: construction/metadata, not engine walking.
local rb = require("@lune/roblox")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local env: any = table.clone(rb)
local builder = luau.load(fs.readFile("src/server/TreasureWorld.luau"), { environment = env })()
local frame = rb.CFrame.new(251, 0, -145) * rb.CFrame.Angles(0, 0.4, 0)
local decor = rb.Instance.new("Folder")
local result = builder.build(decor, frame)
local expected = {
	emberlung = true,
	cascade_heart = true,
	wind_chime = true,
	iron_seed = true,
	stillwater_pearl = true,
}
local count, checks, parts = 0, 0, 0
local function check(ok, message)
	assert(ok, message)
	checks += 1
end
for _, item in result.root:GetDescendants() do
	check(not item:IsA("ProximityPrompt"), "world must not create a competing discovery authority")
	if item:IsA("BasePart") then
		parts += 1
		check(
			item.Anchored and not item.CanCollide and not item.CanQuery and not item.CanTouch,
			"relic decoration must preserve collision and query routes: " .. item.Name
		)
		if item:GetAttribute("TreasureDiscovery") then
			local id = item:GetAttribute("TreasureId")
			check(expected[id] == true, "unknown or duplicate discovery")
			expected[id] = false
			count += 1
			check(typeof(item:GetAttribute("TreasureFloor")) == "Vector3", "floor metadata")
			check(#item:GetAttribute("TreasureHint") > 10, "authored clue")
			check(
				(item.CFrame.Position - item:GetAttribute("TreasureFloor")).Magnitude < 2,
				"discovery remains reachable above its documented floor"
			)
		end
	end
end
check(count == 5, "exactly five fixed discoveries")
check(parts < 65, "bounded discovery art budget")
check(
	(frame:PointToObjectSpace(result.emberlung.CFrame.Position) - rb.Vector3.new(-19, 2.6, 25)).Magnitude
		< 0.001,
	"Emberlung uses supplied cave frame, inside visitor floor before z29 boundary"
)
check(
	math.abs(result.cascadeHeart.CFrame.Position.Y - 36.6) < 0.001
		and result.cascadeHeart.CFrame.Position.Z < 213,
	"Heart stays in tier6 ahead of solid upper riser"
)
check(
	result.cascadeHeart:GetAttribute("TreasureHint"):find("beside the highest fall") ~= nil,
	"clue never promises nonexistent walk-behind space"
)
print(
	"Treasure world: "
		.. checks
		.. " checks; "
		.. parts
		.. " static parts. Not engine traversal acceptance."
)
