--!strict
-- Authored discovery routes around Worldcraft's existing hollow volcano.
-- No runtime connections: VolcanoService owns interactions and breathing.
local Worldcraft = require(script.Parent.Worldcraft)

local VolcanoWorld = {}
local STONE = Color3.fromRGB(53, 43, 46)
local ASH = Color3.fromRGB(114, 101, 94)
local EMBER = Color3.fromRGB(255, 127, 47)
local GOLD = Color3.fromRGB(243, 204, 128)
local COOL = Color3.fromRGB(142, 209, 210)

function VolcanoWorld.build(kit: Worldcraft.Kit, centre: Vector3)
	local root = Instance.new("Folder")
	root.Name = "VolcanoExperience"
	root:SetAttribute("Centre", centre)
	root.Parent = kit.decor
	local ground = Instance.new("Folder")
	ground.Name = "VolcanoWalkable"
	ground.Parent = kit.ground
	local ownKit = { rngFor = kit.rngFor, decor = root, ground = ground }
	local mouth = Worldcraft.volcanoMouth(centre)
	local outward = Vector3.new(math.cos(mouth), 0, math.sin(mouth))
	local frame = CFrame.lookAt(centre, centre + outward)
	Worldcraft.buildVolcano(ownKit, centre, mouth)

	local function block(
		name: string,
		size: Vector3,
		cf: CFrame,
		color: Color3,
		walkable: boolean
	): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored = true
		p.Size = size
		p.CFrame = frame * cf
		p.Color = color
		p.Material = if walkable then Enum.Material.Slate else Enum.Material.Basalt
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.CanCollide = walkable
		p.Parent = if walkable then ground else root
		return p
	end
	local function glow(name: string, at: Vector3, size: Vector3, color: Color3): Part
		local p = block(name, size, CFrame.new(at), color, false)
		p.Material = Enum.Material.Neon
		p.CastShadow = false
		p:SetAttribute("VolcanoBreath", true)
		return p
	end
	local function lamp(p: Part, range: number, brightness: number)
		local light = Instance.new("PointLight")
		light.Color = p.Color
		light.Range = range
		light.Brightness = brightness
		light.Shadows = false
		light.Parent = p
	end
	local function inscription(name: string, at: Vector3, words: string, color: Color3)
		local stone = block(name, Vector3.new(7, 4, 1), CFrame.new(at), STONE, false)
		local gui = Instance.new("BillboardGui")
		gui.Size = UDim2.fromOffset(230, 72)
		gui.StudsOffset = Vector3.new(0, 3, 0)
		gui.MaxDistance = 32
		gui.AlwaysOnTop = false
		gui.Parent = stone
		local text = Instance.new("TextLabel")
		text.Size = UDim2.fromScale(1, 1)
		text.BackgroundTransparency = 1
		text.Text = words
		text.TextColor3 = color
		text.TextStrokeTransparency = 0.25
		text.TextWrapped = true
		text.TextSize = 15
		text.Font = Enum.Font.Garamond
		text.Parent = gui
	end
	local function action(name: string, id: string, at: Vector3, color: Color3): Part
		block(
			name .. "Plinth",
			Vector3.new(5, 1, 5),
			CFrame.new(at - Vector3.new(0, 1.3, 0)),
			STONE,
			false
		)
		local p = glow(name, at, Vector3.new(2.8, 1.8, 2.8), color)
		p:SetAttribute("VolcanoAction", id)
		lamp(p, 13, 0.7)
		return p
	end
	local function bridge(name: string, a: Vector3, b: Vector3, width: number)
		block(
			name,
			Vector3.new(width, 1.4, (b - a).Magnitude + 1),
			CFrame.lookAt((a + b) / 2, b),
			ASH,
			true
		)
	end

	-- Safe approach / sanctuary. All added paths have real floor under them.
	bridge("AshPilgrimRoad", Vector3.new(0, 0.8, -105), Vector3.new(0, 0.8, -63), 16)
	block("DragonSanctuary", Vector3.new(47, 2, 39), CFrame.new(0, 1, -1), STONE, true)
	bridge("SanctuaryEntry", Vector3.new(0, 1.1, -32), Vector3.new(0, 1.1, -15), 20)
	for side = -1, 1, 2 do
		for index = 1, 5 do
			local z = -98 + index * 9
			block(
				"PilgrimMarker",
				Vector3.new(2, 3 + index % 2, 2),
				CFrame.new(side * 11, 1.5, z) * CFrame.Angles(0, index, 0),
				ASH,
				false
			)
			glow("RoadEmber", Vector3.new(side * 11, 3.4, z), Vector3.new(0.8, 0.4, 0.8), EMBER)
		end
	end
	inscription(
		"Threshold",
		Vector3.new(-10, 4, -78),
		"THE SLEEPING FURNACE\nListen. The mountain breathes.",
		GOLD
	)
	local brazier = action("EmberBrazier", "light_brazier", Vector3.new(7, 3.5, -43), ASH)
	brazier:SetAttribute("VolcanoCultivationRate", 6)
	brazier:SetAttribute("VolcanoCultivationRadius", 14)
	-- A sealed alcove beside the bowl: lighting exposes an actual small space.
	block("BrazierRecessFloor", Vector3.new(10, 1.4, 10), CFrame.new(17, 1, -43), STONE, true)
	block("BrazierRecessBack", Vector3.new(2, 9, 12), CFrame.new(23, 4.5, -43), STONE, false)
	for side = -1, 1, 2 do
		block(
			"BrazierRecessSide",
			Vector3.new(12, 9, 2),
			CFrame.new(17, 4.5, -43 + side * 6),
			STONE,
			false
		)
	end
	local seal = block("AshSeal", Vector3.new(1, 7, 10), CFrame.new(11.6, 4.7, -43), ASH, false)
	seal.CanCollide = true
	seal:SetAttribute("VolcanoAshSeal", true)
	local relic = glow("BrazierRelic", Vector3.new(18, 3, -43), Vector3.new(2, 2, 2), GOLD)
	relic:SetAttribute("VolcanoRecessRelic", true)
	inscription(
		"RecessCarving",
		Vector3.new(21, 4, -43),
		"Three embers answer the breath.\nSeek the forgotten bed beyond the right-hand ribs.",
		GOLD
	)
	inscription(
		"BrazierClue",
		Vector3.new(-8, 3, -43),
		"Give the cold bowl a little fire.\nA small breath is enough.",
		GOLD
	)
	-- Keep every original dragon part intact. A light-tight black chamber,
	-- rather than stone across its face, conceals the space around the creature.
	for _, item in root:GetChildren() do
		if item:IsA("Model") and item:GetAttribute("Vendor") == "dragon" then
			for _, p in item:GetDescendants() do
				if p:IsA("BasePart") then
					p.CFrame = p.CFrame + frame:VectorToWorldSpace(Vector3.new(0, 0, 28))
				elseif p:IsA("PointLight") then
					p.Brightness = 0.3
					p.Range = 12
					p.Shadows = true
				end
			end
		elseif item:IsA("BasePart") then
			local at = frame:PointToObjectSpace(item.CFrame.Position)
			if
				(
					string.find(item.Name, "VolcanoFacet")
					and at.Z > 20
					and math.abs(at.X) < 44
					and at.Y < 65
				)
				or string.find(item.Name, "DragonPool")
				or string.find(item.Name, "LavaFall")
			then
				item:Destroy()
			end
		end
	end
	-- Existing exterior rivers and climb dressing must not shine through the pocket.
	for _, p in root:GetChildren() do
		if p:IsA("BasePart") then
			local at = frame:PointToObjectSpace(p.CFrame.Position)
			if at.Z > 20 and math.abs(at.X) < 35 and at.Y < 62 then
				p.Color = Color3.new(0, 0, 0)
				p.Material = Enum.Material.Neon
				for _, light in p:GetChildren() do
					if light:IsA("Light") then
						light:Destroy()
					end
				end
			end
		end
	end
	for _, p in ground:GetChildren() do
		if p:IsA("BasePart") then
			local at = frame:PointToObjectSpace(p.CFrame.Position)
			if at.Z > 32 and math.abs(at.X) < 35 and at.Y < 62 then
				p.Color = Color3.new(0, 0, 0)
				p.Material = Enum.Material.Neon
			end
		end
	end
	local function darkness(name: string, size: Vector3, at: Vector3)
		local p = block(name, size, CFrame.new(at), Color3.new(0, 0, 0), false)
		-- Zero-radiance black avoids ambient lighting revealing the box walls.
		p.Material = Enum.Material.Neon
		p.CanCollide = true
		p.CastShadow = true
		return p
	end
	darkness("DragonCaveBack", Vector3.new(96, 120, 6), Vector3.new(0, 5, 134))
	darkness("DragonCaveRoof", Vector3.new(96, 6, 118), Vector3.new(0, 65, 78))
	darkness("DragonCaveBottom", Vector3.new(96, 6, 118), Vector3.new(0, -55, 78))
	for side = -1, 1, 2 do
		darkness("DragonCaveWall", Vector3.new(6, 120, 106), Vector3.new(side * 26, 5, 85))
		darkness("DragonCaveLightSeal", Vector3.new(24, 120, 6), Vector3.new(side * 35, 5, 32))
		-- The exterior rock joins the volcano wall around the opening only.
		block(
			"DragonCaveShoulder",
			Vector3.new(13, 62, 12),
			CFrame.new(side * 36, 29, 12),
			STONE,
			false
		)
		block(
			"DragonCaveBrow",
			Vector3.new(43, 13, 14),
			CFrame.new(side * 20, 61, 14) * CFrame.Angles(0, 0, side * 0.08),
			STONE,
			false
		)
		for i = 0, 2 do
			block(
				"DragonCaveRim",
				Vector3.new(8, 18, 9),
				CFrame.new(side * (30 + i % 2), 9 + i * 17, 13)
					* CFrame.Angles(0, side * 0.15, side * 0.12),
				STONE,
				false
			)
		end
	end
	local caveFloor = block(
		"DragonCaveFloor",
		Vector3.new(62, 2, 100),
		CFrame.new(0, 1, 69),
		Color3.new(0, 0, 0),
		true
	)
	caveFloor.Material = Enum.Material.Neon
	bridge("DragonAudiencePath", Vector3.new(0, 1, 14), Vector3.new(0, 1, 29), 16)
	action("DragonOffer", "dragon", Vector3.new(0, 4, 12), GOLD)
	local forge = action("ForgeAnvil", "forge", Vector3.new(-13, 4, 4), EMBER)
	forge:SetAttribute("VolcanoCultivationRate", 8)
	forge:SetAttribute("VolcanoCultivationRadius", 18)
	action("PurifyFont", "purify", Vector3.new(14, 4, -4), COOL)
	inscription(
		"ForgeWords",
		Vector3.new(-16, 4, 9),
		"SOLID FIRE\nWhat you cannot use, another may treasure.",
		EMBER
	)
	inscription(
		"FontWords",
		Vector3.new(18, 4, 1),
		"QUIET EMBERS\nA little pure mana remains when fire is surrendered.",
		COOL
	)
	for i = 1, 7 do
		glow("SanctuaryInlay", Vector3.new(-21 + i * 5, 2.04, -17), Vector3.new(2, 0.07, 0.4), GOLD)
	end

	-- A side passage with a genuine opening in the shell, joining the outdoors.
	-- Local +X is bearing mouth+pi/2; remove only intersecting low shell facets.
	for _, p in root:GetChildren() do
		if p:IsA("BasePart") and string.find(p.Name, "VolcanoFacet") then
			local at = frame:PointToObjectSpace(p.Position)
			if at.X > 45 and math.abs(at.Z) < 19 and at.Y < 27 then
				p:Destroy()
			end
		end
	end
	bridge("FissureFloor", Vector3.new(20, 1.2, -10), Vector3.new(88, 1.2, -10), 10)
	for i = 1, 7 do
		local x = 28 + i * 7
		for side = -1, 1, 2 do
			block(
				"FissureRib",
				Vector3.new(3, 11 + i % 3, 3),
				CFrame.new(x, 5, -10 + side * 7) * CFrame.Angles(0, 0, side * 0.12),
				STONE,
				false
			)
		end
		glow("FissureThread", Vector3.new(x, 2, -14.8), Vector3.new(4, 0.12, 0.3), EMBER)
	end
	block("FissureLintel", Vector3.new(19, 4, 18), CFrame.new(70, 13, -10), STONE, false)
	action("FissureCache", "fissure", Vector3.new(58, 3.7, -10), GOLD)
	inscription("FissureWarning", Vector3.new(87, 3, -15), "A warm draft rises from below.", GOLD)

	-- The observation secret is tucked behind staggered ribs, not a locked wall.
	bridge("RefugePathA", Vector3.new(19, 1.2, 10), Vector3.new(32, 1.2, 10), 8)
	bridge("RefugePathB", Vector3.new(32, 1.2, 10), Vector3.new(37, 1.2, 23), 8)
	block("RefugeFloor", Vector3.new(15, 1.4, 15), CFrame.new(37, 1.2, 24), ASH, true)
	block("RefugeBackWall", Vector3.new(18, 11, 2), CFrame.new(37, 6, 32), STONE, false)
	block("RefugeSideWall", Vector3.new(2, 11, 16), CFrame.new(45, 6, 24), STONE, false)
	block("RefugeRoof", Vector3.new(18, 2, 17), CFrame.new(37, 12, 24), STONE, false)
	for i = 1, 3 do
		block("RefugeScreen", Vector3.new(3, 11, 6), CFrame.new(26, 5, 10 + i * 5), STONE, false)
		local clue = glow(
			"BreathGlyph" .. i,
			Vector3.new(24.3, 5, 10 + i * 5),
			Vector3.new(0.12, 1.8, 1.8),
			GOLD
		)
		clue:SetAttribute("VolcanoClue", true)
	end
	action("RefugeCache", "refuge", Vector3.new(38, 3.8, 25), GOLD)
	block(
		"AbandonedBedroll",
		Vector3.new(3, 0.3, 6),
		CFrame.new(34, 2.05, 26),
		Color3.fromRGB(110, 83, 67),
		false
	)
	inscription(
		"RefugeJournal",
		Vector3.new(41, 4, 28),
		"When the mountain exhales,\nthree embers remember the way.",
		GOLD
	)

	-- Trial: linked ascending terraces, never requiring the reward to finish.
	action("TrialStart", "trial_start", Vector3.new(-24, 3.8, -7), EMBER)
	local previous = Vector3.new(-24, 1.2, -7)
	for i = 1, 10 do
		local at = Vector3.new(-29 - math.sin(i / 10 * math.pi) * 10, 1.2 + i * 1.4, -7 + i * 2.8)
		bridge("TrialTread" .. i, previous, at, 8)
		glow("TrialGuide" .. i, at + Vector3.new(-3.4, 1, 0), Vector3.new(0.5, 0.5, 0.5), EMBER)
		previous = at
	end
	block("TrialLanding", Vector3.new(12, 1.4, 11), CFrame.new(previous), STONE, true)
	action("TrialFinish", "trial_finish", previous + Vector3.new(0, 2.5, 0), GOLD)
	inscription(
		"TrialWords",
		Vector3.new(-23, 4, -12),
		"THE CINDER PATH\nCarry your fire. Follow the embers upward.",
		GOLD
	)
	-- Optional 15-stud edge gap along the chamber side, clear of dragon skull.
	block(
		"CinderShortcutLanding",
		Vector3.new(10, 1.4, 11),
		CFrame.new(-29, previous.Y, -5),
		STONE,
		true
	)
	bridge("ShortcutDescent", Vector3.new(-29, previous.Y, -5), Vector3.new(-16, 1.2, -14), 7)
	inscription(
		"ShortcutHint",
		previous + Vector3.new(0, 3, 5),
		"A directed ember crosses\nwhere footsteps cannot.",
		GOLD
	)

	-- Rich crater source on dry ground outside the existing central lava pool.
	local crater = action("CraterSource", "gather", Vector3.new(16, 90.5, 0), EMBER)
	crater:SetAttribute("VolcanoCultivationRate", 18)
	crater:SetAttribute("VolcanoCultivationRadius", 12)
	-- Optional dangerous west rim. East source/stair routes remain safe.
	for side = -1, 1, 2 do
		local at = Vector3.new(-16, 88.15, side * 9)
		local hazard = glow("ThermalVent", at, Vector3.new(6, 0.25, 6), EMBER)
		hazard:SetAttribute("VolcanoHazard", true)
		for edge = -1, 1, 2 do
			glow(
				"VentWarningRim",
				at + Vector3.new(edge * 3.7, 0, 0),
				Vector3.new(0.4, 0.3, 7.8),
				GOLD
			)
			glow(
				"VentWarningRim",
				at + Vector3.new(0, 0, edge * 3.7),
				Vector3.new(7.8, 0.3, 0.4),
				GOLD
			)
		end
	end
	inscription(
		"ThermalWarning",
		Vector3.new(-16, 91, 0),
		"THE WEST RIM EXHALES\nBright borders warn of rising heat.\nKeep east for safe passage.",
		GOLD
	)
	inscription(
		"CraterWords",
		Vector3.new(15, 91, 5),
		"THE OPEN FURNACE\nRich fire rises on the dragon's breath.",
		GOLD
	)
	for i = 1, 6 do
		local angle = i / 6 * math.pi * 2
		glow(
			"CraterVent",
			Vector3.new(math.cos(angle) * 20, 88.1, math.sin(angle) * 20),
			Vector3.new(1.2, 0.2, 2.4),
			EMBER
		)
	end

	for _, item in root:GetDescendants() do
		if item:IsA("ProximityPrompt") then
			item:Destroy() -- The service is the sole interaction owner.
		elseif item:IsA("Model") and item:GetAttribute("Vendor") == "dragon" then
			item:SetAttribute("VolcanoDragon", true)
		elseif item:IsA("BasePart") then
			if
				string.find(item.Name, "Pool") and not string.find(item.Name, "Bed")
				or string.find(item.Name, "Lava")
				or string.find(item.Name, "River")
				or item.Name == "VolcanoCraterLake"
			then
				item:SetAttribute("VolcanoLava", true)
			end
			if
				item.Name == "Jaw"
				or item.Name == "Tongue"
				or string.match(item.Name, "^ToothD")
			then
				item:SetAttribute("VolcanoJaw", true)
			end
			if item.Name == "EyeL" or item.Name == "EyeR" then
				item:SetAttribute("VolcanoEye", true)
			end
		end
	end
	return { centre = centre, root = root, ground = ground, frame = frame }
end

return VolcanoWorld
