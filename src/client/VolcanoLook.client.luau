--!strict
-- Camera-local cave adaptation. Outdoor palette restores smoothly on exit.
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local root = Workspace:WaitForChild("ArenaDecor"):WaitForChild("VolcanoExperience", 30)
if not root then
	return
end
local offer = root:WaitForChild("DragonOffer", 30)
if not offer or not offer:IsA("BasePart") then
	return
end
local centre = root:GetAttribute("Centre")
if typeof(centre) ~= "Vector3" then
	return
end
local frame = CFrame.new(centre) * offer.CFrame.Rotation
local baseAmbient = Lighting.Ambient
local baseExposure = Lighting.ExposureCompensation
local bloom = Lighting:FindFirstChildOfClass("BloomEffect")
local baseBloom = if bloom then bloom.Intensity else 0
local grade = Instance.new("ColorCorrectionEffect")
grade.Name = "VolcanoLocalGrade"
grade.Parent = Lighting
local weight = 0
local appliedWeight = -1
RunService.RenderStepped:Connect(function(dt)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local p = frame:PointToObjectSpace(camera.CFrame.Position)
	local lateral = 1 - math.clamp((math.abs(p.X) - 27) / 18, 0, 1)
	local depth = math.clamp((p.Z + 55) / 30, 0, 1) * (1 - math.clamp((p.Z - 57) / 15, 0, 1))
	local height = 1 - math.clamp((p.Y - 42) / 18, 0, 1)
	local target = lateral * depth * height
	weight += (target - weight) * (1 - math.exp(-dt * 2.5))
	if math.abs(weight - appliedWeight) < 0.003 then
		return
	end
	appliedWeight = weight
	Lighting.Ambient = baseAmbient:Lerp(Color3.fromRGB(25, 20, 24), weight)
	Lighting.ExposureCompensation = baseExposure - weight * 0.18
	if bloom then
		bloom.Intensity = baseBloom * (1 - weight * 0.7)
	end
	grade.Contrast = weight * 0.06
	grade.Saturation = -weight * 0.08
	grade.TintColor = Color3.new(1, 1, 1):Lerp(Color3.fromRGB(255, 240, 223), weight * 0.35)
end)
-- Sparse motes only at the entrance; nothing illuminates the dragon's backdrop.
local dust = Instance.new("Part")
dust.Name = "VolcanoEntranceAsh"
dust.Transparency = 1
dust.Anchored = true
dust.CanCollide = false
dust.CanTouch = false
dust.CanQuery = false
dust.Size = Vector3.new(30, 1, 20)
dust.CFrame = frame * CFrame.new(0, 22, -36)
dust.Parent = root
local emitter = Instance.new("ParticleEmitter")
emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
emitter.Rate = 3
emitter.Lifetime = NumberRange.new(5, 8)
emitter.Speed = NumberRange.new(0.4, 0.8)
emitter.Acceleration = Vector3.new(0.1, -0.2, 0)
emitter.SpreadAngle = Vector2.new(180, 180)
emitter.Color = ColorSequence.new(Color3.fromRGB(157, 139, 118))
emitter.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.2, 0.6),
	NumberSequenceKeypoint.new(0.8, 0.8),
	NumberSequenceKeypoint.new(1, 1),
})
emitter.Size = NumberSequence.new(0.13)
emitter.LightEmission = 0
emitter.Parent = dust
