--!strict
--[[
	Nameplates: what another cultivator looks like from across a fight.

	Name, stage and tier, a health bar, and a cast bar, floating over every other
	player's head. Client-side, presentation-only, and reading nothing but
	replicated attributes -- `Health`, `MaxHealth`, `Stage`, `Tier` -- which the
	server already publishes for every player and which therefore already reach
	every client at no cost. No new protocol, no server round trip, nothing this
	module can get wrong that reaches anyone else's machine.

	**Why these are built here rather than in PresenceService.** That service
	already floats a stage plate, and it is right to: stage is slow-changing
	state and rebuilding a billboard on change is cheap. Health and a cast bar
	are not slow-changing -- they want a per-frame redraw -- and a server pushing
	that at every player for every other player is exactly the kind of traffic a
	nameplate must never cost. So the plate moves client-side and PresenceService
	keeps the aura, which is genuinely server state.

	The server plate is *disabled* rather than removed when this module takes
	over. If anything in here throws, the original plate is one property away
	from coming back, and a player still knows who they are looking at.

	**Why nameplates matter more here than in the game this register comes from.**
	There is no tab-target. Nameplates are the only way to read the other three
	people in a node fight rather than just whoever is under your reticle.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local InterfaceSpec =
	require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("InterfaceSpec"))

local Nameplates = {}

local player = Players.LocalPlayer

local PLATE_NAME = "HudNameplate"
--[[ The tag CombatService puts on anything that can be fought, agreed with it
	directly rather than inferred. A dummy carries the same `Health`, `MaxHealth`,
	`StageIndex` and `Stage` attributes a player does, on the Model instead of on
	the Player, which is what lets one read path cover both. ]]
local COMBATANT_TAG = "Combatant"
-- PresenceService's own plate, which this one supersedes.
local SERVER_PLATE_NAME = "CultivatorPlate"

local function color(rgb: InterfaceSpec.Rgb): Color3
	return Color3.fromRGB(rgb.r, rgb.g, rgb.b)
end

local PALETTE = InterfaceSpec.Palette
local PLATE = InterfaceSpec.Plate

local TROUGH = color(PALETTE.trough)
local HEALTH = color(PALETTE.health)
local HEALTH_LOW = color(PALETTE.healthLow)
local TEXT = color(PALETTE.text)
local TEXT_DIM = color(PALETTE.textDim)
local DANGER = color(PALETTE.danger)
local SLOW = color(PALETTE.slow)
local NEUTRAL = color(PALETTE.neutral)
local BLACK = Color3.new(0, 0, 0)

--[[ The cast registry.

	Owned here rather than in the HUD because the nameplate is the *primary*
	consumer -- a cast you need to react to usually belongs to someone who is not
	under your reticle. The HUD's own cast bar and the target frame both read
	back out of this same table via `Nameplates.castOf`, so there is exactly one
	record of who is casting what and no chance of the plate and the frame
	disagreeing about it.

	Keyed by UserId. Cleared when the windup elapses, and overwritten rather than
	queued if a second cast arrives -- a caster has at most one cast in flight,
	since the global cooldown outlasts every windup in the pool. ]]
export type Cast = {
	techId: string,
	kind: string,
	-- How long the bar runs: the technique's commit. castTime for a channel,
	-- windup for everything else -- the server sends one number and the
	-- client never adds two. Named for what it is, not for which field it
	-- came from.
	duration: number,
	startedAt: number,
	endsAt: number,
	--[[ Set when the cast ended early and badly -- interrupted, or completed
		but fizzled -- so a bar can draw a snap rather than a fade. To the
		player the cast produced nothing, and "finished cleanly" would be a
		lie. Held for `snapSeconds` after the end, then the record is gone. ]]
	snappedAt: number?,
}

local casts: { [number]: Cast } = {}

--[[ Started on receipt against the *client's* clock rather than from a server
	timestamp, because `os.clock` is not shared across machines. The cost is the
	one-way latency, which shortens the bar slightly -- the defender sees the
	telegraph start a few frames late and it finishes exactly when the technique
	resolves. Wrong in the direction that costs the attacker, which is the right
	direction to be wrong in. ]]
function Nameplates.noteCast(casterId: number, techId: string, kind: string, duration: number)
	local now = os.clock()
	casts[casterId] = {
		techId = techId,
		kind = kind,
		duration = duration,
		startedAt = now,
		-- Sub-floor commits still get a record, so the plate can flash even
		-- though it will not draw a bar. `flashSeconds` gives the flash
		-- somewhere to live without pretending to be a duration.
		endsAt = now + math.max(duration, InterfaceSpec.Cast.flashSeconds),
		snappedAt = nil,
	}
end

--[[ A cast ended by the server rather than by its own clock: interrupted, or
	completed. Matched on technique so a stale event for an earlier cast cannot
	end a newer one -- the same guard the movement prediction uses.

	`snapped` is true for an interrupt and for a fizzled completion. A clean
	completion just ends the record now, which for a channel that ran its full
	duration is a no-op the client would have reached on its own clock a few
	milliseconds later. ]]
function Nameplates.endCast(casterId: number, techId: string, snapped: boolean)
	local cast = casts[casterId]
	if not cast or cast.techId ~= techId then
		return
	end
	local now = os.clock()
	if snapped then
		cast.snappedAt = now
		cast.endsAt = now
	else
		casts[casterId] = nil
	end
end

function Nameplates.castOf(userId: number): Cast?
	local cast = casts[userId]
	if not cast then
		return nil
	end
	local now = os.clock()
	if cast.snappedAt then
		if now >= cast.snappedAt + InterfaceSpec.Cast.snapSeconds then
			casts[userId] = nil
			return nil
		end
		return cast
	end
	if now >= cast.endsAt + InterfaceSpec.Cast.holdSeconds then
		casts[userId] = nil
		return nil
	end
	return cast
end

-- Whether a cast record is in its snap: ended badly, still being shown as such.
function Nameplates.isSnapped(cast: Cast): boolean
	return cast.snappedAt ~= nil
end

--[[ A combatant, player or dummy, behind one shape.

	The plate does not care which it is drawing. A player's attributes live on
	the Player object and a dummy's live on its Model, so the only difference is
	*which instance to read from* -- and that is one field rather than a second
	code path. Combat made the same call server-side with its own `Combatant`
	handle, deliberately: two parallel implementations of "who is in this fight"
	would drift, and the drift would show up as a health bar that stops moving.

	`id` is the combatant id: a player's UserId, always positive, or a dummy's
	negative pseudo-id. That is why plates can be keyed by it without collision,
	and why a cast broadcast binds to the right plate whoever cast it. ]]
export type Combatant = {
	id: number,
	source: Instance,
	model: Model,
	name: string,
}

type Plate = {
	gui: BillboardGui,
	name: TextLabel,
	stage: TextLabel,
	healthFill: Frame,
	castRow: Frame,
	castFill: Frame,
	castLabel: TextLabel,
	model: Model,
	head: BasePart,
	humanoid: Humanoid?,
}

local plates: { [number]: Plate } = {}

local function stroked(text: TextLabel): TextLabel
	--[[ Plates sit over the world, not over a panel, so text here keeps the
		stroke the HUD sheds. `ImpactSpec`'s rule -- value contrast is what
		carries legibility at distance, on any ground -- applies to a nameplate
		more than to anything else in the interface. ]]
	local stroke = Instance.new("UIStroke")
	stroke.Color = BLACK
	stroke.Thickness = 2
	stroke.Transparency = 0.15
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Parent = text
	return text
end

local function buildPlate(who: Combatant, head: BasePart): Plate?
	-- The HUD's own scale, width cap included, so a plate and the pair agree.
	local viewport = if Workspace.CurrentCamera
		then Workspace.CurrentCamera.ViewportSize
		else Vector2.new(1920, 1080)
	local scale = InterfaceSpec.scale(viewport.Y, viewport.X)
	local width = math.round(PLATE.width * scale)
	local nameHeight = math.round(PLATE.nameTextSize * scale) + 4
	local healthHeight = math.round(PLATE.healthHeight * scale)
	local castHeight = math.round(PLATE.castHeight * scale)
	local gap = math.round(PLATE.rowGap * scale)
	--[[ The stage text and the cast bar share the third row and swap between
		them, so the row has to be tall enough for the *taller* of the two. Sized
		to the cast bar alone, the stage caption would spill out of the billboard
		-- which a BillboardGui will happily render, since it does not clip, so
		the bug would show up as text drifting under the plate rather than as
		anything that announces itself. ]]
	local thirdRow = math.max(castHeight, math.round(PLATE.stageTextSize * scale) + 4)
	local castTop = nameHeight + gap + healthHeight + gap
	local total = castTop + thirdRow

	local gui = Instance.new("BillboardGui")
	gui.Name = PLATE_NAME
	gui.Size = UDim2.fromOffset(width, total)
	--[[ Offset from the top of the anchor rather than a flat constant.

		`studsOffset` was tuned against a Head, which already sits near the top
		of a rig. A dummy's anchor is its root -- a five-stud slab pinned at its
		own centre -- so the same constant would float the plate halfway *inside*
		the body it is labelling. Measuring from the anchor's top edge makes one
		number correct for both, and stays correct for whatever shape a future
		combatant turns out to be. ]]
	gui.StudsOffsetWorldSpace = Vector3.new(0, head.Size.Y / 2 + PLATE.studsOffset, 0)
	-- Occluded rather than always-on-top: seeing health bars through a wall
	-- would be a wallhack the interface handed out for free.
	gui.AlwaysOnTop = false
	gui.MaxDistance = PLATE.maxDistance
	gui.ResetOnSpawn = false
	gui.Parent = head

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(1, 0, 0, nameHeight)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = math.round(PLATE.nameTextSize * scale)
	nameLabel.TextColor3 = TEXT
	nameLabel.TextXAlignment = Enum.TextXAlignment.Center
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Text = who.name
	nameLabel.Parent = gui
	stroked(nameLabel)

	--[[ Stage sits under the health bar and *shares* its row with the cast bar,
		the two swapping rather than stacking. While a technique is winding up,
		what this person is about to do outranks what stage they are -- and
		reusing the row keeps the plate from growing at exactly the moment a
		fight gets busy and screen space is scarcest. ]]
	local stageLabel = Instance.new("TextLabel")
	stageLabel.Size = UDim2.new(1, 0, 0, thirdRow)
	stageLabel.Position = UDim2.fromOffset(0, castTop)
	stageLabel.BackgroundTransparency = 1
	stageLabel.Font = Enum.Font.GothamMedium
	stageLabel.TextSize = math.round(PLATE.stageTextSize * scale)
	stageLabel.TextColor3 = TEXT_DIM
	stageLabel.TextXAlignment = Enum.TextXAlignment.Center
	stageLabel.Text = ""
	stageLabel.Parent = gui
	stroked(stageLabel)

	local healthBack = Instance.new("Frame")
	healthBack.Size = UDim2.new(1, 0, 0, healthHeight)
	healthBack.Position = UDim2.fromOffset(0, nameHeight + gap)
	healthBack.BackgroundColor3 = TROUGH
	healthBack.BackgroundTransparency = 0.15
	healthBack.BorderSizePixel = 0
	healthBack.Parent = gui

	local healthStroke = Instance.new("UIStroke")
	healthStroke.Color = BLACK
	healthStroke.Thickness = 1
	healthStroke.Transparency = 0.3
	healthStroke.Parent = healthBack

	local healthFill = Instance.new("Frame")
	healthFill.Size = UDim2.fromScale(1, 1)
	healthFill.BackgroundColor3 = HEALTH
	healthFill.BorderSizePixel = 0
	healthFill.Parent = healthBack

	--[[ The cast row occupies the same band the stage label does, and the two
		swap: while a technique is winding up, what this person is *about to do*
		outranks what stage they are. Reusing the row rather than adding one
		keeps the plate from growing at the exact moment a fight gets busy. ]]
	local castRow = Instance.new("Frame")
	castRow.Size = UDim2.new(1, 0, 0, castHeight)
	-- Vertically centred in the shared row, so swapping to it does not make the
	-- plate appear to jump.
	castRow.Position = UDim2.fromOffset(0, castTop + math.floor((thirdRow - castHeight) / 2))
	castRow.BackgroundColor3 = TROUGH
	castRow.BackgroundTransparency = 0.1
	castRow.BorderSizePixel = 0
	castRow.Visible = false
	castRow.Parent = gui

	local castStroke = Instance.new("UIStroke")
	castStroke.Color = BLACK
	castStroke.Thickness = 1
	castStroke.Transparency = 0.3
	castStroke.Parent = castRow

	local castFill = Instance.new("Frame")
	castFill.Size = UDim2.fromScale(0, 1)
	castFill.BackgroundColor3 = TEXT
	castFill.BorderSizePixel = 0
	castFill.Parent = castRow

	local castLabel = Instance.new("TextLabel")
	castLabel.Size = UDim2.fromScale(1, 1)
	castLabel.BackgroundTransparency = 1
	castLabel.Font = Enum.Font.GothamBold
	castLabel.TextSize = math.max(math.round(PLATE.stageTextSize * scale) - 1, 8)
	castLabel.TextColor3 = TEXT
	castLabel.TextXAlignment = Enum.TextXAlignment.Center
	castLabel.ZIndex = 3
	castLabel.Text = ""
	castLabel.Parent = castRow
	stroked(castLabel)

	return {
		gui = gui,
		name = nameLabel,
		stage = stageLabel,
		healthFill = healthFill,
		castRow = castRow,
		castFill = castFill,
		castLabel = castLabel,
		model = who.model,
		head = head,
		-- May legitimately be nil here; see `standDownEngineTag`.
		humanoid = who.model:FindFirstChildOfClass("Humanoid"),
	}
end

--[[ Stand PresenceService's plate down, every frame rather than once at build.

	Doing it once does not work, for two reasons, and the second needs no race at
	all. PresenceService *polls*, so its plate is often created after ours and a
	one-shot disable at build time finds nothing to disable -- that much is a
	race. The load-bearing half is not: `PresenceService.tick` compares
	`stageIndex * 1000 + tier`, so `apply` fires on every *tier* roll rather than
	only at a breakthrough, and it calls `clearPresence`, which **destroys** the
	plate, before building a fresh one with `Enabled` defaulting to true. At
	tonight's pacing a tier rolls over roughly every two minutes, so a one-shot
	disable would have been undone all evening, deterministically.

	Disabled rather than destroyed, still: its own tick rebuilds a plate it cannot
	find, so destroying it would start a fight that runs every tick for the rest
	of the session. Setting a property that is already set costs nothing, and if
	anything in this module throws, one property brings the original plate back.

	Looked up non-recursively on the head, which is where PresenceService parents
	it -- a recursive search over a whole character every frame for every player
	is not a thing to do sixty times a second. ]]
local function standDownServerPlate(plate: Plate)
	local serverPlate = plate.head:FindFirstChild(SERVER_PLATE_NAME)
	if serverPlate and serverPlate:IsA("BillboardGui") and serverPlate.Enabled then
		serverPlate.Enabled = false
	end
end

local function dropPlate(id: number)
	local plate = plates[id]
	if not plate then
		return
	end
	plates[id] = nil
	if plate.gui then
		plate.gui:Destroy()
	end
end

--[[ Everything on screen that can be fought, gathered once per frame.

	Players first, then anything carrying CombatService's `Combatant` tag. A
	tagged model that *is* a player's character is skipped rather than trusted:
	nothing tags one today, and a plate drawn twice over one head is exactly the
	bug this file already shipped once.

	The table is reused rather than reallocated, because this runs every frame
	and a fresh table per frame for eight entries is churn with nothing to show
	for it. ]]
local scratch: { Combatant } = {}

local function combatants(): { Combatant }
	table.clear(scratch)

	for _, other in Players:GetPlayers() do
		local character = other.Character
		if other ~= player and character then
			table.insert(scratch, {
				id = other.UserId,
				source = other,
				model = character,
				name = other.DisplayName,
			})
		end
	end

	for _, tagged in CollectionService:GetTagged(COMBATANT_TAG) do
		if tagged:IsA("Model") and not Players:GetPlayerFromCharacter(tagged) then
			local id = tagged:GetAttribute("CombatantId")
			if typeof(id) == "number" then
				--[[ A dummy's Model is named "Dummy" for every variant, so the
					instance name would render three identical plates. The
					`DisplayName` attribute is what distinguishes them, and it is
					what a player's `DisplayName` is the analogue of. ]]
				local shown = tagged:GetAttribute("DisplayName")
				table.insert(scratch, {
					id = id,
					source = tagged,
					model = tagged,
					name = if typeof(shown) == "string" then shown else tagged.Name,
				})
			end
		end
	end

	return scratch
end

--[[ Resolve a hit instance to the combatant it belongs to, or nil.

	Exposed because targeting needs the same answer the plate does, and two
	definitions of "what is a combatant" on one client is how a lock ends up on
	something that has no health bar. Walks up to the nearest Model, then asks
	the same two questions the enumeration asks: is it a player's character, or
	is it tagged. Anything else -- ground, a construct, a node -- is nil. ]]
function Nameplates.combatantFromInstance(instance: Instance): Combatant?
	local model = instance:FindFirstAncestorWhichIsA("Model")
	while model do
		local owner = Players:GetPlayerFromCharacter(model)
		if owner then
			if owner == player then
				return nil
			end
			return { id = owner.UserId, source = owner, model = model, name = owner.DisplayName }
		end
		if CollectionService:HasTag(model, COMBATANT_TAG) then
			local id = model:GetAttribute("CombatantId")
			if typeof(id) == "number" then
				local shown = model:GetAttribute("DisplayName")
				return {
					id = id,
					source = model :: Instance,
					model = model,
					name = if typeof(shown) == "string" then shown else model.Name,
				}
			end
		end
		model = model:FindFirstAncestorWhichIsA("Model")
	end
	return nil
end

--[[ Whether a combatant is still present and alive: its model is in the world
	and its published health is above zero. The lock drops on either. ]]
function Nameplates.isLive(who: Combatant): boolean
	if not who.model.Parent then
		return false
	end
	local health = who.source:GetAttribute("Health")
	return typeof(health) ~= "number" or health > 0
end

local function ensurePlate(who: Combatant)
	local existing = plates[who.id]
	if existing and existing.model == who.model and existing.gui.Parent then
		return
	end
	dropPlate(who.id)

	--[[ A plate anchors to the top of whatever this combatant is, which is not
		always a Head.

		A player rig has one. A training dummy is a Model holding a single part
		named `HumanoidRootPart` and nothing else -- no Head, and deliberately no
		Humanoid either. Requiring a Head meant `ensurePlate` returned early and
		a dummy silently never got a plate at all: not an error, not a warning,
		just no health bar over the one thing built to have its health watched.

		Found by reading DummyService before asking anyone to test it, which is
		the only reason it was not discovered as "the nameplates do not work". ]]
	local anchor = who.model:FindFirstChild("Head") or who.model.PrimaryPart
	if not anchor or not anchor:IsA("BasePart") then
		return
	end
	local built = buildPlate(who, anchor)
	if built then
		plates[who.id] = built
	end
end

--[[ Retire Roblox's own overhead name tag, every frame rather than once.

	It is on by default -- `Humanoid.DisplayDistanceType` starts at `Viewer` --
	and nothing in this project ever turned it off, so every player carried two
	names at two anchors: the engine's in white, and this plate's in the stage
	colour. `None` also retires the default health display, which is correct
	rather than incidental: this plate draws its own health bar, the built-in one
	appears only once damaged, and the two would have disagreed about where a
	health bar lives at exactly the moment one mattered.

	**Why this cannot be a one-shot set, which is how it was first written and
	why it did not work.** `ensurePlate` gates on the *Head* existing, not the
	Humanoid. A character replicates progressively, so the Head can arrive first;
	the lookup then returns nil, the set silently does nothing, and because
	`ensurePlate` short-circuits once a plate exists it is never retried. That is
	the identical shape to the `PresenceService` bug directly above -- a one-shot
	write losing a race it cannot detect, against state that comes back.

	Re-asserted here instead, and the humanoid is re-looked-up while it is still
	missing, so a late arrival is picked up on whatever frame it lands. The write
	only happens when the value actually differs, so the steady state is one
	property comparison per player per frame.

	Honest about what this is: the timing above is a *plausible* mechanism, not a
	proven one -- it was not reproduced, only derived from the code. The change is
	worth making either way, because if the cause is timing this fixes it, and if
	the cause is something else this costs a comparison and changes nothing. It
	cannot make the failure worse, which is the only reason it is safe to land
	past freeze.

	Client-side and local-view only. Nothing replicates, and the humanoid is
	untouched as far as the server is concerned. ]]
local function standDownEngineTag(plate: Plate)
	local humanoid = plate.humanoid
	if not humanoid or not humanoid.Parent then
		humanoid = plate.model:FindFirstChildOfClass("Humanoid")
		plate.humanoid = humanoid
	end
	if humanoid and humanoid.DisplayDistanceType ~= Enum.HumanoidDisplayDistanceType.None then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
end

local function refresh(who: Combatant, plate: Plate)
	standDownServerPlate(plate)
	standDownEngineTag(plate)

	local health = who.source:GetAttribute("Health")
	local maxHealth = who.source:GetAttribute("MaxHealth")
	local fraction = InterfaceSpec.fraction(
		if typeof(health) == "number" then health else 0,
		if typeof(maxHealth) == "number" then maxHealth else 0
	)

	plate.healthFill.Size = UDim2.fromScale(fraction, 1)
	plate.healthFill.BackgroundColor3 = if fraction <= InterfaceSpec.Vitals.lowHealthFraction
		then HEALTH_LOW
		else HEALTH

	local stage = who.source:GetAttribute("Stage")
	local tier = who.source:GetAttribute("Tier")
	if typeof(stage) == "string" then
		plate.stage.Text = if typeof(tier) == "number" then `{stage}  ·  {tier}` else stage
	else
		plate.stage.Text = ""
	end

	--[[ Stage colour is carried by the *name*, not by a separate chip. One
		coloured element per plate; anything more and a busy fight becomes a
		field of competing hues with no hierarchy. ]]
	local stageIndex = who.source:GetAttribute("StageIndex")
	if typeof(stageIndex) == "number" then
		plate.name.TextColor3 = color(InterfaceSpec.stageColor(stageIndex))
	end

	--[[ A cast under the floor draws no bar -- it cannot be seen -- but its
		SNAP is still drawn, because the snap is the event of the cast breaking
		and an event needs no duration to have happened. Without this, an
		interrupted sub-floor channel was invisible end to end: no bar during,
		no sign after. Found by asking what a 0.1s channel would show. ]]
	local cast = Nameplates.castOf(who.id)
	if cast and (InterfaceSpec.telegraphs(cast.duration) or Nameplates.isSnapped(cast)) then
		plate.castRow.Visible = true
		plate.stage.Visible = false
		if cast.snappedAt then
			-- Broken, not finished: full width in the danger hue for a beat.
			plate.castFill.Size = UDim2.fromScale(1, 1)
			plate.castFill.BackgroundColor3 = DANGER
		else
			local elapsed = os.clock() - cast.startedAt
			local progress = math.clamp(elapsed / math.max(cast.duration, 1e-3), 0, 1)
			plate.castFill.Size = UDim2.fromScale(progress, 1)
			plate.castFill.BackgroundColor3 = color(InterfaceSpec.kindColor(cast.kind))
		end
		plate.castLabel.Text = string.upper(cast.techId)
	else
		plate.castRow.Visible = false
		plate.stage.Visible = true
		--[[ A sub-floor windup gets a flash on the name instead of a bar. It
			says "something just happened here" without promising a duration
			that was never readable. ]]
		if cast then
			local remaining = cast.endsAt - os.clock()
			if remaining > 0 then
				plate.name.TextColor3 = color(InterfaceSpec.kindColor(cast.kind))
			end
		end

		--[[ The slow: the first status effect this game has shown. It borrows
			the third row the way a cast does, and sits below a cast in
			precedence -- what someone is about to do outranks what has been done
			to them. Read off the same instance as Health, so a dummy's slow is
			as visible as a player's, and graded by the magnitude the server
			publishes rather than guessed from WalkSpeed. ]]
		local slow = who.source:GetAttribute("SlowMultiplier")
		if typeof(slow) == "number" and slow < 1 then
			plate.stage.TextColor3 = SLOW
			plate.stage.Text = if InterfaceSpec.Status.showMultiplier
				then string.format("SLOWED  ×%.1f", slow)
				else "SLOWED"
		elseif who.source:GetAttribute("Neutral") == true then
			--[[ A neutral NPC: the first thing a player learns about it is what
				it is. "Will not start it" rather than "harmless", per the
				human's correction -- it does not aggro, and it retaliates once
				hit. Read off the Neutral attribute NpcService publishes, never
				inferred from stage, which an NPC also carries. Sits below a
				slow and a cast in this row: what is happening to it or what it
				is about to do still outranks what it is. ]]
			plate.stage.TextColor3 = NEUTRAL
			plate.stage.Text = "NEUTRAL  ·  will not start it"
		else
			plate.stage.TextColor3 = TEXT_DIM
		end
	end
end

function Nameplates.start()
	local function watch(target: Player)
		target.CharacterAdded:Connect(function()
			-- The head arrives with the character but the attributes may not,
			-- so the plate is built on the next step rather than right here.
			dropPlate(target.UserId)
		end)
		target.CharacterRemoving:Connect(function()
			dropPlate(target.UserId)
		end)
	end

	for _, other in Players:GetPlayers() do
		watch(other)
	end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(function(other: Player)
		dropPlate(other.UserId)
		casts[other.UserId] = nil
	end)

	--[[ A dummy's plate is dropped when its tag goes, which is how a despawned
		dummy stops having a health bar floating where it used to be. Players are
		covered by CharacterRemoving above. ]]
	CollectionService:GetInstanceRemovedSignal(COMBATANT_TAG):Connect(function(instance: Instance)
		local id = instance:GetAttribute("CombatantId")
		if typeof(id) == "number" then
			dropPlate(id)
			casts[id] = nil
		end
	end)

	RunService.RenderStepped:Connect(function()
		local present: { [number]: boolean } = {}
		for _, who in combatants() do
			present[who.id] = true
			ensurePlate(who)
			local plate = plates[who.id]
			if plate then
				refresh(who, plate)
			end
		end

		--[[ Anything with a plate that is no longer a combatant loses it. The
			signals above catch the ordinary cases; this catches the rest --
			a tag removed without the attribute, a model reparented, a dummy
			destroyed outright -- so a plate cannot outlive the thing it names. ]]
		for id in plates do
			if not present[id] then
				dropPlate(id)
			end
		end
	end)
end

return Nameplates
