--!strict
-- QA-only automatic scenic camera. Excluded from the default place.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
assert(RunService:IsStudio(), "Volcano QA camera is Studio-only")
local player = Players.LocalPlayer
local gui = Instance.new("ScreenGui")
gui.Name = "VolcanoQAOverlay"
gui.ResetOnSpawn = false
gui.DisplayOrder = 100
gui.Parent = player:WaitForChild("PlayerGui")
local label = Instance.new("TextLabel")
label.AnchorPoint = Vector2.new(0.5, 0)
label.Position = UDim2.new(0.5, 0, 0, 12)
label.Size = UDim2.new(0.6, 0, 0, 64)
label.BackgroundColor3 = Color3.fromRGB(15, 20, 23)
label.BackgroundTransparency = 0.1
label.TextColor3 = Color3.fromRGB(235, 237, 241)
label.TextSize = 15
label.Font = Enum.Font.Code
label.TextWrapped = true
label.Parent = gui
local views: { { name: string, eye: Vector3, target: Vector3 } } = {}
local start = time()
local function find(name: string): BasePart?
	local object = Workspace:FindFirstChild(name, true)
	return if object and object:IsA("BasePart") then object else nil
end
task.spawn(function()
	local deadline = time() + 60
	while not find("TrialStart") and time() < deadline do
		task.wait(0.2)
	end
	local centre = Vector3.new(251, 0, -145)
	local dragon = find("DragonAudience") or find("DragonInteraction")
	if not dragon then
		for _, item in Workspace:GetDescendants() do
			if item:IsA("BasePart") and item:GetAttribute("VolcanoAction") == "dragon" then
				dragon = item
				break
			end
		end
	end
	local entrance = find("EmberBrazier")
	local refuge = find("RefugeCache")
	local trial = find("TrialFinish")
	local crater = find("CraterSource")
	local frame = CFrame.new(centre) * (if dragon then dragon.CFrame.Rotation else CFrame.identity)
	table.insert(views, {
		name = "Approach",
		eye = centre
			+ (if dragon then dragon.CFrame.LookVector * 190 else Vector3.new(145, 0, 145))
			+ Vector3.new(0, 72, 0),
		target = centre + Vector3.new(0, 30, 0),
	})
	table.insert(views, {
		name = "Chamber",
		eye = frame:PointToWorldSpace(Vector3.new(18, 10, -24)),
		target = frame:PointToWorldSpace(Vector3.new(0, 23, 17)),
	})
	for _, entry in
		{
			{ "Brazier", entrance },
			{ "Refuge", refuge },
			{ "Crater", crater },
		}
	do
		local point = entry[2] :: BasePart?
		if point then
			local distance = if entry[1] == "Crater" then 24 else 12
			table.insert(views, {
				name = entry[1] :: string,
				eye = point.Position + point.CFrame.LookVector * distance + Vector3.new(0, 7, 0),
				target = point.Position,
			})
		end
	end
	if trial then
		table.insert(views, {
			name = "Trial",
			eye = frame:PointToWorldSpace(Vector3.new(-15, 20, -5)),
			target = frame:PointToWorldSpace(Vector3.new(-32, 10, 14)),
		})
	end
	start = time()
end)
RunService.RenderStepped:Connect(function()
	local camera = Workspace.CurrentCamera
	if not camera or #views == 0 then
		return
	end
	local view = views[math.floor((time() - start) / 8) % #views + 1]
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt(view.eye, view.target)
	label.Text =
		`VOLCANO QA · {view.name} · {Workspace:GetAttribute("VolcanoQAStatus") or "Booting"}\n{Workspace:GetAttribute(
			"VolcanoQASummary"
		) or "Waiting for real player and services..."}`
end)
