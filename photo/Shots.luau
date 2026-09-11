--!strict
--[[
	The storefront shots: where the camera stands, what it looks at, what fires.

	LANDSCAPE'S FILE. The rig (PhotoRig.client.luau, interface's) reads this
	table and does the mechanics; this file holds only the coordinates,
	lighting and composition per shot, so the two leads never edit the same
	file. The schema is in .agent-reports/storefront.md and is the contract;
	the `Shot` type below is its Luau form and moves with the rig if the rig's
	needs change -- by a ping first.

	Run order is table order. A string attribute `Shot` on the rig script
	selects one by name.
]]

export type Shot = {
	name: string,
	camera: { position: Vector3, lookAt: Vector3, fov: number },
	character: Vector3?,
	dummy: string?,
	settle: number?,
	hud: { [string]: boolean }?,
	hideChildren: { string }?,
	coreGui: boolean?,
	lighting: { [string]: any }?,
	fire: {
		slot: string,
		target: Vector3?,
		aim: Vector3?,
		lockId: number?,
		delay: number?,
		markerAfter: number,
	}?,
	hold: number?,
}

local SHOTS: { Shot } = {
	{
		--[[ THUMBNAIL, recommended. The two regions face each other across
			the corridor south of the plaza: the character stands on the
			Reach's grass firing EAST at the Barrens, the camera west and
			above so the afternoon sun is behind the lens -- green front-lit,
			basalt and embers dark, the flash between them. Nothing in the
			frame is the spawn. ]]
		name = "reach-against-barrens",
		camera = {
			position = Vector3.new(-92, 15, -98),
			lookAt = Vector3.new(-30, 5, -110),
			fov = 66,
		},
		character = Vector3.new(-58, 3, -108),
		dummy = "stationary lowgold ahead",
		settle = 3,
		hud = { CultivationHud = true, CultivationReticle = false, ImpactFeedback = true },
		hideChildren = {
			"Sense",
			"Guidance",
			"Notice",
			"FirstRunCard",
			"BreakthroughPrompt",
			"TargetFrame",
			"RefinementRail",
			"LoadoutPicker",
		},
		coreGui = false,
		lighting = { ClockTime = 16.0 },
		fire = {
			slot = "striker",
			target = Vector3.new(-53, 4, -108),
			delay = 0.5,
			markerAfter = 0.36,
		},
		hold = 4,
	},
	{
		--[[ THUMBNAIL, alternate: the crossroads pillars with a cast. The
			character stands on the plaza's south edge firing north so the
			flash lands at the monument's foot with the gold crown directly
			above it, the two region waymarks framing left and right, the
			compass spokes leading in, and the Wellspring spire on the same
			axis 172 studs beyond. ]]
		name = "crossroads-cast",
		camera = {
			position = Vector3.new(-22, 7, -62),
			lookAt = Vector3.new(0, 12, -20),
			fov = 64,
		},
		character = Vector3.new(0, 3, -34),
		dummy = "stationary lowgold ahead",
		settle = 3,
		hud = { CultivationHud = true, CultivationReticle = false, ImpactFeedback = true },
		hideChildren = {
			"Sense",
			"Guidance",
			"Notice",
			"FirstRunCard",
			"BreakthroughPrompt",
			"TargetFrame",
			"RefinementRail",
			"LoadoutPicker",
		},
		coreGui = false,
		lighting = { ClockTime = 15.4 },
		fire = {
			slot = "striker",
			target = Vector3.new(0, 4, -29),
			delay = 0.5,
			markerAfter = 0.36,
		},
		hold = 4,
	},
	{
		--[[ ICON. HUD out entirely; composed for the CENTRE SQUARE of the
			16:9 frame -- landscape crops that square, never the thumbnail
			squeezed. The Wellspring heart at (0, 0, 172): the spire rising
			through the square, the neon pool at its foot, a node in the lower
			third. Dusk, so the cyan pool and rim and a gold Prime are the
			only saturated light. No fire: the subject is the node. The Prime
			is RNG; shoot on a round where the node in frame is gold, two
			rounds max, then the CrossroadsCrown is the deterministic
			fallback (camera (-14, 30, -40) -> (0, 40, 0), fov 40). ]]
		name = "wellspring-prime",
		camera = {
			position = Vector3.new(-24, 9, 138),
			lookAt = Vector3.new(0, 14, 172),
			fov = 50,
		},
		settle = 3,
		hud = { CultivationHud = false, CultivationReticle = false, ImpactFeedback = false },
		coreGui = false,
		lighting = { ClockTime = 18.3, Brightness = 1.6, ExposureCompensation = 0.15 },
		hold = 6,
	},
}

return SHOTS
