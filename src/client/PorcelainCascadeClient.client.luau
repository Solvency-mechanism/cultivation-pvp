--!strict
-- Four authored falls, six local accents each. One throttled worker owns all
-- animation; distant and streamed-out scenes release their visual workload.
local Workspace = game:GetService("Workspace")
local MAX_FALLS = 4
local VISIBLE_DISTANCE = 150
local TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
type Accent = { attachment: Attachment, emitter: ParticleEmitter, parts: { Part } }
local accents: { [BasePart]: Accent } = {}
local count = 0
local activeRoot: Instance? = nil
local rootConnections: { RBXScriptConnection } = {}
local arenaConnections: { RBXScriptConnection } = {}
local stopped = false
local enabled = false

local function removeFall(object: Instance)
	if not object:IsA("BasePart") then
		return
	end
	local accent = accents[object]
	if not accent then
		return
	end
	accents[object] = nil
	count -= 1
	accent.attachment:Destroy()
	for _, part in accent.parts do
		part:Destroy()
	end
end

local function registerFall(object: Instance)
	if not object:IsA("BasePart") or accents[object] or count >= MAX_FALLS then
		return
	end
	if not object.Anchored or object:GetAttribute("CascadeWaterfall") ~= true then
		return
	end
	local attachment = Instance.new("Attachment")
	attachment.Name = "CascadeLocalSpray"
	attachment.Position = Vector3.new(0, -object.Size.Y / 2, -object.Size.Z / 2 - 0.12)
	attachment.Parent = object
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "ImpactSpray"
	emitter.Texture = TEXTURE
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Color = ColorSequence.new(Color3.fromRGB(228, 240, 230))
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.09),
		NumberSequenceKeypoint.new(1, 0.035),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.3, 0.6)
	emitter.Speed = NumberRange.new(1.5, 3)
	emitter.Acceleration = Vector3.new(0, -8, 0)
	emitter.SpreadAngle = Vector2.new(45, 45)
	emitter.LightEmission = 0
	emitter.LightInfluence = 1
	emitter.Rate = 6
	emitter.Enabled = false
	emitter.Parent = attachment
	local parts: { Part } = {}
	for index = 1, 6 do
		local part = Instance.new("Part")
		part.Name = if index <= 4 then "CascadeFlowHighlight" else "CascadeImpactFoam"
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
		part.Material = Enum.Material.SmoothPlastic
		part.Color = Color3.fromRGB(223, 238, 224)
		part.Transparency = 1
		part.Size = Vector3.new(0.08, 0.4, 0.025)
		if index > 4 then
			local mesh = Instance.new("SpecialMesh")
			mesh.MeshType = Enum.MeshType.Sphere
			mesh.Parent = part
		end
		part.Parent = object
		table.insert(parts, part)
	end
	accents[object] = { attachment = attachment, emitter = emitter, parts = parts }
	count += 1
end

local function animate(now: number)
	for source, accent in accents do
		local height = source.Size.Y
		local width = source.Size.X
		for index, part in accent.parts do
			if index <= 4 then
				local phase = (now * (0.65 + index * 0.035) + index * 0.237) % 1
				local length = math.min(height * 0.17, 1.8)
				part.Size = Vector3.new(math.clamp(width * 0.035, 0.045, 0.12), length, 0.025)
				part.CFrame = source.CFrame
					* CFrame.new(
						(index - 2.5) * width * 0.19,
						(0.5 - phase) * (height - length),
						-source.Size.Z / 2 - 0.045
					)
				part.Transparency = 0.55 + 0.45 * math.abs(phase * 2 - 1)
			else
				local phase = (now * 0.65 + index * 0.5) % 1
				local foot = source.CFrame:PointToWorldSpace(
					Vector3.new(0, -height / 2 + 0.04, -source.Size.Z / 2 - 0.12)
				)
				part.Size = Vector3.new(
					math.min(width, 3) * (0.45 + phase * 0.6),
					0.035,
					0.22 + phase * 0.65
				)
				part.CFrame = CFrame.new(foot + Vector3.new(0, 0.03 + (index - 5) * 0.02, 0))
				part.Transparency = 0.65 + phase * 0.35
			end
		end
	end
end

local function setEnabled(value: boolean)
	enabled = value
	for _, accent in accents do
		accent.emitter.Enabled = value
		if not value then
			accent.emitter:Clear()
			for _, part in accent.parts do
				part.Transparency = 1
			end
		end
	end
end

local function releaseRoot()
	for _, connection in rootConnections do
		connection:Disconnect()
	end
	table.clear(rootConnections)
	for part in accents do
		removeFall(part)
	end
	activeRoot = nil
	enabled = false
end
local function bindRoot(root: Instance)
	if root.Name ~= "PorcelainCascade" or root == activeRoot then
		return
	end
	releaseRoot()
	activeRoot = root
	table.insert(rootConnections, root.DescendantAdded:Connect(registerFall))
	table.insert(rootConnections, root.DescendantRemoving:Connect(removeFall))
	for _, object in root:GetDescendants() do
		registerFall(object)
	end
end
script.Destroying:Connect(function()
	stopped = true
	releaseRoot()
	for _, connection in arenaConnections do
		connection:Disconnect()
	end
	table.clear(arenaConnections)
end)
task.spawn(function()
	local arena = Workspace:WaitForChild("ArenaDecor", 30)
	if not arena or stopped then
		return
	end
	table.insert(arenaConnections, arena.ChildAdded:Connect(bindRoot))
	table.insert(
		arenaConnections,
		arena.ChildRemoved:Connect(function(root)
			if root == activeRoot then
				releaseRoot()
			end
		end)
	)
	local existing = arena:FindFirstChild("PorcelainCascade")
	if existing then
		bindRoot(existing)
	end
	local nextDistanceCheck = 0
	while not stopped do
		local now = os.clock()
		if now >= nextDistanceCheck then
			nextDistanceCheck = now + 1
			local camera = Workspace.CurrentCamera
			local centre = if activeRoot then activeRoot:GetAttribute("Centre") else nil
			setEnabled(
				camera ~= nil
					and typeof(centre) == "Vector3"
					and (camera.CFrame.Position - centre).Magnitude <= VISIBLE_DISTANCE
			)
		end
		if enabled then
			animate(now)
		end
		task.wait(if enabled then 0.05 else 1)
	end
end)
