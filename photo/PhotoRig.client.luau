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
local TextChatService = game:GetService("TextChatService")
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
	character     Vector3? place the character's root here, BEFORE the settle,
	              facing fire.target if there is one and camera.lookAt otherwise.
	              Without this the character stands where it spawned -- the
	              22-stud deck at z = -136, the exact surface the brief says not
	              to photograph -- and every impact could only happen there.
	              A LocalScript may set its own root's CFrame; the client owns
	              its character, and the move replicates well inside a settle.
	dummy         string?  the /dummy argument line -- "stationary lowgold ahead"
	              -- sent by the rig itself through TextChatService after the
	              character is placed, so "ahead" is ahead of where the shot
	              wants and the manual chat step and its replication race go
	              away. Omit for a shot with no target.
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
	              lockId: for a lock technique (Frostbolt, Rime Verdict,
	              Hoarfrost), the target's CombatantId -- the third argument
	              UseTechnique takes, which the server refuses no_target
	              without. A dummy's is the negative CombatantId attribute on
	              its Model; read it off the placed dummy and put it here. Lance
	              and the aim variations need nothing.
	hold          number?  seconds to keep the frame after the marker before
	              the next shot. Default 4.
]]

--[[ The three frames landscape named in storefront.md; coordinates are
	first-round. Order matters when no Shot attribute selects one: both
	thumbnails run first so the aura nodes get two holds to cycle before the
	icon frame, which wants a gold Prime in the Wellspring and is the only
	shot that does not fire. Axes: +z north toward the Wellspring, -x west
	(Verdant Reach), +x east (Ember Barrens); ground is y ~ 0.2. ]]
--[[ The shots live in Shots.luau, landscape's file, so the two leads never
	edit one file: the rig owns the mechanics, the table owns the frames. ]]
local Shots = require(script.Parent:WaitForChild("Shots"))
type Shot = Shots.Shot
local SHOTS: { Shot } = Shots

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

--[[ Stand the character where the shot wants it, facing what it will fire at.
	Done before the settle so the move has replicated by the time anything
	else looks. Facing the fire target rather than the camera's subject when
	both exist, because "ahead" -- where a summoned dummy lands -- has to be
	where the aim is going, and those two rays only sometimes agree. ]]
local function placeCharacter(shot: Shot)
	local at = shot.character
	if not at then
		return
	end
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if not root or not root:IsA("BasePart") then
		log(`{shot.name}: no root to place`)
		return
	end
	local facing = if shot.fire and shot.fire.target then shot.fire.target else shot.camera.lookAt
	-- Level the look so the character does not pitch; roots are upright.
	local flat = Vector3.new(facing.X, at.Y, facing.Z)
	if (flat - at).Magnitude < 1e-3 then
		flat = at + Vector3.new(0, 0, 1)
	end
	root.CFrame = CFrame.lookAt(at, flat)
	log(`{shot.name}: character at {at}`)
end

--[[ Send the /dummy line through TextChatService, which is what a person
	typing it does -- the server's TextChatCommand fires on it exactly as it
	would on a keyboard. Sent after the character is placed, so "ahead" means
	ahead of the shot's character and not of the spawn deck. ]]
local function summonDummy(shot: Shot)
	local line = shot.dummy
	if not line then
		return
	end
	local channel = TextChatService:FindFirstChild("TextChannels")
	local general = if channel then channel:FindFirstChild("RBXGeneral") else nil
	if not general or not general:IsA("TextChannel") then
		log(`{shot.name}: no RBXGeneral channel; place the dummy by hand`)
		return
	end
	local ok, err = pcall(function()
		general:SendAsync(`/dummy {line}`)
	end)
	if ok then
		log(`{shot.name}: sent /dummy {line}`)
	else
		log(`{shot.name}: /dummy failed: {err}`)
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
	-- The real path, with the real remote, the same things a keypress sends:
	-- slot, aim, and the lock id when the technique needs one. The server owns
	-- everything after this line.
	useTechnique:FireServer(spec.slot, aim, spec.lockId)
	log(`{shot.name}: fired {spec.slot}`)
	task.wait(spec.markerAfter)
end

local function runShot(shot: Shot)
	log(`{shot.name}: placing camera`)
	local release = holdCamera(shot)
	local restoreLighting = applyLighting(shot)
	applyHud(shot)
	placeCharacter(shot)
	summonDummy(shot)

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
