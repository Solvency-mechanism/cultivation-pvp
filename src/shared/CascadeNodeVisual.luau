--!strict
-- Presentation-only selection. No node/state/config mutation and no dependency
-- on placement, cultivation, capture radius, rewards or persistence.
local CascadeNodeVisual = {}
local COMPACT = {
	common = { core = 2.0, hover = 0.2, column = 4, shards = 2, shardHeight = 2.8, rate = 3 },
	rare = { core = 2.8, hover = 0.5, column = 6, shards = 3, shardHeight = 3.4, rate = 4 },
	prime = { core = 3.6, hover = 0.8, column = 8, shards = 4, shardHeight = 4.0, rate = 5 },
}

function CascadeNodeVisual.isScoped(region: string, rootPresent: boolean): boolean
	return region == "wellspring" and rootPresent
end

function CascadeNodeVisual.select(base: any, tier: string, scoped: boolean): any
	if not scoped then
		return base
	end
	local spec = table.clone(base)
	local compact = COMPACT[tier] or COMPACT.common
	for key, value in compact do
		spec[key] = value
	end
	spec.light = 0
	spec.shaft = 0
	spec.ringTransparency = 0.96
	spec.ringBedTransparency = 1
	spec.ringEyeTransparency = 1
	spec.perimeter = true
	return spec
end

return CascadeNodeVisual
