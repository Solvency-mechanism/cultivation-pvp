--!strict
--[[
	Technique presentation.

	The server broadcasts a resolved technique over the TechniqueFired remote and
	this draws it. Presentation only: damage is already applied by the time this
	runs, so nothing here decides an outcome and a client that ignores it changes
	nothing but its own screen.

	Payload shape:
		techId   string   -- key into Config.Techniques
		kind     string   -- striker | enforcer | forger | ruler
		casterId number   -- Player.UserId of the caster
		origin   Vector3  -- where the technique came from
		target   Vector3? -- where a striker landed; nil for area kinds
		hit      boolean  -- whether it connected
]]

local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")

local Vfx = {}

export type Shot = {
	techId: string,
	kind: string,
	casterId: number,
	origin: Vector3,
	target: Vector3?,
	hit: boolean,
}

--[[ Placeholder. A single line so the remote is provably wired end to end;
	everything about how a technique reads is still to be built. ]]
function Vfx.play(shot: Shot)
	if shot.kind ~= "striker" or not shot.target then
		return
	end

	local origin = shot.origin
	local target = shot.target
	local beam = Instance.new("Part")
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.CanTouch = false
	beam.Material = Enum.Material.Neon
	beam.Color = if shot.hit then Color3.fromRGB(255, 180, 120) else Color3.fromRGB(150, 170, 210)
	beam.Size = Vector3.new(0.4, 0.4, (target - origin).Magnitude)
	beam.CFrame = CFrame.lookAt(origin:Lerp(target, 0.5), target)
	beam.Parent = Workspace
	Debris:AddItem(beam, 0.12)
end

return Vfx
