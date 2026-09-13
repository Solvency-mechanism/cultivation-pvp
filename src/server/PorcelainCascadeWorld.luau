--!strict
-- Mineral water builds broad, offset scalloped shelves. Geometry only: existing
-- Wellspring/Lumen gameplay remains authoritative; no new resource economy.
local Cascade = {}
export type Kit = { decor: Folder, ground: Folder, rngFor: (string) -> Random }
local IVORY = Color3.fromRGB(224, 219, 198)
local CHALK = Color3.fromRGB(245, 239, 216)
local SEDIMENT = Color3.fromRGB(174, 173, 153)
local WATER = Color3.fromRGB(56, 167, 165)
local DEEP = Color3.fromRGB(39, 126, 133)
local FOAM = Color3.fromRGB(199, 239, 221)

function Cascade.build(kit: Kit, centre: Vector3?)
	local origin = centre or Vector3.new(0, 0, 172)
	local root = Instance.new("Folder")
	root.Name = "PorcelainCascade"
	root:SetAttribute("Centre", origin)
	root:SetAttribute("AuraIdentity", "wellspring")
	local ground = Instance.new("Folder")
	ground.Name = "PorcelainWalkable"
	ground.Parent = kit.ground
	local rng = kit.rngFor("Porcelain mineral strata")
	local shift = origin - Vector3.new(0, 0, 172)
	local function position(v: Vector3): Vector3
		return v + shift
	end
	local function stone(
		name: string,
		size: Vector3,
		cf: CFrame,
		color: Color3,
		walkable: boolean
	): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = CFrame.new(shift) * cf
		p.Color = color
		p.Material = Enum.Material.Limestone
		p.Anchored = true
		p.CanCollide = walkable
		p.CanQuery = walkable
		p.CanTouch = false
		p.CastShadow = walkable
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p:SetAttribute(if walkable then "CascadeWalkable" else "CascadeDressing", true)
		p.Parent = if walkable then ground else root
		return p
	end
	local function disc(
		name: string,
		radius: number,
		height: number,
		at: Vector3,
		color: Color3,
		walkable: boolean
	): Part
		local p = stone(
			name,
			Vector3.new(height, radius * 2, radius * 2),
			CFrame.new(at) * CFrame.Angles(0, 0, math.pi / 2),
			color,
			walkable
		)
		p.Shape = Enum.PartType.Cylinder
		return p
	end
	local function water(name: string, size: Vector3, cf: CFrame, color: Color3): Part
		local p = stone(name, size, cf, color, false)
		p.Material = Enum.Material.SmoothPlastic
		p.CastShadow = false
		p:SetAttribute("CascadeWater", true)
		p.Transparency = 0
		return p
	end
	-- Ellipsoids overlap as continuous deposited lobes, not isolated rocks.
	local function lobe(name: string, size: Vector3, cf: CFrame, color: Color3): Part
		local p = stone(name, size, cf, color, false)
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = p
		p:SetAttribute("CascadeEllipsoid", true)
		p.Material = Enum.Material.SmoothPlastic
		return p
	end
	local function ramp(name: string, a: Vector3, b: Vector3, width: number)
		local p = stone(
			name,
			Vector3.new(width, 1.2, (b - a).Magnitude + 0.8),
			CFrame.lookAt((a + b) / 2, b),
			IVORY,
			true
		)
		p:SetAttribute("CascadeBank", true)
		-- Deposited mineral supports each bank down to the original ground.
		-- A visible sloping wedge, not a floating strip or invisible collider.
		local low, high = if a.Y <= b.Y then a else b, if a.Y <= b.Y then b else a
		local horizontal = Vector3.new(high.X - low.X, 0, high.Z - low.Z)
		local midpoint = (a + b) / 2
		local facing =
			CFrame.lookAt(Vector3.new(midpoint.X, 0, midpoint.Z), Vector3.new(low.X, 0, low.Z))
		stone(
			name .. "DepositFoot",
			Vector3.new(width, math.max(0.2, low.Y), horizontal.Magnitude),
			CFrame.new(midpoint.X, low.Y / 2 - 0.4, midpoint.Z) * facing.Rotation,
			SEDIMENT,
			false
		)
		if high.Y - low.Y > 0.1 then
			local slope = Instance.new("WedgePart")
			slope.Name = name .. "DepositSlope"
			slope.Size = Vector3.new(width, high.Y - low.Y, horizontal.Magnitude)
			slope.CFrame = CFrame.new(
				position(Vector3.new(midpoint.X, (low.Y + high.Y) / 2 - 0.4, midpoint.Z))
			) * facing.Rotation
			slope.Color = IVORY
			slope.Material = Enum.Material.Limestone
			slope.Anchored = true
			slope.CanCollide = false
			slope.CanQuery = false
			slope.CanTouch = false
			slope:SetAttribute("CascadeDressing", true)
			slope.Parent = root
		end
		if name:find("Bank") then
			local side = if midpoint.X < 0 then -1 else 1
			for rib = 1, 2 do
				local at = a:Lerp(b, rib / 3)
				lobe(
					"BankMineralButtress",
					Vector3.new(
						width + 1.8,
						math.max(1, at.Y + 0.2),
						horizontal.Magnitude * 0.8 + 1
					),
					CFrame.new(at.X + side * 0.7, at.Y / 2 - 0.45, at.Z) * facing.Rotation,
					IVORY:Lerp(SEDIMENT, 0.15)
				)
			end
		end
		return p
	end
	local function marker(name: string, at: Vector3): Part
		local p = stone(name, Vector3.new(0.3, 0.3, 0.3), CFrame.new(at), CHALK, false)
		p.Transparency = 1
		p.CastShadow = false
		return p
	end
	-- x, bed height, z, breadth, depth. Alternating spill points make water
	-- wander between terraces instead of forming concentric wedding-cake rings.
	local terraces = {
		{ -3, 2, 130, 38, 20 },
		{ 7, 8, 146, 38, 14 },
		{ -6, 15, 162, 40, 16 },
		{ 6, 22, 178, 42, 16 },
		{ -5, 29, 192, 36, 14 },
		{ 4, 35, 206, 30, 14 },
		{ 0, 41, 219, 24, 12 },
	}
	local pools: { Vector3 } = {}
	for index, spec in terraces do
		local x, y, z, width, depth = spec[1], spec[2], spec[3], spec[4], spec[5]
		local foundation = stone(
			"TerraceFoundation" .. index,
			Vector3.new(width, y, depth),
			CFrame.new(x, y / 2, z),
			IVORY,
			true
		)
		foundation:SetAttribute("CascadeTier", index)
		foundation.Material = Enum.Material.SmoothPlastic
		stone(
			"MineralBed" .. index,
			Vector3.new(width, 0.65, depth),
			CFrame.new(x, y - 0.325, z),
			IVORY,
			true
		)
		local pool = water(
			"TerraceWater" .. index,
			Vector3.new(width - 4, 0.12, depth - 3),
			CFrame.new(x, y + 0.39, z),
			WATER:Lerp(DEEP, (index % 3) * 0.13)
		)
		pool:SetAttribute("CascadeWaterDepth", 0.45)
		pool:SetAttribute("CascadeTier", index)
		if index == 7 then
			pool:SetAttribute("CascadeMist", true)
		end
		local p = marker("PoolStanding" .. index, Vector3.new(x, y + 3, z))
		p:SetAttribute("CascadePool", true)
		p:SetAttribute("CascadeTier", index)
		table.insert(pools, position(Vector3.new(x, y + 3, z)))
		-- The visible escarpment is a continuous skirt of overlapping mineral
		-- curtains. Darker recessed lower lobes read as undercuts below pale lips.
		local front = z - depth / 2
		local rise = if index == 1 then y else y - terraces[index - 1][2]
		for rib = 1, 5 do
			local t = (rib - 1) / 4
			local sx = x - width / 2 + t * width
			local wave = math.sin(t * math.pi * 3 + index * 0.8)
			lobe(
				"MineralCurtain",
				Vector3.new(width / (2.65 + t * 0.2), rise * (1.04 + 0.05 * wave), 1.8),
				CFrame.new(sx, y - rise / 2 - 0.15, front + 0.3 + wave * 0.12),
				IVORY
			)
			for band = 1, 2 do
				lobe(
					"DepositedScallopBand",
					Vector3.new(width / 2.5, 0.30 + 0.12 * math.abs(wave), 2.1),
					CFrame.new(sx, y - 0.65 - band * rise / 3 + wave * 0.22, front + 0.08),
					if band == 1 then CHALK else IVORY:Lerp(SEDIMENT, 0.22)
				)
			end
		end
		for side = -1, 1, 2 do
			for rib = 1, 3 do
				lobe(
					"LateralMineralLobe",
					Vector3.new(1.8, rise + 0.1, depth / 1.25),
					CFrame.new(
						x + side * (width / 2 - 0.2),
						y - rise / 2 - 0.35,
						z - depth / 2 + rib * depth / 4
					),
					IVORY
				)
			end
		end
		-- Front shelf scallops share a continuous core. Two strata hide the
		-- rectangular foundation face and show deposited mineral thickness.
		local scallops = 7
		for scallop = 1, scallops do
			local sx = x - width / 2 + 2 + (scallop - 1) * (width - 4) / (scallops - 1)
			local bulge = 2.2 + 0.45 * math.sin(scallop * 1.7 + index)
			local sz = z - depth / 2 + 1.4
			disc("PorcelainScallop", bulge, 1.25, Vector3.new(sx, y - 0.1, sz), CHALK, true)
			disc(
				"OlderMineralStratum",
				bulge + 0.3,
				0.55,
				Vector3.new(sx, y - 1.05, sz + 0.1),
				IVORY,
				false
			)
			-- An imperfect outer lip is interrupted at each actual spillway.
			if scallop ~= 3 and scallop ~= 4 then
				stone(
					"ScallopLip",
					Vector3.new((width - 4) / 6 + 0.3, 0.6, 0.8),
					CFrame.new(sx, y + 0.78, sz - 0.8)
						* CFrame.Angles(0, 0.1 * math.sin(scallop), 0),
					CHALK,
					false
				)
			end
		end
		for side = -1, 1, 2 do
			stone(
				"DryBasinRim",
				Vector3.new(2.2, 0.75, depth + 0.5),
				CFrame.new(x + side * (width / 2 - 0.7), y + 0.375, z),
				CHALK,
				true
			)
			stone(
				"MineralVein",
				Vector3.new(0.22, 0.03, depth * 0.7),
				CFrame.new(x + side * (width / 2 - 0.3), y + 0.765, z),
				SEDIMENT,
				false
			)
		end
		stone(
			"BackBasinRim",
			Vector3.new(width, 0.7, 1.3),
			CFrame.new(x, y + 0.35, z + depth / 2 - 0.35),
			IVORY,
			true
		)
		-- Wet-edge growth is sparse and rooted locally, never random floor litter.
		for cluster = 1, 3 do
			local side = if cluster % 2 == 0 then 1 else -1
			local at = Vector3.new(
				x + side * (width / 2 - 1.0),
				y + 0.8,
				z - depth / 2 + cluster * (depth / 4)
			)
			disc("WetMineralRoot", 0.65, 0.22, at, Color3.fromRGB(99, 128, 92), false)
			for leaf = 1, 3 do
				local height = rng:NextNumber(0.8, 1.9)
				local plant = stone(
					"MarginSedge",
					Vector3.new(0.12, height * 1.4, 0.34),
					CFrame.new(at + Vector3.new((leaf - 2) * 0.3, height / 2, 0))
						* CFrame.Angles(0, leaf * 1.2, (leaf - 2) * 0.3),
					Color3.fromRGB(78, 121 + leaf * 8, 85),
					false
				)
				plant.Material = Enum.Material.SmoothPlastic
				local leafMesh = Instance.new("SpecialMesh")
				leafMesh.MeshType = Enum.MeshType.Sphere
				leafMesh.Parent = plant
				plant:SetAttribute("CascadeEllipsoid", true)
				plant.CastShadow = false
			end
		end
	end

	-- One continuous watercourse: broad descending sheets from each upper lip
	-- into the next pool, with narrow runoff fans marking every landing.
	for index = 2, #terraces do
		local upper, lower = terraces[index], terraces[index - 1]
		local spillX = math.clamp(
			(upper[1] + lower[1]) / 2,
			upper[1] - upper[4] / 2 + 4,
			upper[1] + upper[4] / 2 - 4
		)
		local a = Vector3.new(spillX, upper[2] + 0.43, upper[3] - upper[5] / 2 - 0.1)
		local b = Vector3.new(spillX, lower[2] + 0.45, lower[3] + lower[5] / 2 - 1)
		local run = a - b
		local cascade = water(
			"CascadeFall" .. index,
			Vector3.new(0.85, run.Magnitude, 0.18),
			CFrame.fromMatrix((a + b) / 2, Vector3.xAxis, run.Unit),
			FOAM
		)
		if index == 3 or index == 4 or index == 6 then
			cascade:SetAttribute("CascadeWaterfall", true)
		end
		local ribbon = water(
			"FallingTurquoiseRibbon",
			Vector3.new(0.27, run.Magnitude + 0.05, 0.06),
			cascade.CFrame - CFrame.new(shift).Position + Vector3.new(0, 0, -0.13),
			WATER
		)
		ribbon:SetAttribute("CascadeFlowDirection", Vector3.new(0, -1, -0.2))
		for strand = -2, 2 do
			if strand ~= 0 then
				for segment = 1, 2 do
					local t = (segment - 0.5) / 2
					local at = a:Lerp(b, t) + Vector3.new(strand * (0.72 + t * 0.28), 0, -0.12)
					water(
						"BrokenFallStrand",
						Vector3.new(0.26 + 0.12 * segment, run.Magnitude * 0.52, 0.13),
						CFrame.fromMatrix(at, Vector3.xAxis, run.Unit),
						if strand % 2 == 0 then FOAM else WATER:Lerp(FOAM, 0.45)
					)
				end
			end
		end
		for finger = -2, 2 do
			local foam = lobe(
				"RunoffFoamFinger",
				Vector3.new(0.7, 0.09, 2.0 + (2 - math.abs(finger)) * 0.7),
				CFrame.new(spillX + finger * 0.65, lower[2] + 0.49, b.Z - 0.7),
				FOAM
			)
			foam:SetAttribute("CascadeWater", true)
		end
	end

	local west = {
		Vector3.new(0, 0.7, 116),
		Vector3.new(-26, 2, 125),
		Vector3.new(-31, 7, 140),
		Vector3.new(-37, 14, 157),
		Vector3.new(-36, 21, 174),
		Vector3.new(-32, 28, 191),
		Vector3.new(-25, 35, 209),
		Vector3.new(-15, 41, 223),
		Vector3.new(0, 41, 225),
	}
	local routes: { [string]: { Vector3 } } = { west = {}, east = {} }
	for _, name in { "west", "east" } do
		local previous: Vector3? = nil
		for index, point in west do
			local at = Vector3.new(if name == "west" then point.X else -point.X, point.Y, point.Z)
			if previous then
				local half = (previous + at) / 2
				ramp(name .. "Bank" .. index .. "A", previous, half, 6.8)
				ramp(name .. "Bank" .. index .. "B", half, at, 6.8)
			end
			local check = marker(name .. "Checkpoint" .. index, at + Vector3.new(0, 3, 0))
			check:SetAttribute("CascadeRoute", name)
			check:SetAttribute("CascadeRouteIndex", index)
			check:SetAttribute("CascadeCheckpoint", true)
			table.insert(routes[name], position(at + Vector3.new(0, 3, 0)))
			previous = at
		end
		-- Each tier has a short, dry approach from the bank into its shallow rim.
		for index, spec in terraces do
			local z = spec[3]
			for segment = 2, #west do
				local a, b = west[segment - 1], west[segment]
				if z >= a.Z and z <= b.Z then
					local t = (z - a.Z) / (b.Z - a.Z)
					local bank = a:Lerp(b, t)
					if name == "east" then
						bank = Vector3.new(-bank.X, bank.Y, bank.Z)
					end
					local side = if name == "west" then -1 else 1
					ramp(
						name .. "PoolAccess" .. index,
						bank,
						Vector3.new(spec[1] + side * (spec[4] / 2 - 0.6), spec[2] + 0.7, z),
						4.2
					)
					break
				end
			end
		end
	end
	-- Open shaded alcove behind the fourth fall, approached from the west bank.
	-- It sits above lower pools but below the next terrace, with daylight exits.
	ramp("ShadedAlcoveApproach", Vector3.new(-36, 21, 174), Vector3.new(-25, 21, 174), 6)
	stone("AlcoveFloor", Vector3.new(10, 1.1, 10), CFrame.new(-25, 21, 174), IVORY, true)
	local roof =
		stone("MineralOverhang", Vector3.new(13, 2.5, 13), CFrame.new(-25, 28.0, 174), IVORY, false)
	roof.CanQuery = true
	roof:SetAttribute("CascadeNodeExclusion", true) -- placement rejects decor roofs; walking stays open
	-- A tributary from the fifth basin crosses the overhang and falls in front
	-- of the alcove. Both dry side entrances stay open behind the veil.
	local channelA, channelB = Vector3.new(-21.5, 29.45, 190), Vector3.new(-25, 29.3, 168.5)
	water(
		"VeilFeeder",
		Vector3.new(3.6, 0.13, (channelA - channelB).Magnitude),
		CFrame.lookAt((channelA + channelB) / 2, channelB),
		WATER
	)
	stone(
		"VeilMineralChannel",
		Vector3.new(5, 0.6, (channelA - channelB).Magnitude + 0.5),
		CFrame.lookAt(
			(channelA + channelB) / 2 - Vector3.new(0, 0.45, 0),
			channelB - Vector3.new(0, 0.45, 0)
		),
		IVORY,
		false
	)
	local veil =
		water("AlcoveWaterVeil", Vector3.new(0.85, 7.7, 0.16), CFrame.new(-25, 25.45, 168.5), FOAM)
	veil:SetAttribute("CascadeWaterfall", true)
	for strand = -3, 3 do
		if strand ~= 0 then
			water(
				"AlcoveVeilThread",
				Vector3.new(0.22 + (strand % 2) * 0.12, 7.7, 0.12),
				CFrame.new(-25 + strand * 0.65, 25.45, 168.5 + math.abs(strand) * 0.06),
				FOAM
			)
		end
	end
	for rib = 1, 9 do
		local x = -31 + (rib - 1) * 1.5
		lobe(
			"AlcovePorcelainLip",
			Vector3.new(2.5, 1.5, 3.2),
			CFrame.new(x, 28.2, 167.9 + 0.3 * math.sin(rib)),
			CHALK
		)
		-- Short draperies never descend into the established 5.2-stud headroom.
		lobe("AlcoveDrapery", Vector3.new(0.45, 1.15, 0.7), CFrame.new(x, 27.6, 167.1), IVORY)
	end
	for side = -1, 1, 2 do
		stone(
			"OverhangColumn",
			Vector3.new(1.5, 6.8, 2),
			CFrame.new(-25 + side * 5.2, 24.6, 178),
			SEDIMENT,
			false
		)
	end
	local alcove = marker("ShadedAlcove", Vector3.new(-25, 24.6, 174))
	alcove:SetAttribute("CascadeAlcove", true)
	-- The source shell grows from a grounded rear escarpment, not from the
	-- air behind the upper basin. The compact core begins behind the visitor
	-- route (z225); overlapping wide strata soften its continuous support.
	stone(
		"SourceRearEscarpmentCore",
		Vector3.new(24, 41, 5),
		CFrame.new(0, 20.5, 229.5),
		SEDIMENT,
		false
	)
	for layer = 1, 6 do
		lobe(
			"SourceRearDepositedMass",
			Vector3.new(26, 8.5, 8.0),
			CFrame.new(0, 3.3 + (layer - 1) * 7, 229.8),
			IVORY:Lerp(SEDIMENT, 0.23 - layer * 0.025)
		)
	end
	-- An asymmetric shell grown around the warm spring: broad curved flutes
	-- lean together above a dark teal hollow, rather than a row of crystal spikes.
	local hood = {
		-- Broad leaning shoulders carry a joined curved roof, leaving an open
		-- spring aperture below. Five overlapping masses read as one shell.
		{ -8.2, 50.1, 231.0, 9.2, 19.5, 4.6, -0.25 },
		{ 8.0, 48.8, 231.0, 9.0, 17.5, 4.6, 0.27 },
		{ -5.4, 57.0, 230.3, 12.0, 9.0, 4.5, -0.28 },
		{ 2.6, 57.2, 230.0, 12.8, 8.4, 4.6, 0.15 },
		{ 7.0, 54.5, 230.5, 9.5, 8.5, 4.5, 0.45 },
	}
	for rib, form in hood do
		local cf = CFrame.new(form[1], form[2], form[3]) * CFrame.Angles(0.05, 0, form[7])
		local shell = lobe(
			if rib == 3 then "WellspringTip" else "SourceShellFlute",
			Vector3.new(form[4], form[5], form[6]),
			cf,
			CHALK:Lerp(IVORY, rib * 0.08)
		)
		shell:SetAttribute("CascadeSourceShell", true)
		-- Shallow wide fluting follows the hood's mass; no contrasting pickets.
		lobe(
			"SourceFlowGroove",
			Vector3.new(form[4] * 0.70, form[5] * 0.74, 0.25),
			cf * CFrame.new(0, 0, -form[6] * 0.48),
			IVORY
		)
	end
	for side = -1, 1, 2 do
		lobe(
			"SourceShellFoot",
			Vector3.new(9.2, 1.7, 5.2),
			CFrame.new(side * 8, 41.5, 230.5),
			IVORY
		)
	end
	for arch = 1, 5 do
		lobe(
			"SpringHollowFold",
			Vector3.new(5.8 - arch * 0.45, 1.0, 2.2),
			CFrame.new(-7.3, 42 + arch * 0.7, 230 - arch * 0.35),
			IVORY:Lerp(CHALK, arch / 5)
		)
	end
	local beacon = water(
		"wellspringBeacon",
		Vector3.new(2.6, 1.2, 3.0),
		CFrame.new(0, 43.2, 222.7),
		Color3.fromRGB(170, 226, 190)
	)
	beacon:SetAttribute("CascadeSource", true)
	root:SetAttribute("CascadeTierCount", #terraces)
	root.Parent = kit.decor -- all tags are complete before clients see the subtree
	return { root = root, ground = ground, routes = routes, pools = pools }
end

return Cascade
