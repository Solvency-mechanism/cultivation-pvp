--!strict
-- QA-only camera. 1/2/3 select views; 0 restores. Never moves the character.
local RunService = game:GetService("RunService")
if not RunService:IsStudio() then
	return
end
local Workspace = game:GetService("Workspace")
local Input = game:GetService("UserInputService")
local camera = assert(Workspace.CurrentCamera, "Camera missing")
local original = { kind = camera.CameraType, frame = camera.CFrame, fov = camera.FieldOfView }
local names = { "approach", "overhang", "source" }
local eyes = { Vector3.new(0, 14, -76), Vector3.new(30, 24, 4), Vector3.new(-33, 55, 62) }
local targets = { Vector3.new(0, 22, 3), Vector3.new(0, 17, 9), Vector3.new(0, 37, 40) }
Input.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.Zero then
		camera.CameraType = original.kind
		camera.CFrame = original.frame
		camera.FieldOfView = original.fov
		return
	end
	local index = if input.KeyCode == Enum.KeyCode.One
		then 1
		elseif input.KeyCode == Enum.KeyCode.Two then 2
		elseif input.KeyCode == Enum.KeyCode.Three then 3
		else nil
	if not index then
		return
	end
	local root = Workspace:FindFirstChild("PorcelainCascade", true)
	if not root then
		return
	end
	local centre = root:GetAttribute("Centre")
	if typeof(centre) ~= "Vector3" then
		return
	end
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt(centre + eyes[index], centre + targets[index])
	camera.FieldOfView = 65
	print(
		`[Cascade camera] {names[index]} viewport={camera.ViewportSize} FOV=65; photo only, no performance claim`
	)
end)
