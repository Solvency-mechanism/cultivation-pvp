-- QA-only: paste into Studio CLIENT command bar; intentionally unmapped.
-- The caller must stop other camera diagnostics before running this one.
task.spawn(function()
	assert(
		game:GetService("RunService"):IsStudio() and game:GetService("RunService"):IsClient(),
		"Studio client only"
	)
	local camera = assert(workspace.CurrentCamera, "Camera missing")
	local saved = { kind = camera.CameraType, frame = camera.CFrame, fov = camera.FieldOfView }
	local result = { diagnostic = "cascade-visual", checks = {}, failures = {} }
	local function check(name, condition)
		result.checks[name] = condition
		if not condition then
			table.insert(result.failures, name)
		end
	end
	local ok, err = pcall(function()
		local root = assert(workspace:FindFirstChild("PorcelainCascade", true), "Cascade missing")
		local centre = root:GetAttribute("Centre")
		assert(typeof(centre) == "Vector3", "Centre missing")
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame =
			CFrame.lookAt(centre + Vector3.new(0, 20, -55), centre + Vector3.new(0, 20, 15))
		task.wait(1.2)
		local parts, emitters, poses = {}, {}, {}
		local rate = 0
		for _, object in root:GetDescendants() do
			if
				object:IsA("BasePart")
				and (object.Name == "CascadeFlowHighlight" or object.Name == "CascadeImpactFoam")
			then
				table.insert(parts, object)
				poses[object] = object.CFrame
			elseif object:IsA("ParticleEmitter") and object.Name == "ImpactSpray" then
				table.insert(emitters, object)
				rate += object.Rate
			end
		end
		result.parts = #parts
		result.emitters = #emitters
		result.rate = rate
		check("boundedLocalParts", #parts > 0 and #parts <= 24)
		check("fourSprayEmitters", #emitters == 4)
		check("sprayRate24", rate == 24)
		local nearEnabled = true
		for _, emitter in emitters do
			nearEnabled = nearEnabled and emitter.Enabled
		end
		check("nearEnabled", #emitters > 0 and nearEnabled)
		task.wait(0.2)
		local moved = 0
		for _, part in parts do
			if part.CFrame ~= poses[part] then
				moved += 1
			end
		end
		result.moved = moved
		check("actualTransformsChange", moved > 0)
		camera.CFrame = CFrame.new(centre + Vector3.new(0, 30, -350))
		task.wait(1.2)
		local disabled, hidden = true, true
		for _, emitter in emitters do
			disabled = disabled and not emitter.Enabled
		end
		for _, part in parts do
			hidden = hidden and part.Transparency == 1
		end
		check("farEmittersDisabled", disabled)
		check("farPartsHidden", hidden)
		camera.CFrame = CFrame.lookAt(centre + Vector3.new(0, 20, -55), centre)
		task.wait(1.2)
		local resumed, visible = true, false
		for _, emitter in emitters do
			resumed = resumed and emitter.Enabled
		end
		for _, part in parts do
			visible = visible or part.Transparency < 1
		end
		check("nearResumes", resumed and visible)
		local nodes = assert(workspace:FindFirstChild("AuraNodes"), "AuraNodes missing")
		local wells, other, stylesCorrect = 0, 0, true
		for _, node in nodes:GetChildren() do
			local region = node:GetAttribute("Region")
			if region ~= nil then
				local expected = if region == "wellspring" then "cascade_compact" else "field"
				stylesCorrect = stylesCorrect and node:GetAttribute("VisualStyle") == expected
				if region == "wellspring" then
					wells += 1
				else
					other += 1
				end
			end
		end
		result.wellspringNodes = wells
		result.otherNodes = other
		check("nodeStylesCorrect", stylesCorrect)
		check("bothScopesObserved", wells > 0 and other > 0)
	end)
	camera.CameraType = saved.kind
	camera.CFrame = saved.frame
	camera.FieldOfView = saved.fov
	result.ok = ok and #result.failures == 0
	if not ok then
		result.error = tostring(err)
	end
	print("[cascade-visual] " .. game:GetService("HttpService"):JSONEncode(result))
end)
