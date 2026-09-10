--!strict
--[[
	Ensures the place has ground and a spawn.

	The project tree deliberately does not ship a Workspace full of parts, so a
	place built straight from `rojo build` would otherwise drop the player into
	the void. This builds the minimum needed to stand somewhere, and skips
	anything the place already provides -- connecting Rojo to a Studio Baseplate
	place is the common case, and duplicating its ground would z-fight.

	Placeholder geometry. A real map replaces this and should seed node
	placement from tagged anchors so static aura geography means something.
]]

local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local ArenaService = {}

local GROUND_NAME = "ArenaGround"
local GROUND_THICKNESS = 8

local function hasGround(): boolean
	for _, child in Workspace:GetChildren() do
		if child:IsA("BasePart") and (child.Name == "Baseplate" or child.Name == GROUND_NAME) then
			return true
		end
	end
	return false
end

local function hasSpawn(): boolean
	return Workspace:FindFirstChildWhichIsA("SpawnLocation", true) ~= nil
end

--[[ Wide enough that the whole node field is standable. NodeService places
	nodes within a 220-stud radius of the origin, so ground has to reach past
	that or Prime nodes will spawn over open air. ]]
local function groundSize(): number
	return 220 * 2 + 260
end

local function buildGround()
	local ground = Instance.new("Part")
	ground.Name = GROUND_NAME
	ground.Anchored = true
	ground.Size = Vector3.new(groundSize(), GROUND_THICKNESS, groundSize())
	ground.Position = Vector3.new(0, -GROUND_THICKNESS / 2, 0)
	ground.Material = Enum.Material.Slate
	ground.Color = Color3.fromRGB(58, 60, 68)
	ground.TopSurface = Enum.SurfaceType.Smooth
	ground.BottomSurface = Enum.SurfaceType.Smooth
	ground.Parent = Workspace
end

local function buildSpawn()
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "ArenaSpawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(24, 1, 24)
	spawn.Position = Vector3.new(0, 0.5, 0)
	spawn.Material = Enum.Material.Neon
	spawn.Color = Color3.fromRGB(255, 205, 110)
	spawn.Neutral = true
	-- No spawn forcefield. PvP is the game; an invulnerability window at the
	-- one place everyone returns to would make the spawn a safe grind.
	spawn.Duration = 0
	spawn.Parent = Workspace
end

function ArenaService.start()
	if not hasGround() then
		buildGround()
	end
	if not hasSpawn() then
		buildSpawn()
	end

	-- Falling off a 700-stud plate should not be a silent, permanent loss of the
	-- character; the void kills, the death handler charges for it, and respawn
	-- puts you back on the pad.
	Workspace.FallenPartsDestroyHeight = -120

	print(`[arena] ready -- {#Config.Stages} stages, ground {groundSize()} studs`)
end

return ArenaService
