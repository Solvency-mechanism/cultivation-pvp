--!strict
-- Fixed authored discoveries. TreasureService is the sole prompt/award owner.
local TreasureWorld = {}
local IVORY = Color3.fromRGB(224, 219, 198)
local BASALT = Color3.fromRGB(55, 44, 43)
local GOLD = Color3.fromRGB(207, 170, 92)

function TreasureWorld.build(decor: Folder, volcanoFrame: CFrame)
	local root = Instance.new("Folder")
	root.Name = "TreasureDiscoveries"
	local function part(
		name: string,
		size: Vector3,
		cf: CFrame,
		color: Color3,
		glow: boolean?
	): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = cf
		p.Color = color
		p.Material = if glow then Enum.Material.Neon else Enum.Material.SmoothPlastic
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p:SetAttribute("TreasureDressing", true)
		p.Parent = root
		return p
	end
	local function round(
		name: string,
		size: Vector3,
		cf: CFrame,
		color: Color3,
		glow: boolean?
	): Part
		local p = part(name, size, cf, color, glow)
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = p
		return p
	end
	local function relic(id: string, cf: CFrame, color: Color3, hint: string, legendary: boolean)
		-- cf is the existing floor surface: no new collision or floating platform.
		round(
			id .. "PlinthFoot",
			Vector3.new(2.7, 0.35, 2.4),
			cf * CFrame.new(0, 0.12, 0),
			if id == "emberlung" or id == "iron_seed" then BASALT else IVORY
		)
		part(
			id .. "Plinth",
			Vector3.new(1.4, 0.75, 1.4),
			cf * CFrame.new(0, 0.5, 0),
			if id == "emberlung" or id == "iron_seed" then BASALT else IVORY
		)
		round(id .. "Bowl", Vector3.new(2.0, 0.32, 1.8), cf * CFrame.new(0, 0.93, 0), GOLD)
		local core =
			round(id, Vector3.new(0.65, 0.95, 0.65), cf * CFrame.new(0, 1.6, 0), color, true)
		core:SetAttribute("TreasureDiscovery", true)
		core:SetAttribute("TreasureId", id)
		core:SetAttribute("TreasureHint", hint)
		core:SetAttribute("TreasureLegendary", legendary)
		core:SetAttribute("TreasureFloor", cf.Position)
		if legendary then
			for side = -1, 1, 2 do
				round(
					id .. "RelicWing",
					Vector3.new(0.6, 1.2, 0.35),
					cf * CFrame.new(side * 0.48, 1.65, 0) * CFrame.Angles(0, 0, side * -0.28),
					color
				)
				part(
					id .. "ReliquaryCheek",
					Vector3.new(0.35, 2.8, 1.7),
					cf * CFrame.new(side * 1.4, 1.4, 0.35),
					if id == "emberlung" then BASALT else IVORY
				)
			end
			round(
				id .. "ReliquaryHood",
				Vector3.new(3.3, 0.65, 2.2),
				cf * CFrame.new(0, 2.9, 0.35),
				if id == "emberlung" then BASALT else IVORY
			)
		end
		return core
	end
	local ember = relic(
		"emberlung",
		volcanoFrame * CFrame.new(-19, 1, 25),
		Color3.fromRGB(222, 105, 43),
		"A warm seam beside the dragon's audience ledge.",
		true
	)
	-- A low broken basalt screen makes a pocket without modifying the cave.
	part(
		"EmberlungNookScreen",
		Vector3.new(0.7, 3.6, 4.3),
		volcanoFrame * CFrame.new(-21, 2.8, 25),
		BASALT
	)
	for index = 1, 4 do
		part(
			"EmberlungSeamClue",
			Vector3.new(0.17, 0.035, 0.65),
			volcanoFrame * CFrame.new(-13 - index * 1.2, 1.025, 20 + index * 0.9),
			GOLD
		)
	end
	local heart = relic(
		"cascade_heart",
		CFrame.new(5.5, 35, 211.6),
		Color3.fromRGB(81, 206, 186),
		"A pearl-white reliquary beside the highest fall.",
		true
	)
	for index = 1, 3 do
		round(
			"CascadeHeartPearlClue",
			Vector3.new(0.32, 0.12, 0.32),
			CFrame.new(8 - index * 0.6, 35.48, 208 + index * 0.8),
			GOLD
		)
	end
	relic(
		"wind_chime",
		CFrame.new(-21.3, 2.75, 130),
		Color3.fromRGB(149, 202, 198),
		"The dry western lip of the lowest porcelain pool.",
		false
	)
	relic(
		"iron_seed",
		volcanoFrame * CFrame.new(34, 1.9, 23),
		Color3.fromRGB(179, 144, 103),
		"A quiet corner of the volcano refuge.",
		false
	)
	relic(
		"stillwater_pearl",
		CFrame.new(-27, 21.55, 175),
		Color3.fromRGB(187, 220, 210),
		"In the shaded alcove behind the cascading veil.",
		false
	)
	root.Parent = decor -- all discovery metadata precedes replication
	return { root = root, emberlung = ember, cascadeHeart = heart }
end

return TreasureWorld
