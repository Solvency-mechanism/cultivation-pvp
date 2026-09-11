--!strict
--[[ Run with: lune run tests/wiring.test

	Every server module that exposes `start` must be required by init.server.

	Twice now a finished, correct server module has been landed as dead code:
	DummyService (8,513 bytes, every /dummy command fell on the floor for a
	day) and NpcService (293 lines, no NPC ever spawned). Both passed every
	suite, because an unreferenced module is perfectly valid Luau and a module
	nobody requires cannot fail a test nobody runs. Nothing but a person
	opening init.server and looking could see it.

	This reads the source. It does not load Roblox modules -- Lune cannot --
	so it is the same class of instrument as the compile suite and the local
	count: a fact about the files, checked where a person would otherwise have
	to remember to look. ]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local init = fs.readFile("src/server/init.server.luau")

local failed = 0
for _, name in fs.readDir("src/server") do
	local moduleName = name:match("^(%w+)%.luau$")
	if not moduleName or name == "init.server.luau" then
		continue
	end
	local source = fs.readFile(`src/server/{name}`)
	if not source:find(`function {moduleName}%.start%(`) then
		continue
	end
	local required = init:find(`require%(script%.{moduleName}%)`) ~= nil
	local started = init:find(`startService%("{moduleName}"`) ~= nil
	if not (required and started) then
		failed += 1
		print(
			`FAIL {moduleName}: has a start but init.server {if required
				then "never starts it"
				else "never requires it"}`
		)
	end
end

print(`server modules with a start are wired: {failed} unwired`)
process.exit(if failed == 0 then 0 else 1)
