--!strict
-- Controlled fracture/crust kit: sparse larger forms, no random floor scatter.
local Surface = {}
function Surface.build(root: Folder)
	if root:FindFirstChild("GeologicalDetail") then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "GeologicalDetail"
	folder.Parent = root
	local index = 0
	local centre = root:GetAttribute("Centre")
	local function outside(p: BasePart): number
		if typeof(centre) ~= "Vector3" then
			return 1
		end
		local radial = p.CFrame.Position - centre
		radial = Vector3.new(radial.X, 0, radial.Z)
		return if p.CFrame.ZVector:Dot(radial) >= 0 then 1 else -1
	end
	local function shard(name: string, size: Vector3, cf: CFrame, color: Color3)
		local p = Instance.new("WedgePart")
		p.Name = name
		p.Size = size
		p.CFrame = cf
		p.Color = color
		p.Material = Enum.Material.Basalt
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p:SetAttribute("VolcanoSurfaceDetail", true)
		p.Parent = folder
	end
	for _, p in root:GetDescendants() do
		if p:IsA("BasePart") and p.Name:match("^VolcanoRiver") then
			local outward = outside(p)
			p.Color = Color3.fromRGB(245, 91, 23)
			for _, light in p:GetChildren() do
				if light:IsA("PointLight") then
					light.Color = p.Color
					light.Brightness = 0.45
					light.Range = 16
				end
			end
			for side = -1, 1, 2 do
				shard(
					"CooledFlowEdge",
					Vector3.new(p.Size.X * 0.38, p.Size.Y * 0.85, 0.7),
					p.CFrame
						* CFrame.new(side * p.Size.X * 0.39, side * 0.5, outward * 0.65)
						* CFrame.Angles(0, 0, side * 0.06),
					Color3.fromRGB(57, 34, 29)
				)
			end
		elseif
			p:IsA("BasePart")
			and (p.Name:match("^VolcanoFacet") or p:GetAttribute("VolcanoRockFace"))
		then
			index += 1
			local outward = outside(p)
			if index % 4 == 0 then
				shard(
					"FracturePlane",
					Vector3.new(p.Size.X * 0.55, p.Size.Y * 0.43, 1.8),
					p.CFrame
						* CFrame.new(
							p.Size.X * 0.13 * math.sin(index),
							-p.Size.Y * 0.12,
							outward * (p.Size.Z * 0.5 + 0.4)
						)
						* CFrame.Angles(0, 0, math.sin(index * 2) * 0.18),
					p.Color:Lerp(Color3.fromRGB(115, 92, 78), 0.2)
				)
			end
			if index % 9 == 2 then
				shard(
					"CompressedStratum",
					Vector3.new(p.Size.X * 0.83, 0.65, 1.1),
					p.CFrame
						* CFrame.new(
							-p.Size.X * 0.06,
							-p.Size.Y * 0.22,
							outward * (p.Size.Z * 0.5 + 0.28)
						)
						* CFrame.Angles(0, 0, 0.045),
					Color3.fromRGB(35, 31, 32)
				)
			end
			if p.CFrame.Position.Y < 14 and index % 2 == 0 then
				local base = p.CFrame.Position - Vector3.new(0, p.CFrame.Position.Y + 0.3, 0)
				shard(
					"EmbeddedTalus",
					Vector3.new(p.Size.X * 0.68, 3.1, 4.1),
					CFrame.new(base) * p.CFrame.Rotation * CFrame.Angles(0, 0, index * 0.017),
					Color3.fromRGB(67, 54, 48)
				)
			end
		elseif p:IsA("BasePart") and p:GetAttribute("VolcanoThreshold") then
			shard(
				"ThresholdBrokenLip",
				Vector3.new(p.Size.X * 0.72, p.Size.Y * 0.74, 3.2),
				p.CFrame
					* CFrame.new(
						-math.sign(
								p.CFrame.Position.X
									- (if typeof(centre) == "Vector3" then centre.X else 0)
							) * 0.4,
						0,
						-p.Size.Z * 0.47
					)
					* CFrame.Angles(0, 0, 0.13),
				p.Color:Lerp(Color3.fromRGB(85, 69, 60), 0.18)
			)
		end
	end
end
return Surface
