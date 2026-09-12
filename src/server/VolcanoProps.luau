--!strict
-- Deterministic, non-colliding station dressing. Existing action Parts remain
-- the interaction and lighting owners; this module adds no remotes or lights.
local VolcanoProps = {}
local STONE = Color3.fromRGB(65, 62, 61)
local WORN = Color3.fromRGB(113, 103, 88)
local IRON = Color3.fromRGB(45, 46, 49)
local EDGE = Color3.fromRGB(130, 126, 119)
local EMBER = Color3.fromRGB(233, 107, 35)
local WATER = Color3.fromRGB(83, 140, 154)

function VolcanoProps.build(root: Folder, _ground: Folder)
	if root:FindFirstChild("AuthoredStations") then
		return
	end
	local props = Instance.new("Folder")
	props.Name = "AuthoredStations"
	props.Parent = root
	local markers: { [string]: BasePart } = {}
	for _, object in root:GetDescendants() do
		if object:IsA("BasePart") then
			local action = object:GetAttribute("VolcanoAction")
			if typeof(action) == "string" then
				markers[action] = object
			end
		end
	end
	local function part(
		parent: Instance,
		name: string,
		frame: CFrame,
		size: Vector3,
		color: Color3,
		material: Enum.Material,
		wedge: boolean?
	): BasePart
		local object: BasePart = if wedge then Instance.new("WedgePart") else Instance.new("Part")
		object.Name = name
		object.Anchored = true
		object.CanCollide = false
		object.CanTouch = false
		object.CanQuery = false
		object.Size = size
		object.CFrame = frame
		object.Color = color
		object.Material = material
		object.TopSurface = Enum.SurfaceType.Smooth
		object.BottomSurface = Enum.SurfaceType.Smooth
		object.Parent = parent
		return object
	end
	local function model(name: string): Model
		local object = Instance.new("Model")
		object.Name = name
		object.Parent = props
		return object
	end
	local function rim(
		parent: Instance,
		frame: CFrame,
		radius: number,
		y: number,
		count: number,
		color: Color3,
		material: Enum.Material
	)
		for index = 1, count do
			local angle = index / count * math.pi * 2
			part(
				parent,
				"Rim" .. index,
				frame
					* CFrame.new(math.cos(angle) * radius, y, math.sin(angle) * radius)
					* CFrame.Angles(0, -angle, 0),
				Vector3.new(0.55, 0.65, 2 * radius * math.sin(math.pi / count) + 0.1),
				color,
				material
			)
		end
	end
	local function prepare(marker: BasePart)
		-- Client breathing otherwise makes hidden generic cubes reappear.
		marker:SetAttribute("VolcanoBreath", nil)
		marker.Transparency = 1
		marker.CanCollide = false
		local plinth = root:FindFirstChild(marker.Name .. "Plinth")
		if plinth and plinth:IsA("BasePart") then
			plinth.Material = Enum.Material.Slate
			plinth.Color = STONE
		end
		-- Two broad broken feet seat the tool into the ground, rather than
		-- balancing it on a perfectly square, apparently floating display cube.
		for side = -1, 1, 2 do
			part(
				props,
				"EmbeddedStationFoot",
				marker.CFrame * CFrame.new(side * 1.55, -1.9, 0) * CFrame.Angles(0, side * 0.12, 0),
				Vector3.new(1.5, 0.65, 4.3),
				STONE,
				Enum.Material.Slate,
				true
			)
		end
	end

	local forge = markers.forge
	if forge then
		prepare(forge)
		local station = model("PilgrimsAnvil")
		local f = forge.CFrame
		part(
			station,
			"AnvilFoot",
			f * CFrame.new(0, -1.0, 0),
			Vector3.new(3.2, 0.4, 2.7),
			IRON,
			Enum.Material.Metal
		)
		part(
			station,
			"AnvilWaist",
			f * CFrame.new(0, -0.4, 0),
			Vector3.new(1.5, 0.9, 1.7),
			IRON,
			Enum.Material.Metal
		)
		part(
			station,
			"AnvilFace",
			f * CFrame.new(0, 0.2, 0),
			Vector3.new(3.5, 0.45, 2.1),
			EDGE,
			Enum.Material.Metal
		)
		part(
			station,
			"AnvilHorn",
			f * CFrame.new(2.3, 0.04, 0) * CFrame.Angles(0, math.pi / 2, 0),
			Vector3.new(1.4, 0.65, 1.8),
			IRON,
			Enum.Material.Metal,
			true
		)
		part(
			station,
			"HardyHole",
			f * CFrame.new(-1.1, 0.435, 0.3),
			Vector3.new(0.35, 0.015, 0.35),
			Color3.fromRGB(18, 18, 20),
			Enum.Material.SmoothPlastic
		)
		part(
			station,
			"HammerHandle",
			f * CFrame.new(-0.4, 0.57, -0.3) * CFrame.Angles(0, 0.5, 0),
			Vector3.new(0.18, 0.18, 1.8),
			Color3.fromRGB(94, 62, 42),
			Enum.Material.Wood
		)
		part(
			station,
			"HammerHead",
			f * CFrame.new(-0.75, 0.63, -1.0) * CFrame.Angles(0, 0.5, 0),
			Vector3.new(0.8, 0.45, 0.5),
			IRON,
			Enum.Material.Metal
		)
		part(
			station,
			"CoolingIngot",
			f * CFrame.new(0.65, 0.54, 0.2),
			Vector3.new(0.9, 0.2, 0.45),
			EMBER,
			Enum.Material.Neon
		)
		for side = -1, 1, 2 do
			part(
				station,
				"AnvilStrap",
				f * CFrame.new(side * 1.2, -0.65, 0),
				Vector3.new(0.23, 0.9, 2.5),
				EDGE,
				Enum.Material.Metal
			)
		end
		for index = 1, 5 do
			part(
				station,
				"Slag" .. index,
				f
					* CFrame.new(-1.5 + index * 0.6, -0.86, 1.8 + index % 2 * 0.2)
					* CFrame.Angles(0.2, index * 1.7, 0.4),
				Vector3.new(0.35, 0.3, 0.4),
				if index == 3 then EMBER else IRON,
				if index == 3 then Enum.Material.Neon else Enum.Material.Basalt
			)
		end
	end

	local purify = markers.purify
	if purify then
		prepare(purify)
		local station = model("StillwaterBasin")
		local f = purify.CFrame
		part(
			station,
			"BasinFoot",
			f * CFrame.new(0, -1.0, 0),
			Vector3.new(3.8, 0.5, 3.8),
			STONE,
			Enum.Material.Slate
		)
		part(
			station,
			"BasinWell",
			f * CFrame.new(0, -0.45, 0),
			Vector3.new(3.65, 0.5, 3.65),
			Color3.fromRGB(32, 48, 52),
			Enum.Material.Slate
		)
		rim(station, f, 1.9, -0.05, 12, WORN, Enum.Material.Slate)
		local water = part(
			station,
			"StillWater",
			f * CFrame.new(0, -0.12, 0) * CFrame.Angles(0, 0, math.pi / 2),
			Vector3.new(0.08, 3.25, 3.25),
			WATER,
			Enum.Material.Glass
		)
		water.Transparency = 0.28
		if water:IsA("Part") then
			water.Shape = Enum.PartType.Cylinder
		end
		water.Reflectance = 0.15
		for index = 1, 3 do
			local ripple = part(
				station,
				"WaterGlimmer" .. index,
				f
					* CFrame.new(-0.8 + index * 0.35, -0.07, -0.5 + index * 0.35)
					* CFrame.Angles(0, 0.4, 0),
				Vector3.new(0.9 - index * 0.15, 0.015, 0.035),
				Color3.fromRGB(167, 210, 209),
				Enum.Material.SmoothPlastic
			)
			ripple.Transparency = 0.3
		end
		part(
			station,
			"PouringLip",
			f * CFrame.new(0, 0.0, -2.1),
			Vector3.new(0.65, 0.3, 0.7),
			WORN,
			Enum.Material.Slate
		)
		part(
			station,
			"OverflowChannel",
			f * CFrame.new(0, -0.6, -2.65),
			Vector3.new(0.5, 0.18, 1.4),
			STONE,
			Enum.Material.Slate,
			true
		)
	end

	local dragon = markers.dragon
	if dragon then
		prepare(dragon)
		local station = model("KeepersOfferingStone")
		local f = dragon.CFrame
		part(
			station,
			"OfferingBase",
			f * CFrame.new(0, -1.0, 0),
			Vector3.new(4.5, 0.6, 4.2),
			STONE,
			Enum.Material.Slate
		)
		part(
			station,
			"WornDais",
			f * CFrame.new(0, -0.45, 0),
			Vector3.new(3.8, 0.6, 3.5),
			WORN,
			Enum.Material.Slate
		)
		part(
			station,
			"OfferingRecess",
			f * CFrame.new(0, -0.135, 0),
			Vector3.new(2.8, 0.025, 2.5),
			Color3.fromRGB(46, 39, 34),
			Enum.Material.Basalt
		)
		for side = -1, 1, 2 do
			for index = 1, 3 do
				part(
					station,
					"CarvedNotch",
					f
						* CFrame.new(side * 1.72, -0.12, -0.9 + index * 0.45)
						* CFrame.Angles(0, side * 0.35, 0),
					Vector3.new(0.2, 0.035, 0.3),
					STONE,
					Enum.Material.Basalt
				)
			end
		end
		for index = 1, 3 do
			part(
				station,
				"OldOffering" .. index,
				f
					* CFrame.new((index - 2) * 0.55, 0.06, 0.1 + index % 2 * 0.3)
					* CFrame.Angles(0, index * 0.7, 0.15),
				Vector3.new(0.36, 0.3, 0.6),
				if index == 2 then EMBER else Color3.fromRGB(115, 71, 41),
				if index == 2 then Enum.Material.Neon else Enum.Material.Rock
			)
		end
	end

	local brazier = markers.light_brazier
	if brazier then
		prepare(brazier)
		local station = model("PilgrimsBrazier")
		local f = brazier.CFrame
		part(
			station,
			"BrazierStem",
			f * CFrame.new(0, -0.9, 0),
			Vector3.new(1.2, 1.1, 1.2),
			IRON,
			Enum.Material.CorrodedMetal
		)
		part(
			station,
			"BowlBottom",
			f * CFrame.new(0, -0.45, 0),
			Vector3.new(2.9, 0.3, 2.9),
			IRON,
			Enum.Material.CorrodedMetal
		)
		rim(station, f, 1.7, -0.1, 10, IRON, Enum.Material.CorrodedMetal)
		for index = 1, 4 do
			part(
				station,
				"ColdCharcoal" .. index,
				f
					* CFrame.new(-1.0 + index * 0.4, -0.22, (index % 2 - 0.5) * 0.7)
					* CFrame.Angles(0.1, index, 0.2),
				Vector3.new(0.65, 0.35, 0.5),
				Color3.fromRGB(33, 29, 29),
				Enum.Material.Basalt
			)
		end
		-- The live action marker becomes the coal bed. The service's existing
		-- colour/material change and single light now illuminate a real bowl.
		brazier.Size = Vector3.new(2.5, 0.12, 2.5)
		brazier.Color = Color3.fromRGB(66, 56, 51)
		brazier.Material = Enum.Material.Basalt
		brazier.Transparency = 0
	end
	-- Four approach lanterns near the mouth are housed in dark iron. Existing
	-- emissive parts remain the single visual/light owner; no extra lights.
	local lampIndex = 0
	for _, ember in root:GetChildren() do
		if ember:IsA("BasePart") and ember.Name == "RoadEmber" then
			lampIndex += 1
			if lampIndex % 5 == 4 or lampIndex % 5 == 0 then
				local f = ember.CFrame
				ember.Size = Vector3.new(0.48, 0.9, 0.48)
				part(
					props,
					"LanternFoot",
					f * CFrame.new(0, -0.57, 0),
					Vector3.new(1.15, 0.18, 1.15),
					IRON,
					Enum.Material.CorrodedMetal
				)
				part(
					props,
					"LanternCap",
					f * CFrame.new(0, 0.63, 0),
					Vector3.new(1.25, 0.25, 1.25),
					IRON,
					Enum.Material.CorrodedMetal,
					true
				)
				for side = -1, 1, 2 do
					part(
						props,
						"LanternGuard",
						f * CFrame.new(side * 0.48, 0.02, 0),
						Vector3.new(0.12, 1.18, 0.9),
						IRON,
						Enum.Material.Metal
					)
				end
			end
		end
	end
end

return VolcanoProps
