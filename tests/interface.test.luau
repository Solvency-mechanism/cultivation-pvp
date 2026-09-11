--!strict
--[[ Run with: lune run tests/interface.test

	`InterfaceSpec` is pure and dependency-free for the same reason every other
	module in src/shared is, and it earns the same treatment: the numbers behind
	the HUD are checkable without Studio, without a running game and without a
	second player.

	What is worth asserting here is narrow and deliberate. Not "does the bar look
	right" -- no test can answer that -- but the handful of places where a wrong
	answer is silent and would only ever be discovered by someone playing:
	a divide-by-zero on a pool the server has not published yet, a scale factor
	that collapses the interface on an unusual viewport, a cast bar drawn for a
	windup too short to read, a notice priority that lets a node telegraph erase
	a death. ]]

local process = require("@lune/process")
local Config = require("../src/shared/Config")
local InterfaceSpec = require("../src/shared/InterfaceSpec")

local passed, failed = 0, 0
local failures: { string } = {}

local function check(name: string, ok: boolean, detail: string?)
	if ok then
		passed += 1
	else
		failed += 1
		table.insert(failures, `{name}{if detail then ` -- {detail}` else ""}`)
	end
end

local function eq(name: string, actual: any, expected: any)
	check(name, actual == expected, `expected {expected}, got {actual}`)
end

-- Bar fractions. A client renders before the server has published anything, so
-- every one of these arrives in practice rather than only in theory.
eq("half a pool reads as half", InterfaceSpec.fraction(50, 100), 0.5)
eq("an unpublished pool is empty, not an error", InterfaceSpec.fraction(0, 0), 0)
eq("a negative maximum is empty", InterfaceSpec.fraction(10, -5), 0)
eq("overfull clamps to one", InterfaceSpec.fraction(150, 100), 1)
eq("negative health clamps to zero", InterfaceSpec.fraction(-20, 100), 0)

--[[ Viewport scaling.

	**Two assertions here encoded the wrong idea and were rewritten rather than
	repaired.** They asserted that a phone scales up hard (> 1.2) and that the
	curve falls monotonically from phone to reference. Both were true of a scale
	function that had a legibility floor and no footprint ceiling -- the same
	function that let the bottom stack eat 44% of a landscape phone and 66% of a
	320px window. The tests were faithfully protecting the bug.

	What is asserted now is the property actually wanted: a phone is never scaled
	*below* reference, and the stack always fits its budget. ]]
check("the reference viewport is unscaled", math.abs(InterfaceSpec.scale(1080) - 1) < 0.02)
check("a phone is never scaled below the reference size", InterfaceSpec.scale(480) >= 1.0)
check("a large monitor grows sublinearly", InterfaceSpec.scale(2160) < 1.5)
check("scale is clamped at the top", InterfaceSpec.scale(4000) <= InterfaceSpec.Scale.maxScale)
check("a degenerate viewport does not divide by zero", InterfaceSpec.scale(0) == 1)

--[[ The footprint cap, and the height check that should have existed already.

	The action bar's *width* was asserted from this suite's first version; the
	*height* of the stack it belongs to was not. That asymmetry is the lesson
	rather than a detail: the axis that got tested is the axis that had already
	been thought about, and the axis that broke is the one that had not. ]]
local STACK_BUDGET = InterfaceSpec.Scale.stackBudget

for _, height in { 400, 450, 480, 540, 600, 700, 768, 800, 900, 1080, 1440, 2160 } do
	local occupied = InterfaceSpec.stackHeight() * InterfaceSpec.scale(height)
	check(
		`the bottom stack fits its budget at {height}px`,
		occupied <= STACK_BUDGET * height + 1,
		`took {math.round((occupied / height) * 100)}% of the frame`
	)
end

--[[ 400px is the floor at which the budget is still satisfiable. Below it no
	scale both fits the budget and keeps text legible, `minScale` deliberately
	wins, and that trade is asserted rather than left to clamp ordering. ]]
check(
	"below 400px legibility wins over footprint, deliberately",
	InterfaceSpec.scale(320) == InterfaceSpec.Scale.minScale
)

-- Named so a regression reports which real device it broke, not which number moved.
check(
	"a landscape phone keeps most of its screen",
	InterfaceSpec.stackHeight() * InterfaceSpec.scale(480) <= STACK_BUDGET * 480 + 1,
	"854x480 is the case the small-screen branch was written for"
)
check(
	"the cap does not bite at desktop heights",
	InterfaceSpec.stackHeight() * InterfaceSpec.scale(768) < 0.3 * 768
)

-- Summed from the specs, so a layout change moves it rather than leaving a stale
-- literal that would make the cap silently wrong in the flattering direction.
check(
	"the stack height is derived, not a literal",
	InterfaceSpec.stackHeight() > InterfaceSpec.Slot.size + InterfaceSpec.Vitals.healthHeight
)

--[[ The action bar has to fit. The movement pass flagged a five-slot bar as a
	phone-width worry it could not resolve, and the whole reason square icon
	slots were chosen over the old wide name-plates is that they retire it. If
	that ever stops being true, it should fail here rather than on a phone. ]]
local FOUR_SLOT_LEGACY_WIDTH = 468
check(
	"five slots are narrower than the four wide plates they replaced",
	InterfaceSpec.barWidth(5) < FOUR_SLOT_LEGACY_WIDTH,
	`five slots came to {InterfaceSpec.barWidth(5)}px`
)
--[[ Phone width, modelled honestly. Roblox plays landscape, so a 480-tall
	phone is roughly 854 wide -- the constraint is not "does it fit", which is
	trivially yes, but whether the bar has eaten so much of the width that the
	world is gone. Half is the line: past that the HUD is the game. ]]
local PHONE_HEIGHT, PHONE_WIDTH = 480, 854
local phoneBar = InterfaceSpec.barWidth(5) * InterfaceSpec.scale(PHONE_HEIGHT)
check(
	"five slots take under half a landscape phone's width",
	phoneBar < PHONE_WIDTH / 2,
	`{math.round(phoneBar)}px of {PHONE_WIDTH}`
)
-- The vitals cluster sits above the bar and is the wider of the two, so it is
-- the element that actually decides whether the cluster fits.
local phoneVitals = InterfaceSpec.Vitals.width * InterfaceSpec.scale(PHONE_HEIGHT)
check(
	"the vitals cluster takes under half a landscape phone's width",
	phoneVitals < PHONE_WIDTH / 2,
	`{math.round(phoneVitals)}px of {PHONE_WIDTH}`
)
eq("one slot is just the slot", InterfaceSpec.barWidth(1), InterfaceSpec.Slot.size)
eq("no slots is no bar", InterfaceSpec.barWidth(0), 0)

--[[ The telegraph floor. A bar that lives two frames is worse than no bar,
	because it trains the eye to look for something that is not reliably there.
	These assertions pin that judgement against the live technique pool, so a
	future technique that drops under the floor is discovered here. ]]
check("a zero windup does not telegraph", not InterfaceSpec.telegraphs(0))
check("a 0.06s dash does not telegraph", not InterfaceSpec.telegraphs(0.06))
check("a 0.9s pierce telegraphs", InterfaceSpec.telegraphs(0.9))

--[[ Every striker must be readable. Read-and-react is the stated core of the
	combat design, and it is meaningless if the attacks it is about cannot be
	seen coming. This is the assertion that caught lance sitting at exactly the
	floor. ]]
-- The telegraph is the commit: castTime for a channelled technique, windup for
-- everything else. One number, per the one-timer ruling -- a channel with
-- windup 0 is not a flash, it is a three-second bar.
--[[ Three ways a striker can be telegraphed, and the assertion accepts any:

	1. A commit at or above the floor -- the bar is the telegraph. Every
	   striker before the projectile variations was this.
	2. A projectile -- the FLIGHT is the telegraph. A Shard has no bar because
	   you dodge the bolt, which is what "skillshot" means. An instant hitscan
	   with no bar would fail here; an instant bolt does not, because there is
	   still a thing to react to.
	3. A named sub-floor channel. A real channel -- server-tracked, interruptible
	   -- deliberately under the floor is a design choice about a technique that
	   is meant not to be reactable, and it is the case this layer had to give
	   an explicit answer for (no bar; the snap still draws). It is a NAMED
	   list so that a future one fails this test until someone adds it on
	   purpose. It cannot happen by accident. ]]
local SUB_FLOOR_CHANNELS: { [string]: boolean } = { hoarfrost = true }

for id, tech in Config.Techniques do
	if tech.kind == "striker" then
		local commit = if tech.castTime > 0 then tech.castTime else tech.windup
		local byCommit = InterfaceSpec.telegraphs(commit)
		local byFlight = (tech :: any).projectile ~= nil
		local byDesign = SUB_FLOOR_CHANNELS[id] == true and tech.castTime > 0
		check(
			`striker {id} is telegraphable, by bar, by flight, or by name`,
			byCommit or byFlight or byDesign,
			`commit {commit} is under the {InterfaceSpec.Cast.windupFloor} floor with no projectile and no exemption`
		)
	end
end

-- Every kind the config can produce needs a colour, or a slot falls back to
-- grey and the kind vocabulary silently stops working for it.
for id, tech in Config.Techniques do
	check(
		`technique {id} has a colour for kind {tech.kind}`,
		InterfaceSpec.KindColor[tech.kind] ~= nil
	)
end
for _, slot in Config.LoadoutSlots do
	check(`slot {slot} has a kind colour`, InterfaceSpec.KindColor[slot] ~= nil)
end

--[[ Reach, and the absences that are deliberate.

	`forger` and `enforcer` must NOT report reach. A construct dropped with
	nobody nearby is legitimate zoning and a self-buff has no reach at all, so an
	"out of reach" state on either would invent a failure that does not exist --
	and a player seeing it would reasonably conclude the technique was unusable.
	Asserted rather than left as an omission, because an omission is exactly what
	a future edit would restore by accident. ]]
check("a striker's reach can fail", InterfaceSpec.hasReach("striker"))
check("a ruler's reach can fail", InterfaceSpec.hasReach("ruler"))
check("a forger has no reach state, deliberately", not InterfaceSpec.hasReach("forger"))
check("an enforcer has no reach state, deliberately", not InterfaceSpec.hasReach("enforcer"))
check("an unknown kind claims no reach", not InterfaceSpec.hasReach("nonsense"))

-- Every kind in the live pool resolves, so a new kind cannot crash the slot bar.
for id, tech in Config.Techniques do
	check(
		`technique {id} resolves a reach answer for kind {tech.kind}`,
		type(InterfaceSpec.hasReach(tech.kind)) == "boolean"
	)
end

-- Stage colours must cover the ladder, and must not run out at the top.
for index = 1, #Config.Stages do
	check(`stage {index} has a colour`, InterfaceSpec.stageColor(index) ~= nil)
end
eq(
	"past the top of the ladder clamps rather than returning nil",
	InterfaceSpec.stageColor(#Config.Stages + 5),
	InterfaceSpec.stageColor(#Config.Stages)
)

--[[ Notice weight. The single-slot channel means priority is the only thing
	stopping a Prime-node announcement from erasing a kill that landed half a
	second earlier. ]]
local death = InterfaceSpec.noticeKind("death")
local kill = InterfaceSpec.noticeKind("kill")
local server = InterfaceSpec.noticeKind("server")
local plain = InterfaceSpec.noticeKind("local")

check("a death outranks a server announcement", death.priority > server.priority)
check("a kill outranks a server announcement", kill.priority > server.priority)
check("a death is held longer than a plain notice", death.seconds > plain.seconds)
check("a death is drawn larger than a plain notice", death.scale > plain.scale)
check("a kill cannot be erased immediately", kill.floor > 0)
check("a plain notice claims no floor", plain.floor == 0)
eq("an unknown kind degrades to the plain weight", InterfaceSpec.noticeKind("nonsense"), plain)

--[[ Cast-bar timing constants, and the relation between them that matters.

	A snap -- the bar drawn broken after an interrupt or a fizzle -- has to be
	visible as an event, so it must outlast the ordinary post-cast hold; and it
	must still be brief, so a defender who just interrupted someone is not
	staring at a red bar while the next thing happens. Both bounds asserted,
	because either one drifting turns a designed cue into either a flicker or a
	stuck bar. ]]
check(
	"a snap outlasts the ordinary hold",
	InterfaceSpec.Cast.snapSeconds > InterfaceSpec.Cast.holdSeconds
)
check("a snap is still brief", InterfaceSpec.Cast.snapSeconds < 1.0)
check(
	"the sub-floor flash is shorter than a snap",
	InterfaceSpec.Cast.flashSeconds < InterfaceSpec.Cast.snapSeconds
)

--[[ The commit is one number. Every channelled technique in the live pool must
	have windup 0, per the one-timer ruling -- two timers on one technique is a
	seam by construction, and this is the assertion that keeps anyone from
	reopening it by adding a technique with both. Roster asserts the same from
	the Config side; this is the client's stake in it, since the bar draws
	exactly one duration. ]]
--[[ The one-timer rule holds for EVERY channel: windup 0. The telegraph part
	honours the same named list the striker assertion does -- a sub-floor
	channel is a deliberate exception to "the bar is the telegraph", and it is
	deliberate only if it is listed. Two assertions, one list, or they
	contradict on exactly the case the list exists for -- which they did. ]]
for id, tech in Config.Techniques do
	local castTime = (tech :: any).castTime or 0
	if castTime > 0 then
		check(`channelled technique {id} has no separate windup`, tech.windup == 0)
		check(
			`channelled technique {id} telegraphs by its castTime, or is named sub-floor`,
			InterfaceSpec.telegraphs(castTime) or SUB_FLOOR_CHANNELS[id] == true
		)
	end
end

--[[ The top-level local count of the client, held well under the compiler's
	limit.

	Luau caps a function at 200 local registers, and a script's top-level chunk
	is a function. init.client.luau crossed 200 in 74f3c2b, the compiler refused
	the whole file, and nothing in it ran -- while every suite and linter stayed
	green, since none of them compile a client script. tests/compile.test is the
	hard gate now and fails at exactly 200. This is the soft one: it fails at a
	number that leaves room, so the count is caught a commit early rather than
	at the moment it breaks. Read from the source under Lune, because that is
	the one place this file can be read outside Studio.

	If this fails, do not raise the ceiling: scope a section into a do-block
	and export its handles through a record, as the rest of the file does. ]]
local fs = require("@lune/fs")
local clientSource = fs.readFile("src/client/init.client.luau")
local topLevelLocals = 0
for line in string.gmatch(clientSource, "[^\n]+") do
	if string.match(line, "^local ") then
		topLevelLocals += 1
	end
end
local SOFT_CEILING = 175
check(
	"the client stays under the local-register soft ceiling",
	topLevelLocals <= SOFT_CEILING,
	`{topLevelLocals} top-level locals, ceiling {SOFT_CEILING}, hard limit 200`
)

--[[ The target frame holds its third row. The height was a literal that its
	contents outgrew -- the refusal caption's descenders ran three pixels under
	the frame's edge, seen live the first time the frame had a real target. Now
	summed from the rows, and asserted so a row that grows fails here rather
	than clips on a screen. ]]
do
	local t = InterfaceSpec.Target
	local thirdBottom = t.padTop
		+ t.nameHeight
		+ t.nameToHealthGap
		+ t.healthHeight
		+ t.healthToThirdGap
		+ math.max(t.thirdRowHeight, InterfaceSpec.Cast.targetHeight)
	check(
		"the target frame is tall enough for its third row",
		InterfaceSpec.targetFrameHeight() >= thirdBottom + t.padBottom,
		`third row ends at {thirdBottom}, frame is {InterfaceSpec.targetFrameHeight()}`
	)
	check("the refusal caption fits the third row", t.thirdRowHeight >= 14)
end

-- Cooldown countdowns, in the shape an icon prints them.
eq("a sub-second cooldown shows a decimal", InterfaceSpec.countdown(0.8), "0.8")
eq("a long cooldown rounds up to whole seconds", InterfaceSpec.countdown(15.2), "16")
eq("an elapsed cooldown prints nothing", InterfaceSpec.countdown(0), "")
eq("a negative cooldown prints nothing", InterfaceSpec.countdown(-3), "")

-- Thousands separators. Refinement runs to five figures at Lowgold, and an
-- unseparated five-figure number is read digit by digit rather than at a glance.
eq("small numbers are untouched", InterfaceSpec.commas(42), "42")
eq("four figures separate", InterfaceSpec.commas(9000), "9,000")
eq("five figures separate", InterfaceSpec.commas(45000), "45,000")
eq("seven figures separate twice", InterfaceSpec.commas(1234567), "1,234,567")
eq("exactly three digits do not separate", InterfaceSpec.commas(999), "999")
eq("a fraction floors", InterfaceSpec.commas(1999.7), "1,999")
eq("zero is zero", InterfaceSpec.commas(0), "0")
eq("a negative keeps its sign", InterfaceSpec.commas(-12345), "-12,345")

print(`\n  passed: {passed}   failed: {failed}`)
if failed > 0 then
	for _, f in failures do
		print(`  FAIL  {f}`)
	end
	process.exit(1)
end
print("  all interface tests passed\n")
