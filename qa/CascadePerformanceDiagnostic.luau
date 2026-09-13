-- QA-only paste into Studio CLIENT command bar. No production mapping.
task.spawn(function()
	local rs = game:GetService("RunService")
	assert(rs:IsStudio() and rs:IsClient(), "Studio client only")
	local camera = workspace.CurrentCamera
	local root = assert(workspace:FindFirstChild("PorcelainCascade", true), "Cascade missing")
	local centre = root:GetAttribute("Centre")
	local saved = { camera.CameraType, camera.CFrame, camera.FieldOfView }
	local frames, cpu, gpu = {}, {}, {}
	local stats = game:GetService("Stats")
	local connection
	local function average(values)
		local sum = 0
		for _, v in values do
			sum += v
		end
		return if #values > 0 then sum / #values else 0
	end
	local function percentile(values, fraction)
		table.sort(values)
		return values[math.max(1, math.ceil(#values * fraction))] or 0
	end
	local ok, err = pcall(function()
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame =
			CFrame.lookAt(centre + Vector3.new(0, 14, -76), centre + Vector3.new(0, 22, 3))
		camera.FieldOfView = 65
		task.wait(3)
		local viewport = camera.ViewportSize
		connection = rs.RenderStepped:Connect(function(dt)
			table.insert(frames, dt * 1000)
		end)
		for _ = 1, 48 do
			task.wait(1)
			local readable, c, g = pcall(function()
				return stats.RenderCPUFrameTime * 1000, stats.RenderGPUFrameTime * 1000
			end)
			if readable then
				table.insert(cpu, c)
				table.insert(gpu, g)
			end
		end
		connection:Disconnect()
		connection = nil
		local over = 0
		for _, dt in frames do
			if dt > 33 then
				over += 1
			end
		end
		local report = {
			frames = #frames,
			meanFps = 1000 / average(frames),
			p50Ms = percentile(frames, 0.5),
			p95Ms = percentile(frames, 0.95),
			p99Ms = percentile(frames, 0.99),
			over33Fraction = over / #frames,
			cpuMeanMs = average(cpu),
			gpuMeanMs = average(gpu),
			statsSamples = #gpu,
			viewport = { viewport.X, viewport.Y },
			viewportStable = viewport == camera.ViewportSize,
			fov = 65,
			evidence = "Single 48s Studio sample, not 60FPS certification or physical-device acceptance",
		}
		print("[Cascade performance] " .. game:GetService("HttpService"):JSONEncode(report))
	end)
	if connection then
		connection:Disconnect()
	end
	camera.CameraType = saved[1]
	camera.CFrame = saved[2]
	camera.FieldOfView = saved[3]
	print(
		"[Cascade performance complete] "
			.. tostring(ok)
			.. "; camera restored and callback disconnected; "
			.. tostring(err or "")
	)
end)
