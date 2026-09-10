--!strict
--[[
	What a cultivator looks like to everyone else.

	The pitch is that advancement is public and contested. Until now it was
	private: two players in the same field were identical default avatars, and
	the one fact that decides whether you can even fight someone -- their stage,
	because brackets never mix -- was invisible.

	So stage is worn. Colour and aura density come from the ladder position, and
	the nameplate says the stage outright, because guessing wrong costs a fight
	you were never allowed to have.

	Presentation only. Nothing here is read back by any rule.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Progression = require(ReplicatedStorage.Shared.Progression)
local CultivationService = require(script.Parent.CultivationService)

local PresenceService = {}

--[[ The ladder read as colour. Proving-ground stages are dim and metallic; the
	Gold brackets are where the real game is and they glow. The jump from Jade to
	Lowgold is deliberately the largest step in the palette, because it is the
	largest step in the game. ]]
local STAGE_COLOR: { Color3 } = {
	Color3.fromRGB(126, 132, 148), -- foundation
	Color3.fromRGB(184, 115, 74), -- copper
	Color3.fromRGB(150, 160, 176), -- iron
	Color3.fromRGB(96, 196, 150), -- jade
	Color3.fromRGB(240, 196, 96), -- lowgold
	Color3.fromRGB(252, 168, 58), -- highgold
	Color3.fromRGB(255, 244, 168), -- truegold
}

local AURA_NAME = "CultivatorAura"
local PLATE_NAME = "CultivatorPlate"

--[[ Roblox's player list renders a folder literally named "leaderstats"
	holding IntValue/StringValue children, and nothing else -- no UI to build,
	no remote, no client code. "Advancement is public and contested" was true
	of a single opponent standing in front of you and false of the rest of the
	server: four friends in one place had no shared frame of reference for who
	was ahead. Kills first (the social one -- what makes four friends talk to
	each other), then Stage (the one fact that decides whether two players can
	even fight), then Tier (progression within the bracket). ]]
local LEADERSTATS_NAME = "leaderstats"
local KILLS_STAT = "Kills"
local STAGE_STAT = "Stage"
local TIER_STAT = "Tier"

local shown: { [number]: number } = {}
local kills: { [number]: number } = {}

local function stageColor(stageIndex: number): Color3
	return STAGE_COLOR[stageIndex] or STAGE_COLOR[#STAGE_COLOR]
end

local function clearPresence(character: Model)
	local existing = character:FindFirstChild(AURA_NAME, true)
	while existing do
		existing:Destroy()
		existing = character:FindFirstChild(AURA_NAME, true)
	end
	local plate = character:FindFirstChild(PLATE_NAME, true)
	if plate then
		plate:Destroy()
	end
end

local function buildPlate(head: BasePart, stageName: string, tier: number, color: Color3)
	local plate = Instance.new("BillboardGui")
	plate.Name = PLATE_NAME
	plate.Size = UDim2.fromOffset(190, 30)
	plate.StudsOffsetWorldSpace = Vector3.new(0, 2.6, 0)
	plate.AlwaysOnTop = false
	-- Visible from across the field, because knowing someone's bracket before
	-- you commit is the point.
	plate.MaxDistance = 260
	plate.Parent = head

	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamBold
	text.TextSize = 15
	text.TextColor3 = color
	text.TextStrokeTransparency = 0.25
	text.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	text.Text = `{stageName}  ·  {tier}`
	text.Parent = plate
end

local function buildAura(root: BasePart, stageIndex: number, tier: number, color: Color3)
	local highlight = Instance.new("Highlight")
	highlight.Name = AURA_NAME
	highlight.FillColor = color
	highlight.OutlineColor = color
	-- Fill stays faint. A solid silhouette would read as a targeting marker
	-- rather than as power the character is carrying.
	highlight.FillTransparency = 0.86
	highlight.OutlineTransparency = 0.35
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = root

	local attachment = Instance.new("Attachment")
	attachment.Name = AURA_NAME
	attachment.Position = Vector3.new(0, -2.6, 0)
	attachment.Parent = root

	--[[ Refinement is the continuous axis inside a stage, so it shows as
		density rather than colour: within a bracket everyone reads as the same
		rank, and the veteran simply burns harder. ]]
	local depth = (tier - 1) / math.max(Config.RefinementTiers - 1, 1)

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = AURA_NAME
	emitter.Color = ColorSequence.new(color)
	emitter.LightEmission = 0.75
	emitter.LightInfluence = 0
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5 + depth * 0.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.6, 1.1)
	emitter.Speed = NumberRange.new(2.5 + depth * 3, 4 + depth * 4)
	emitter.SpreadAngle = Vector2.new(14, 14)
	-- Kept low on purpose. This runs on every player in the field at once, and
	-- a per-character particle storm is the cheapest way to make a busy fight
	-- unreadable and the framerate worse.
	emitter.Rate = 5 + math.floor(depth * 13) + stageIndex
	emitter.Acceleration = Vector3.new(0, 7, 0)
	emitter.Parent = attachment
end

--[[ Idempotent -- safe to call every time a player's presence is touched, not
	just at join, so a leaderstats folder that failed to build once (or never
	got the chance, if this service's own start was fault-isolated away) has
	another chance to exist the next time anyone looks at this player. ]]
local function ensureLeaderstats(player: Player): Folder
	local existing = player:FindFirstChild(LEADERSTATS_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = LEADERSTATS_NAME

	local killsValue = Instance.new("IntValue")
	killsValue.Name = KILLS_STAT
	killsValue.Value = kills[player.UserId] or 0
	killsValue.Parent = folder

	local stageValue = Instance.new("StringValue")
	stageValue.Name = STAGE_STAT
	stageValue.Parent = folder

	local tierValue = Instance.new("IntValue")
	tierValue.Name = TIER_STAT
	tierValue.Parent = folder

	folder.Parent = player
	return folder
end

local function updateLeaderstats(player: Player, state: Progression.State)
	local folder = ensureLeaderstats(player)
	local stage = Progression.getStage(Config, state)
	local stageValue = folder:FindFirstChild(STAGE_STAT)
	if stageValue and stageValue:IsA("StringValue") then
		stageValue.Value = stage.name
	end
	local tierValue = folder:FindFirstChild(TIER_STAT)
	if tierValue and tierValue:IsA("IntValue") then
		tierValue.Value = state.tier
	end
end

--[[ Wired from CombatService's injected kill handler in init.server.luau --
	see this file's header for why PresenceService does not require
	CombatService to learn this happened. ]]
function PresenceService.recordKill(player: Player)
	local total = (kills[player.UserId] or 0) + 1
	kills[player.UserId] = total
	local folder = ensureLeaderstats(player)
	local killsValue = folder:FindFirstChild(KILLS_STAT)
	if killsValue and killsValue:IsA("IntValue") then
		killsValue.Value = total
	end
end

local function apply(player: Player)
	local state = CultivationService.getState(player)
	local character = player.Character
	if not state or not character then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	local head = character:FindFirstChild("Head")
	if not root or not root:IsA("BasePart") or not head or not head:IsA("BasePart") then
		return
	end

	clearPresence(character)

	local stage = Progression.getStage(Config, state)
	local color = stageColor(state.stageIndex)
	buildAura(root, state.stageIndex, state.tier, color)
	buildPlate(head, stage.name, state.tier, color)
	updateLeaderstats(player, state)

	-- Packed so one comparison catches either axis changing.
	shown[player.UserId] = state.stageIndex * 1000 + state.tier
end

function PresenceService.onPlayerAdded(player: Player)
	ensureLeaderstats(player)
	local state = CultivationService.getState(player)
	if state then
		updateLeaderstats(player, state)
	end
	player.CharacterAppearanceLoaded:Connect(function()
		shown[player.UserId] = nil
	end)
end

function PresenceService.onPlayerRemoving(player: Player)
	shown[player.UserId] = nil
	kills[player.UserId] = nil
end

--[[ Polled rather than pushed, for the same reason CombatService polls: it
	keeps CultivationService from having to know this service exists. Rebuilding
	only on an actual change keeps it to a comparison per player per tick. ]]
function PresenceService.tick()
	for _, player in Players:GetPlayers() do
		local state = CultivationService.getState(player)
		if not state then
			continue
		end
		local signature = state.stageIndex * 1000 + state.tier
		local character = player.Character
		local wornPlate = if character then character:FindFirstChild(PLATE_NAME, true) else nil
		if shown[player.UserId] ~= signature or not wornPlate then
			apply(player)
		end
	end
end

return PresenceService
