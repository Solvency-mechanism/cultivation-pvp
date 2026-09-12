--!strict
-- A fitted light enclosure inside an authored basalt buttress. Owns replacement
-- shell and spiral geometry explicitly; never recolours unrelated nearby parts.
local VolcanoCave = {}
local BASALT = Color3.fromRGB(53, 43, 46)
local ROAD = Color3.fromRGB(108, 91, 78)

local function flank(h: number): number
	return 80 - 54 * (math.clamp(h / 100, 0, 1) ^ (2 / 3))
end

local function rearRadius(h: number): number
	if h <= 68 then
		return 78 - 12 * h / 68
	end
	return 66 + (flank(88) - 66) * math.clamp((h - 68) / 20, 0, 1)
end

local function shellRadius(h: number, angle: number): number
	local blend = math.clamp((math.cos(angle) - 0.15) / 0.55, 0, 1)
	return flank(h) + math.max(0, rearRadius(h) - flank(h)) * blend
end

function VolcanoCave.build(root: Folder, ground: Folder, frame: CFrame)
	local cave = Instance.new("Folder")
	cave.Name = "DragonCaveArchitecture"
	cave:SetAttribute("VolcanoCaveOwner", true)
	cave.Parent = root
	local envelope = Instance.new("Folder")
	envelope.Name = "BlackInterior"
	envelope.Parent = cave
	local rock = Instance.new("Folder")
	rock.Name = "BasaltEnvelope"
	rock.Parent = cave
	local function part(
		name: string,
		size: Vector3,
		cf: CFrame,
		color: Color3,
		parent: Instance,
		material: Enum.Material
	): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = frame * cf
		p.Color = color
		p.Material = material
		p.Anchored = true
		p.CanCollide = true
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p:SetAttribute("VolcanoCaveOwned", true)
		p.Parent = parent
		return p
	end
	local function black(name: string, size: Vector3, cf: CFrame, parent: Instance?): Part
		return part(name, size, cf, Color3.new(0, 0, 0), parent or envelope, Enum.Material.Neon)
	end
	-- Preserve the complete dragon as one rigid sculpture. Only its placement
	-- and the existing eye-light budget change relative to original Worldcraft.
	for _, item in root:GetChildren() do
		if item:IsA("Model") and item:GetAttribute("Vendor") == "dragon" then
			local head = item:FindFirstChild("Head") :: BasePart
			local anchor = frame:PointToObjectSpace(head.CFrame.Position)
			-- A rigid raised-chin pose sends the intact neck down into the
			-- mountain. Translation alone leaves its dorsal plates outside it.
			local pose = frame
				* CFrame.new(0, anchor.Y, 28)
				* CFrame.Angles(math.rad(12), 0, 0)
				* CFrame.new(-anchor)
				* frame:Inverse()
			for _, p in item:GetDescendants() do
				if p:IsA("BasePart") then
					p.CFrame = pose * p.CFrame
				elseif p:IsA("PointLight") then
					p.Brightness = 0.3
					p.Range = 12
					p.Shadows = true
				end
			end
		elseif item:IsA("BasePart") then
			local at = frame:PointToObjectSpace(item.CFrame.Position)
			-- The named rear shell is replaced by our fitted buttress. Original
			-- lava and ornaments intersecting that replacement are removed, not
			-- painted black, so no exterior route turns into an invisible floor.
			local rear = at.Z > 0 and at.Y < 88
			if
				(rear and (item.Name:match("^VolcanoFacet") or item.Name:match("^VolcanoRiver")))
				or item.Name:match("^VolcanoRampPost")
				or item.Name:match("^VolcanoRampFlame")
				or item.Name:match("^VolcanoDragonPool")
				or item.Name == "VolcanoLavaFall"
			then
				item:Destroy()
			end
		end
	end
	for _, p in ground:GetChildren() do
		if p:IsA("BasePart") and p.Name:match("^VolcanoRamp%d+$") then
			p:Destroy()
		end
	end

	-- Stepped sloping black interior stays within the original radius-80 foot.
	-- Its roof has headroom for the new horn-tip detailing, without occluding it.
	for band = 1, 8 do
		local low = (band - 1) * 8.5
		local high = band * 8.5
		local backLow = 75 - low * 18 / 68
		local backHigh = 75 - high * 18 / 68
		local a = Vector3.new(0, low, backLow)
		local b = Vector3.new(0, high, backHigh)
		local halfWidth = if band >= 4 then 33 else 24
		black(
			"RearLightSeal" .. band,
			Vector3.new(halfWidth * 2, (b - a).Magnitude + 1, 1.6),
			CFrame.fromMatrix((a + b) / 2, Vector3.xAxis, (b - a).Unit)
		)
		for side = -1, 1, 2 do
			black(
				"SideLightSeal" .. band,
				Vector3.new(1.6, 10, backLow - 17),
				CFrame.new(side * halfWidth, (low + high) / 2, (backLow + 17) / 2)
			)
			if band == 4 then
				black(
					"HornRecessSill",
					Vector3.new(10.6, 1.6, backLow - 17),
					CFrame.new(side * 28.5, low, (backLow + 17) / 2)
				)
			end
		end
	end
	black("CaveRoof", Vector3.new(67.6, 2, 44), CFrame.new(0, 69, 38))
	local scenicFloor =
		black("DragonCaveFloor", Vector3.new(48, 2, 59), CFrame.new(0, 0, 46.5), ground)
	scenicFloor:SetAttribute("VolcanoScenicFloor", true)
	scenicFloor:SetAttribute("VolcanoVisitorMaxZ", 29)
	local boundary = part(
		"AudienceBoundary",
		Vector3.new(48, 4.8, 1.6),
		CFrame.new(0, 3.1, 31),
		BASALT,
		rock,
		Enum.Material.Basalt
	)
	boundary:SetAttribute("VolcanoVisitorBoundary", true)
	-- Fractured cap makes the visitor edge visibly read as a low stone barrier.
	for index = -3, 3 do
		part(
			"AudienceBoundaryCap",
			Vector3.new(6.9, 0.7, 2.1),
			CFrame.new(index * 6.7, 5.7 + math.sin(index) * 0.1, 31),
			ROAD:Lerp(BASALT, 0.65),
			rock,
			Enum.Material.Rock
		)
	end

	-- Asymmetric, faceted back mass. Arc panels are broad fractured faces with
	-- staggered seams; short dark clefts divide selected edges into strata.
	local bands = { 0, 12, 25, 40, 55, 68, 78, 88 }
	local segments = 16
	for band = 1, #bands - 1 do
		local low, high = bands[band], bands[band + 1]
		for index = 0, segments - 1 do
			-- Stagger joints by less than a quarter panel; overlap remains generous.
			local stagger = math.sin(index * 1.71 + band * 2.1) * 0.023
			local angle = -math.pi / 2 + (index + 0.5) / segments * math.pi + stagger
			local rLow, rHigh = shellRadius(low, angle), shellRadius(high, angle)
			local radial = Vector3.new(math.sin(angle), 0, math.cos(angle))
			local tangent = Vector3.new(math.cos(angle), 0, -math.sin(angle))
			local slope = (Vector3.yAxis * (high - low) + radial * (rHigh - rLow)).Unit
			local jitter = math.sin(index * 2.3 + band * 1.7)
			local pos = radial * ((rLow + rHigh) / 2)
				+ Vector3.new(0, (low + high) / 2 + jitter * 0.35, 0)
			local width = math.pi * (rLow + rHigh) / 2 / segments * 1.15
			local size =
				Vector3.new(width, math.sqrt((high - low) ^ 2 + (rHigh - rLow) ^ 2) + 1.5, 3)
			local face = part(
				`ButtressFace{band}_{index}`,
				size,
				CFrame.fromMatrix(pos, tangent, slope),
				BASALT:Lerp(Color3.fromRGB(96, 73, 65), 0.22 + 0.12 * jitter),
				rock,
				Enum.Material.Basalt
			)
			face:SetAttribute("VolcanoRockFace", true)
		end
	end
	-- Join the authored rear half to the original front facets. Their angular
	-- tessellations differ: overlapping seam stones close the oblique sky slit
	-- visible from the audience's lateral view without narrowing the cave mouth.
	for side = -1, 1, 2 do
		for band = 1, #bands - 1 do
			local low, high = bands[band], bands[band + 1]
			local a = Vector3.new(side * flank(low), low, 0)
			local b = Vector3.new(side * flank(high), high, 0)
			local seam = part(
				"EnvelopeJoin",
				Vector3.new(14, (b - a).Magnitude + 2, 3.6),
				CFrame.fromMatrix((a + b) / 2, Vector3.zAxis, (b - a).Unit),
				BASALT,
				rock,
				Enum.Material.Basalt
			)
			seam:SetAttribute("VolcanoEnvelopeJoin", true)
		end
	end
	-- A broken rock lip frames the darkness while leaving the whole head clear.
	for side = -1, 1, 2 do
		for tier = 0, 3 do
			local y = 28 + tier * 10 + side * math.sin(tier * 1.2) * 1.1
			local x = side * (33 + math.sin(tier * 1.4) * 1.8)
			local p = part(
				`ThresholdRib{side}_{tier}`,
				Vector3.new(6.5 + tier % 2, 10.8 + tier % 3, 10 + tier % 2 * 3),
				CFrame.new(x, y, 21 + tier % 2 * 3)
					* CFrame.Angles(side * 0.06, side * 0.16, side * (0.09 + tier * 0.02)),
				BASALT:Lerp(ROAD, tier * 0.07),
				rock,
				Enum.Material.Rock
			)
			-- This outer lip dresses an already sealed cavity, not a movement wall.
			p.CanCollide = false
			p.CanQuery = false
			p:SetAttribute("VolcanoThreshold", true)
		end
	end
	for i = -3, 3 do
		part(
			"ThresholdCrown",
			Vector3.new(8.5, 6, 9),
			CFrame.new(i * 7, 66 + math.cos(i) * 1.5, 18) * CFrame.Angles(0, 0, i * 0.035),
			BASALT,
			rock,
			Enum.Material.Rock
		)
	end

	-- A visible, continuous spiral outside the new shell. Original start and
	-- summit arrival bearings retained so arch and crater stairs still line up.
	local previous: Vector3? = nil
	for step = 0, 64 do
		local t = step / 64
		local h = t * 98
		local angle = math.pi - 0.9 - t * 1.6 * math.pi * 2
		local shoulder = 7.5 - 4 * math.clamp((t - 0.92) / 0.08, 0, 1)
		local radius = shellRadius(h, angle) + shoulder
		local point = Vector3.new(math.sin(angle) * radius, h, math.cos(angle) * radius)
		if previous then
			local along = point - previous
			local tread = part(
				"VolcanoRamp" .. step,
				Vector3.new(8, 1.6, along.Magnitude + 1.8),
				CFrame.lookAt((point + previous) / 2, point),
				ROAD:Lerp(BASALT, (step % 5) * 0.07),
				ground,
				Enum.Material.Cobblestone
			)
			tread:SetAttribute("VolcanoRoute", "spiral")
			-- Low, irregular outer kerbs are real stone, with gaps at landings.
			if step % 8 ~= 0 then
				local outward = Vector3.new(point.X, 0, point.Z).Unit
				local kerb = part(
					"SpiralKerb",
					Vector3.new(1.1, 1.8, math.min(6, along.Magnitude)),
					CFrame.lookAt(
						point + outward * 4.2 + Vector3.new(0, 0.8, 0),
						point + outward * 4.2 + along
					),
					BASALT,
					rock,
					Enum.Material.Basalt
				)
				kerb:SetAttribute("VolcanoRoute", "spiral")
			end
		end
		previous = point
	end
	return cave
end

return VolcanoCave
