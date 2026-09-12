--!strict
-- Structural sculpture variant. Original muzzle/teeth/pupils remain stored
-- for baseline comparison but are hidden; the complete original is NOT visible.
local Detail = {}
function Detail.build(root: Folder)
	local dragon: Model? = nil
	for _, item in root:GetChildren() do
		if item:IsA("Model") and item:GetAttribute("VolcanoDragon") then
			dragon = item
			break
		end
	end
	if not dragon or dragon:FindFirstChild("SculptureDetail") then
		return
	end
	local head = dragon:FindFirstChild("Head") :: BasePart
	if not head then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "SculptureDetail"
	folder.Parent = dragon
	local scale = head.Size.X / 14
	local basis = head.CFrame * CFrame.new(0, -12 * scale, 0)
	local red = Color3.fromRGB(123, 31, 27)
	local ridge = Color3.fromRGB(151, 43, 31)
	local dark = Color3.fromRGB(53, 20, 19)
	local bone = Color3.fromRGB(175, 155, 115)
	for _, original in dragon:GetChildren() do
		if
			original:IsA("BasePart")
			and (
				original.Name == "Snout"
				or string.match(original.Name, "^Nostril")
				or string.match(original.Name, "^Slit")
				or string.match(original.Name, "^Tooth")
				or original.Name == "EyeL"
				or original.Name == "EyeR"
				or original.Name == "Jaw"
				or original.Name == "Tongue"
			)
		then
			original:SetAttribute("SculptureBaselineTransparency", original.Transparency)
			original:SetAttribute("SculptureBaselineCanQuery", original.CanQuery)
			original:SetAttribute("SculptureBaselineHidden", true)
			original.Transparency = 1
			original.CanQuery = false
			if original:GetAttribute("VolcanoBreath") then
				original:SetAttribute("SculptureBaselineBreath", true)
				original:SetAttribute("VolcanoBreath", nil)
			end
			if original.Name == "EyeL" or original.Name == "EyeR" then
				original:SetAttribute("SculptureBaselineColor", original.Color)
				original:SetAttribute("SculptureBaselineEye", true)
				original:SetAttribute("VolcanoEye", nil) -- Do not let breathing unhide the baseline.
				for _, light in original:GetChildren() do
					if light:IsA("PointLight") then
						light.Enabled = false
					end
				end
			end
		end
	end
	local function piece(
		name: string,
		kind: string,
		size: Vector3,
		at: CFrame,
		color: Color3
	): BasePart
		local p = Instance.new(kind) :: BasePart
		p.Name = name
		p.Size = size * scale
		p.CFrame = basis * CFrame.new(at.Position * scale) * at.Rotation
		p.Anchored = true
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = false
		p.Material = Enum.Material.Slate
		p.Color = color
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = folder
		return p
	end
	-- Six broad planes support the silhouette; fine repetitive scales were
	-- visually lost at player distance and made the cap look tiled.
	for row = 0, 1 do
		for col = -1, 1 do
			piece(
				"CrownScale",
				"WedgePart",
				Vector3.new(3.8, 0.85, 5.1),
				CFrame.new(col * 3.7 + row * 0.25, 17.15, -4.9 + row * 5.0)
					* CFrame.Angles(0, math.pi, 0),
				if (row + col) % 2 == 0 then red else ridge
			)
		end
	end
	-- Three diminishing sections replace the single square frontal muzzle.
	-- Large sloping side planes bridge their shoulders without rounded shapes.
	piece("MuzzleRoot", "Part", Vector3.new(12.4, 5.0, 5.2), CFrame.new(0, 11.3, 9.2), red)
	piece("MuzzleMiddle", "Part", Vector3.new(10.8, 4.5, 5.5), CFrame.new(0, 10.95, 13.7), red)
	piece("MuzzleTip", "Part", Vector3.new(9.0, 3.6, 4.8), CFrame.new(0, 10.5, 18.0), red)
	piece(
		"NoseBridge",
		"WedgePart",
		Vector3.new(8.9, 1.6, 10.5),
		CFrame.new(0, 12.7, 14.2) * CFrame.Angles(0, math.pi, 0),
		ridge
	)
	piece(
		"NoseCap",
		"WedgePart",
		Vector3.new(9.0, 0.65, 1.6),
		CFrame.new(0, 12.0, 19.8) * CFrame.Angles(0, math.pi, 0),
		red
	)
	local interior = Color3.fromRGB(20, 10, 13)
	local mouthBack =
		piece("MouthBack", "Part", Vector3.new(8.6, 3.5, 0.35), CFrame.new(0, 7.0, 16.6), interior)
	mouthBack:SetAttribute("DragonMouthInterior", true)
	mouthBack:SetAttribute("VolcanoMouth", "upper")
	local roof =
		piece("MouthRoof", "Part", Vector3.new(8.5, 0.15, 4.2), CFrame.new(0, 8.66, 18.2), interior)
	roof:SetAttribute("DragonMouthInterior", true)
	roof:SetAttribute("VolcanoMouth", "upper")
	local jaw = dragon:FindFirstChild("Jaw") :: BasePart?
	if jaw then
		local function jawPiece(
			name: string,
			kind: string,
			size: Vector3,
			offset: CFrame,
			color: Color3
		): BasePart
			local p = piece(name, kind, size, CFrame.identity, color)
			p.CFrame = jaw.CFrame * CFrame.new(offset.Position * scale) * offset.Rotation
			p:SetAttribute("VolcanoJaw", true)
			return p
		end
		jawPiece(
			"LowerJawRoot",
			"Part",
			Vector3.new(11.0, 2.4, 5.8),
			CFrame.new(0, -0.1, -3.3),
			red
		)
		jawPiece(
			"LowerJawFront",
			"WedgePart",
			Vector3.new(9.4, 2.2, 7.7),
			CFrame.new(0, -0.1, 2.8) * CFrame.Angles(0, math.pi, 0),
			red
		)
		local bed = jawPiece(
			"MouthBed",
			"Part",
			Vector3.new(8.6, 0.18, 10.8),
			CFrame.new(0, 1.12, 0.6),
			interior
		)
		bed:SetAttribute("DragonMouthInterior", true)
		bed:SetAttribute("VolcanoMouth", "lower")
		for side = -1, 1, 2 do
			jawPiece(
				"BeveledLowerLip",
				"WedgePart",
				Vector3.new(0.65, 1.3, 10.2),
				CFrame.new(side * 4.55, 0.78, 0.7) * CFrame.Angles(0, side * 0.07, side * 0.22),
				ridge
			)
		end
	end
	for side = -1, 1, 2 do
		local suffix = if side < 0 then "L" else "R"
		piece(
			"BroadSkull" .. suffix,
			"Part",
			Vector3.new(4.0, 8.6, 11.5),
			CFrame.new(side * 7.4, 12.4, 0.1),
			red
		)
		-- Broad cheek planes taper toward the muzzle rather than adding a second jaw.
		piece(
			"CheekPlane",
			"WedgePart",
			Vector3.new(3.0, 5.5, 9),
			CFrame.new(side * 8.0, 11.3, 4.2) * CFrame.Angles(0, side * 0.16, side * 0.07),
			red
		)
		-- The original eyes were recessed behind the brow from a player's low
		-- view. These forward almond forms sit clear of both brow and muzzle.
		piece(
			"EyeSocket",
			"Part",
			Vector3.new(4.3, 2.3, 1.2),
			CFrame.new(side * 6.3, 17.0, 9.3),
			red
		)
		piece(
			"EyeBrow",
			"WedgePart",
			Vector3.new(4.3, 0.65, 1.3),
			CFrame.new(side * 6.3, 18.25, 10.5) * CFrame.Angles(0, 0, side * 0.10),
			dark
		)
		piece(
			"MuzzleShoulder",
			"WedgePart",
			Vector3.new(1.55, 3.9, 8.8),
			CFrame.new(side * 5.2, 10.8, 13.6) * CFrame.Angles(0, side * 0.14, side * 0.10),
			red
		)
		piece(
			"NostrilInset",
			"Part",
			Vector3.new(1.1, 0.38, 0.12),
			CFrame.new(side * 2.7, 11.2, 20.44) * CFrame.Angles(0, 0, side * 0.22),
			dark
		)
		local eye = piece(
			"ForwardAmberEye",
			"Part",
			Vector3.new(3.7, 1.8, 0.85),
			CFrame.new(side * 6.3, 17.0, 10.65),
			Color3.fromRGB(224, 149, 38)
		)
		local eyeMesh = Instance.new("SpecialMesh")
		eyeMesh.MeshType = Enum.MeshType.Sphere
		eyeMesh.Parent = eye
		eye.Material = Enum.Material.Neon
		eye:SetAttribute("VolcanoEye", true)
		local pupil = piece(
			"CenteredPupil",
			"Part",
			Vector3.new(0.5, 1.45, 0.16),
			CFrame.new(side * 6.3, 17.0, 11.08),
			Color3.fromRGB(18, 14, 11)
		)
		pupil.Material = Enum.Material.SmoothPlastic
		local fang = piece(
			"UpperCornerFang",
			"WedgePart",
			Vector3.new(0.72, 2.6, 0.8),
			CFrame.new(side * 3.9, 7.85, 19.0) * CFrame.Angles(0, math.pi / 2, math.pi),
			bone
		)
		fang.Material = Enum.Material.Marble
		fang:SetAttribute("DragonToothRow", 1)
		fang:SetAttribute("DragonToothSide", "upper")
		-- A second pair sweeps outward before curving upward, clearly separate
		-- from the original tall crown horns. Ends remain within the cave envelope.
		piece(
			"OuterHornSocket" .. suffix,
			"Part",
			Vector3.new(3.8, 3.6, 3.8),
			CFrame.new(side * 7.8, 17.4, 5.0),
			red
		)
		local function hornSegment(name: string, a: Vector3, b: Vector3, thickness: number)
			-- +Y points toward b. The opposite rotation made the wedge point
			-- back into the skull, exposing disconnected arrowhead bases.
			local axis = CFrame.lookAt((a + b) / 2, b) * CFrame.Angles(-math.pi / 2, 0, 0)
			local p = piece(
				name .. suffix,
				if name == "OuterHornBase" then "Part" else "WedgePart",
				Vector3.new(thickness, (b - a).Magnitude + 0.3, thickness),
				axis,
				bone
			)
			p.Material = Enum.Material.Marble
			p:SetAttribute("DragonOuterHorn", true)
			p:SetAttribute("VolcanoHornSide", side)
		end
		hornSegment(
			"OuterHornBase",
			Vector3.new(side * 8.0, 18.5, 5.0),
			Vector3.new(side * 12.8, 22.0, 3.8),
			2.5
		)
		hornSegment(
			"OuterHornTip",
			Vector3.new(side * 12.8, 22.0, 3.8),
			Vector3.new(side * 14.8, 26.0, 1.5),
			2.5
		)
		local horn = dragon:FindFirstChild(if side < 0 then "HornL" else "HornR") :: BasePart
		if horn then
			local cap = piece("HornTip", "WedgePart", Vector3.new(3, 5, 3), CFrame.identity, bone)
			cap.Material = Enum.Material.Marble
			cap.CFrame = horn.CFrame
				* CFrame.new(0, horn.Size.Y / 2 + cap.Size.Y / 2 - scale * 0.15, 0)
			for i = 0, 3 do
				local ring = piece(
					"HornGrowthRidge",
					"Part",
					Vector3.new(3.16, 0.2, 3.16),
					CFrame.identity,
					bone
				)
				ring.CFrame = horn.CFrame * CFrame.new(0, (-5 + i * 2.8) * scale, 0)
			end
		end
	end
	-- Spacing and two dominant fangs replace the original even square comb.
	for index = 1, 4 do
		local x = -2.7 + (index - 1) * 1.8
		local length = if index % 2 == 0 then 1.45 else 1.15
		local tooth = piece(
			"UpperTaperedTooth" .. index,
			"WedgePart",
			Vector3.new(0.48, length, 0.6),
			CFrame.new(x, 8.7 - length / 2, 19.7) * CFrame.Angles(0, math.pi / 2, math.pi),
			bone
		)
		tooth.Material = Enum.Material.Marble
		tooth:SetAttribute("DragonToothRow", 1)
		tooth:SetAttribute("DragonToothSide", "upper")
		local lower = piece(
			"LowerTaperedTooth" .. index,
			"WedgePart",
			Vector3.new(0.48, 1.0 + index % 2 * 0.2, 0.65),
			CFrame.new(x + 0.3, 6.5, 18.9) * CFrame.Angles(0.32, math.pi / 2, 0),
			bone
		)
		lower.Material = Enum.Material.Marble
		lower:SetAttribute("VolcanoJaw", true)
		lower:SetAttribute("DragonToothRow", 1)
		lower:SetAttribute("DragonToothSide", "lower")
	end
	-- A staggered second row sits behind the preserved front tooth silhouette.
	for index = 1, 5 do
		local x = -3.2 + (index - 1) * 1.6
		local length = if index % 2 == 0 then 1.35 else 1.65
		local upper = piece(
			"RearUpperTooth" .. index,
			"WedgePart",
			Vector3.new(0.42, length, 0.75),
			CFrame.new(x, 8.65 - length / 2, 18.15) * CFrame.Angles(0, math.pi / 2, math.pi),
			bone
		)
		upper.Material = Enum.Material.Marble
		upper:SetAttribute("DragonToothRow", 2)
		upper:SetAttribute("DragonToothSide", "upper")
		local lower = piece(
			"RearLowerTooth" .. index,
			"WedgePart",
			Vector3.new(0.42, 1.3, 0.75),
			CFrame.new(x + 0.25, 6.55, 17.5) * CFrame.Angles(0.32, math.pi / 2, 0),
			bone
		)
		lower.Material = Enum.Material.Marble
		lower:SetAttribute("VolcanoJaw", true)
		lower:SetAttribute("DragonToothRow", 2)
		lower:SetAttribute("DragonToothSide", "lower")
	end
	for _, p in folder:GetDescendants() do
		if p:IsA("BasePart") and p:GetAttribute("DragonToothRow") then
			p:SetAttribute(
				"VolcanoToothRow",
				if p:GetAttribute("DragonToothRow") == 1 then "front" else "inner"
			)
			p:SetAttribute("VolcanoToothArch", p:GetAttribute("DragonToothSide"))
		end
	end
	folder:SetAttribute("ArtVariant", "broad-four-horn-dragon-v5")
	folder:SetAttribute("VisibleToothCount", 20)
	folder:SetAttribute("OuterHornCount", 2)
	folder:SetAttribute(
		"BaselineVisibility",
		"Original snout, eyes, nostrils, slits, teeth, jaw and tongue retained but hidden; Jaw remains animation pivot"
	)
end
return Detail
