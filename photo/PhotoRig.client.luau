--!strict
--[[
	PhotoRig: the camera is declared, not driven.

	Five sessions proved that synthetic input never reaches the Roblox Player.
	So a storefront shot is not aimed by hand; it is a row in the table below --
	a camera position and look-at, a field of view, which HUD to leave in the
	frame, which technique to fire and when, and a marker printed at the frame
	worth capturing. Every re-shoot is a rebuild, not a re-aim, and two rounds
	of "a little to the left" cost two edits to a number.

	This file lives under photo/ at the repo root, outside src/. It is built
	only by photo.project.json, which extends the default tree with this one
	script; default.project.json does not know it exists, publish-build reads
	default.project.json, and so it ships nowhere. The compile suite and the
	shared-purity check do not see it either, on purpose.

	It reuses the real game entirely: the same HUD, the same Vfx, the same
	UseTechnique remote. The technique in the frame is the technique a player
	gets, because it was fired the way a player fires it. Nothing here is
	composited, painted, or claimed.

	SELECTING A SHOT. If this script carries a string attribute `Shot`, only
	that shot runs. Otherwise every shot runs in table order, each printing its
	marker, with a gap between -- one build, every frame. photo.project.json can
	set the attribute; landscape owns that file.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

-- ===================================================================
-- Shot table. Coordinates are landscape's; composition is interface's.
-- ===================================================================

--[[ SCHEMA -- the contract between this rig and photo.project.json / the
	shot coordinates in storefront.md. Revise by edit there, then here.

	name          string   printed in the marker; the Shot attribute selects by it.
	camera        { position: Vector3, lookAt: Vector3, fov: number }
	              Scriptable camera, held every frame for the shot's duration so
	              a respawn or a Roblox camera reset cannot take it back.
	settle        number?  seconds to wait after the camera is placed before
	              anything fires. Lets the character finish loading, the HUD
	              receive its attributes, and a placed dummy exist. Default 3.
	hud           { [string]: boolean }?
	              ScreenGui name -> visible. Anything not listed keeps its
	              current state. Names today: "CultivationHud" (vitals, bar,
	              sense, guidance, notices, picker, target frame),
	              "CultivationReticle", "ImpactFeedback" (hitmarker, vignette).
	hideChildren  { string }?
	              names of direct children of CultivationHud to hide for the
	              shot: "Sense", "Guidance", "Notice", "FirstRunCard",
	              "BreakthroughPrompt", "TargetFrame", "RefinementRail",
	              "LoadoutPicker". The bottom cluster is "Cluster" (vitals,
	              cast bar, action bar together).
	coreGui       boolean? Roblox's own chat, player list, backpack. Default
	              false for every shot: none of them belong in an advert.
	lighting      { [string]: any }?
	              Lighting properties to set for this shot only -- ClockTime,
	              Brightness, ExposureCompensation, FogEnd. Restored after.
	fire          { slot: string, target: Vector3?, aim: Vector3?, delay: number?,
	                markerAfter: number }?
	              slot is a Config.LoadoutSlots name; the technique loaded in
	              it is what fires (the default loadout puts lance in striker).
	              THE AIM IS FROM THE CHARACTER, NOT THE CAMERA. The server
	              raycasts from the character's root along the vector it is
	              sent, and a photo camera sits somewhere else entirely -- so a
	              ray along the camera's look would leave the character
	              parallel to it and miss the thing the camera is looking at.
	              Give `target`, a world point (the dummy), and the rig aims
	              from the root at it. `aim` overrides with a raw vector if you
	              want one; the camera's look is the last resort and is only
	              right when the camera is on the character's shoulder.
	              delay is seconds after settle before the press; markerAfter
	              is seconds after the press at which the marker prints -- tune
	              it to the technique: a lance impact's flash lasts 0.14s after
	              a 0.28s windup, so ~0.36 catches the core with the shards
	              still out.
	hold          number?  seconds to keep the frame after the marker before
	              the next shot. Default 4.
]]

type Shot = {
	name: string,
	camera: { position: Vector3, lookAt: Vector3, fov: number },
	settle: number?,
	hud: { [string]: boolean }?,
	hideChildren: { string }?,
	coreGui: boolean?,
	lighting: { [string]: any }?,
	fire: {
		slot: string,
		target: Vector3?,
		aim: Vector3?,
		delay: number?,
		markerAfter: number,
	}?,
	hold: number?,
}

--[[ Placeholder coordinates. Landscape replaces these with the three frames
	it names in storefront.md; the shapes are what matter here. ]]
local SHOTS: { Shot } = {
	{
		--[[ THUMBNAIL. HUD in, partially: vitals and the five-slot bar are a
			truthful advert for what the game is; the sense panel, guidance and
			chat are for playing, not looking. A technique mid-moment, not a
			pose. ]]
		name = "thumbnail",
		camera = {
			position = Vector3.new(-18, 9, -84),
			lookAt = Vector3.new(0, 4, -60),
			fov = 62,
		},
		settle = 3,
		hud = { CultivationHud = true, CultivationReticle = false, ImpactFeedback = true },
		hideChildren = {
			"Sense",
			"Guidance",
			"Notice",
			"FirstRunCard",
			"TargetFrame",
			"LoadoutPicker",
		},
		coreGui = false,
		fire = {
			slot = "striker",
			target = Vector3.new(0, 4, -60),
			delay = 0.5,
			markerAfter = 0.36,
		},
		hold = 4,
	},
	{
		--[[ ICON. HUD out entirely. One strong shape, one strong colour,
			readable at 64px: a gold Prime node, or one landed impact's white
			core against near-black dust, per ImpactSpec's two-material rule.
			Composed for SQUARE -- landscape crops the centre, not the
			thumbnail squeezed. ]]
		name = "icon",
		camera = {
			position = Vector3.new(8, 6, -70),
			lookAt = Vector3.new(0, 4, -60),
			fov = 50,
		},
		settle = 3,
		hud = { CultivationHud = false, CultivationReticle = false, ImpactFeedback = false },
		coreGui = false,
		fire = {
			slot = "striker",
			target = Vector3.new(0, 4, -60),
			delay = 0.5,
			markerAfter = 0.36,
		},
		hold = 4,
	},
}

-- ===================================================================
-- Rig.
-- ===================================================================

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local useTechnique = remotes:WaitForChild("UseTechnique") :: RemoteEvent

local function log(message: string)
	print(`[photo] {message}`)
end

local function playerGui(): PlayerGui
	return player:WaitForChild("PlayerGui") :: PlayerGui
end

--[[ Hold the camera every frame rather than setting it once. Roblox's own
	camera scripts write CFrame on RenderStepped while the type is not
	Scriptable, and a respawn or a focus change can flip the type back; holding
	it makes the shot survive both. The connection is dropped when the shot
	ends. ]]
local function holdCamera(shot: Shot): RBXScriptConnection
	local cf = CFrame.lookAt(shot.camera.position, shot.camera.lookAt)
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = cf
	camera.FieldOfView = shot.camera.fov
	return RunService.RenderStepped:Connect(function()
		if camera.CameraType ~= Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Scriptable
		end
		camera.CFrame = cf
		camera.FieldOfView = shot.camera.fov
	end)
end

local function setCoreGui(visible: boolean)
	for _, kind in
		{
			Enum.CoreGuiType.Chat,
			Enum.CoreGuiType.PlayerList,
			Enum.CoreGuiType.Backpack,
			Enum.CoreGuiType.EmotesMenu,
			Enum.CoreGuiType.Health,
		}
	do
		pcall(function()
			StarterGui:SetCoreGuiEnabled(kind, visible)
		end)
	end
end

local function applyHud(shot: Shot)
	local gui = playerGui()
	if shot.hud then
		for name, visible in shot.hud do
			local screen = gui:FindFirstChild(name)
			if screen and screen:IsA("ScreenGui") then
				screen.Enabled = visible
			else
				log(`hud: no ScreenGui named {name}`)
			end
		end
	end
	if shot.hideChildren then
		local hud = gui:FindFirstChild("CultivationHud")
		if hud then
			for _, childName in shot.hideChildren do
				local child = hud:FindFirstChild(childName)
				if child and child:IsA("GuiObject") then
					child.Visible = false
				else
					log(`hideChildren: no child named {childName} under CultivationHud`)
				end
			end
		end
	end
	setCoreGui(shot.coreGui == true)
end

--[[ Lighting is overridden for the shot and put back after, so a shot's
	golden hour never leaks into the next shot or into anything landscape
	pinned in ArenaService. ]]
local function applyLighting(shot: Shot): () -> ()
	local saved: { [string]: any } = {}
	if shot.lighting then
		for property, value in shot.lighting do
			local ok, current = pcall(function()
				return (Lighting :: any)[property]
			end)
			if ok then
				saved[property] = current
				pcall(function()
					(Lighting :: any)[property] = value
				end)
			else
				log(`lighting: no property {property}`)
			end
		end
	end
	return function()
		for property, value in saved do
			pcall(function()
				(Lighting :: any)[property] = value
			end)
		end
	end
end

local function fire(shot: Shot)
	local spec = shot.fire
	if not spec then
		return
	end
	task.wait(spec.delay or 0)
	local aim: Vector3
	if spec.aim then
		aim = spec.aim
	elseif spec.target then
		local character = player.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if root and root:IsA("BasePart") then
			aim = (spec.target - root.Position).Unit
		else
			log(`{shot.name}: no root to aim from; using camera look`)
			aim = camera.CFrame.LookVector
		end
	else
		aim = camera.CFrame.LookVector
	end
	-- The real path, with the real remote, the same two things a keypress
	-- sends. The server owns everything after this line.
	useTechnique:FireServer(spec.slot, aim)
	log(`{shot.name}: fired {spec.slot}`)
	task.wait(spec.markerAfter)
end

local function runShot(shot: Shot)
	log(`{shot.name}: placing camera`)
	local release = holdCamera(shot)
	local restoreLighting = applyLighting(shot)
	applyHud(shot)

	task.wait(shot.settle or 3)
	fire(shot)

	-- The frame to capture. Landscape's capture is timed to this line.
	log(`{shot.name} ready`)

	task.wait(shot.hold or 4)
	release:Disconnect()
	restoreLighting()
end

local function selected(): { Shot }
	local wanted = script:GetAttribute("Shot")
	if typeof(wanted) == "string" then
		for _, shot in SHOTS do
			if shot.name == wanted then
				return { shot }
			end
		end
		log(`no shot named {wanted}; running all`)
	end
	return SHOTS
end

task.spawn(function()
	-- Wait for a character, so the HUD exists to be hidden and the technique
	-- has a caster to fire from.
	if not player.Character then
		player.CharacterAdded:Wait()
	end
	task.wait(1)
	for _, shot in selected() do
		runShot(shot)
	end
	log("done")
end)
