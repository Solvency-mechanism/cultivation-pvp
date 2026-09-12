--!strict
-- QA-only matched scenic camera and client frame samples; excluded from production.
-- Keys 1..8 select a fixed view, 0 resumes a complete 48-second cycle per view.
-- Optional Workspace attributes: VolcanoQACameraView (1..8), VolcanoQACameraAuto
-- (boolean), VolcanoQAVariant (baseline/candidate), VolcanoQAMachine (operator supplied).
-- VolcanoQACameraManifest: paste baseline's JSON pose list before starting a
-- candidate to lock identical world-space eyes/targets even if the head moves.
-- Never changes the production breath clock, dragon pose, lighting or player state.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
assert(RunService:IsStudio(), "Volcano QA camera is Studio-only; not physical-device evidence")
local player = Players.LocalPlayer
local gui = Instance.new("ScreenGui")
gui.Name = "VolcanoQAOverlay"
gui.ResetOnSpawn = false
gui.DisplayOrder = 100
gui.Parent = player:WaitForChild("PlayerGui")
local label = Instance.new("TextLabel")
label.AnchorPoint = Vector2.new(0.5, 0)
label.Position = UDim2.new(0.5, 0, 0, 12)
label.Size = UDim2.new(0.85, 0, 0, 96)
label.BackgroundColor3 = Color3.fromRGB(15, 20, 23)
label.BackgroundTransparency = 0.1
label.TextColor3 = Color3.fromRGB(235, 237, 241)
label.TextSize = 13
label.Font = Enum.Font.Code
label.TextWrapped = true
label.Parent = gui
local views: { { name: string, eye: Vector3, target: Vector3 } } = {}
local runStarted = time()
local cameraStarted = time()
local selected = 1
local automatic = true
local samples: { number } = {}
local sampleDuration = 0
local captureKeys: { [string]: boolean } = {}
local snapshotContext: any = {}
local function find(root: Instance, name: string): BasePart?
	local object = root:FindFirstChild(name, true)
	return if object and object:IsA("BasePart") then object else nil
end
local function vector(v: Vector3): { number }
	return { math.round(v.X * 100) / 100, math.round(v.Y * 100) / 100, math.round(v.Z * 100) / 100 }
end
local function percentile(sorted: { number }, fraction: number): number
	return sorted[math.clamp(math.ceil(#sorted * fraction), 1, #sorted)] or 0
end
local function report(viewName: string)
	if #samples == 0 then
		return
	end
	table.sort(samples)
	local context = table.clone(snapshotContext)
	local camera = Workspace.CurrentCamera
	context.variant = Workspace:GetAttribute("VolcanoQAVariant") or "UNLABELLED"
	context.machine = Workspace:GetAttribute("VolcanoQAMachine")
		or "UNRECORDED: operator must record hardware/OS"
	context.view = viewName
	context.samples = #samples
	context.sampleDurationSeconds = math.round(sampleDuration * 100) / 100
	context.clientElapsedSeconds = math.round((time() - runStarted) * 100) / 100
	context.frameMsP50 = percentile(samples, 0.50) * 1000
	context.frameMsP95 = percentile(samples, 0.95) * 1000
	context.frameMsP99 = percentile(samples, 0.99) * 1000
	context.frameMsMax = samples[#samples] * 1000
	context.meanFps = #samples / sampleDuration
	context.viewport = if camera
		then vector(Vector3.new(camera.ViewportSize.X, camera.ViewportSize.Y, 0))
		else {}
	context.renderQuality =
		tostring(UserSettings():GetService("UserGameSettings").SavedQualityLevel)
	context.streamingEnabled = Workspace.StreamingEnabled
	context.evidence =
		"Studio client RenderStepped wall intervals; includes editor/scheduling effects; not GPU timings or physical-device acceptance"
	local json = HttpService:JSONEncode(context)
	Workspace:SetAttribute("VolcanoQAPerformanceLatest", json) -- local capture convenience only
	print("[Volcano client performance] " .. json)
	table.clear(samples)
	sampleDuration = 0
end

task.spawn(function()
	local deadline = time() + 90
	local root: Instance? = nil
	while time() < deadline do
		root = Workspace:FindFirstChild("VolcanoExperience", true)
		if root and find(root, "DragonOffer") and find(root, "Head") then
			break
		end
		task.wait(0.2)
	end
	assert(root, "QA camera: VolcanoExperience unavailable")
	local centre = root:GetAttribute("Centre")
	assert(typeof(centre) == "Vector3", "QA camera requires authored Centre attribute")
	local offer = assert(find(root, "DragonOffer"), "QA camera requires DragonOffer frame")
	local head = assert(find(root, "Head"), "QA camera requires original dragon Head")
	local frame = CFrame.new(centre) * offer.CFrame.Rotation
	local headLocal = frame:PointToObjectSpace(head.Position)
	-- Frozen, versioned offsets. Baseline and candidate must use this SAME harness;
	-- pose JSON below exposes differing origin/head placement instead of concealing it.
	local definitions = {
		{ "approach", Vector3.new(90, 70, -175), Vector3.new(0, 35, 0) },
		{ "entrance", Vector3.new(0, 8, -12), headLocal + Vector3.new(0, -3, 0) },
		{ "audience", Vector3.new(0, 27, -33), headLocal + Vector3.new(0, 4, 0) },
		{ "lateral", Vector3.new(18, 25, -25), headLocal + Vector3.new(0, 4, 0) },
		{ "trial", Vector3.new(-15, 22, -17), Vector3.new(-32, 10, 14) },
		{ "refuge", Vector3.new(29, 8, 13), Vector3.new(38, 5, 26) },
		{ "crater", Vector3.new(45, 119, -35), Vector3.new(0, 88, 0) },
		{ "rear_exterior", Vector3.new(110, 45, 135), Vector3.new(0, 32, 35) },
	}
	snapshotContext = {
		harness = "volcano-matched-v3",
		studio = true,
		touchEnabled = UserInputService.TouchEnabled,
		keyboardEnabled = UserInputService.KeyboardEnabled,
		centre = vector(centre),
		headPosition = vector(head.Position),
		fov = 65,
		warmupSeconds = 3,
		cameraMode = "scriptable",
		characterTraversal = false,
	}
	for _, definition in definitions do
		local view = {
			name = definition[1] :: string,
			eye = frame:PointToWorldSpace(definition[2] :: Vector3),
			target = frame:PointToWorldSpace(definition[3] :: Vector3),
		}
		table.insert(views, view)
		print("[Volcano camera pose] " .. HttpService:JSONEncode({
			harness = "volcano-matched-v3",
			name = view.name,
			eye = vector(view.eye),
			target = vector(view.target),
			fov = 65,
		}))
	end
	local imported = Workspace:GetAttribute("VolcanoQACameraManifest")
	if typeof(imported) == "string" and imported ~= "" then
		local manifest = HttpService:JSONDecode(imported)
		assert(
			type(manifest) == "table" and #manifest == #views,
			"Matched camera manifest must contain eight poses"
		)
		local function readVector(value: any): Vector3
			assert(type(value) == "table" and #value == 3, "Invalid camera vector")
			for _, n in value do
				assert(
					type(n) == "number" and n == n and math.abs(n) < 100000,
					"Invalid camera coordinate"
				)
			end
			return Vector3.new(value[1], value[2], value[3])
		end
		for index, entry in manifest do
			assert(entry.name == views[index].name, "Camera manifest order/name mismatch")
			views[index].eye = readVector(entry.eye)
			views[index].target = readVector(entry.target)
			assert(
				(views[index].eye - views[index].target).Magnitude > 0.1,
				"Degenerate camera pose"
			)
		end
		snapshotContext.matchedManifest = true
	else
		snapshotContext.matchedManifest = false
	end
	local exported = {}
	for _, view in views do
		table.insert(
			exported,
			{ name = view.name, eye = vector(view.eye), target = vector(view.target) }
		)
	end
	print("[Volcano matched manifest] " .. HttpService:JSONEncode(exported))
	cameraStarted = time()
end)
local digits = {
	Enum.KeyCode.One,
	Enum.KeyCode.Two,
	Enum.KeyCode.Three,
	Enum.KeyCode.Four,
	Enum.KeyCode.Five,
	Enum.KeyCode.Six,
	Enum.KeyCode.Seven,
	Enum.KeyCode.Eight,
}
local hidden = false
local savedGui: { [ScreenGui]: boolean } = {}
local promptService = game:GetService("ProximityPromptService")
local savedPromptsEnabled = promptService.Enabled
game:GetService("ContextActionService")
	:BindActionAtPriority("VolcanoQACameraKeys", function(_, inputState, input)
		if UserInputService:GetFocusedTextBox() then
			return Enum.ContextActionResult.Pass
		end
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Sink
		end
		if input.KeyCode == Enum.KeyCode.H then
			hidden = not hidden
			if hidden then
				savedPromptsEnabled = promptService.Enabled
				promptService.Enabled = false
			else
				promptService.Enabled = savedPromptsEnabled
			end
			for _, screen in player.PlayerGui:GetChildren() do
				if screen:IsA("ScreenGui") then
					if hidden then
						savedGui[screen] = screen.Enabled
						screen.Enabled = false
					else
						screen.Enabled = savedGui[screen] ~= false
					end
				end
			end
			game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.All, not hidden)
		elseif input.KeyCode == Enum.KeyCode.Zero then
			automatic = true
			cameraStarted = time()
		else
			for index, key in digits do
				if input.KeyCode == key then
					automatic = false
					selected = index
				end
			end
		end
		return Enum.ContextActionResult.Sink
	end, false, 3000, Enum.KeyCode.Zero, Enum.KeyCode.H, table.unpack(digits))
local previousView = 0
local viewSince = time()
RunService.RenderStepped:Connect(function(dt)
	local camera = Workspace.CurrentCamera
	if not camera or #views == 0 then
		return
	end
	local requested = Workspace:GetAttribute("VolcanoQACameraView")
	local autoAttribute = Workspace:GetAttribute("VolcanoQACameraAuto")
	if typeof(autoAttribute) == "boolean" then
		automatic = autoAttribute
	end
	if typeof(requested) == "number" and requested == requested then
		selected = math.clamp(math.floor(requested), 1, #views)
	end
	local index = if automatic
		then math.floor((time() - cameraStarted) / 48) % #views + 1
		else selected
	local view = views[index]
	if previousView ~= index then
		if previousView > 0 then
			report(views[previousView].name)
		end
		previousView = index
		viewSince = time()
	end
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = 65
	camera.CFrame = CFrame.lookAt(view.eye, view.target)
	if time() - viewSince >= 3 and dt > 0 and dt < math.huge then
		table.insert(samples, dt)
		sampleDuration += dt
	end
	local epoch = Workspace:GetAttribute("VolcanoEpoch")
	local elapsed = if typeof(epoch) == "number" then Workspace:GetServerTimeNow() - epoch else 0
	local phase = elapsed % 48
	local capture = if math.abs(phase - 12) < 0.5
		then "rest"
		elseif math.abs(phase - 33) < 0.5 then "exhale"
		else nil
	if capture and time() - viewSince >= 3 then
		local key = `{math.floor(elapsed / 48)}:{view.name}:{capture}`
		if not captureKeys[key] then
			captureKeys[key] = true
			print(
				`[Volcano capture ready] {Workspace:GetAttribute("VolcanoQAVariant") or "UNLABELLED"}/{view.name}/{capture} phase={string.format(
					"%.2f",
					phase
				)} harness=volcano-matched-v3`
			)
		end
	end
	label.Text =
		`{Workspace:GetAttribute("VolcanoQAVariant") or "UNLABELLED"} · {index}/8 {view.name} · {if capture
			then "CAPTURE " .. capture
			else "phase " .. string.format("%.1f", phase)} · FOV65\nSTUDIO CLIENT ONLY · 1–8 fixed view / 0 auto · {#samples} frames sampled\n{Workspace:GetAttribute(
			"VolcanoRouteQASummary"
		) or "Spatial probes pending"}`
	if sampleDuration >= 45 then
		report(view.name)
	end
end)
