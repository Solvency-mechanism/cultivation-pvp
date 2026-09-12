--!strict
--[[ Run with: lune run tests/wiring.test

	Source-level facts that execution cannot see -- Lune runs the pure shared
	modules perfectly well without ever proving they agree with each other or
	with what calls them; this reads the FILES to check the things a passing
	suite would not.

	1. Every server module that exposes `start` must be required by
	   init.server. Twice now a finished, correct server module has been
	   landed as dead code: DummyService (8,513 bytes, every /dummy command
	   fell on the floor for a day) and NpcService (293 lines, no NPC ever
	   spawned). Both passed every suite, because an unreferenced module is
	   perfectly valid Luau and a module nobody requires cannot fail a test
	   nobody runs.
	2. Every key in Progression.newState()'s literal appears in both clone()
	   and toStore() -- the highest-severity item named against the Core
	   initiative. PersistenceService.save used to build its own literal by
	   hand and silently dropped any field newState grew that it did not
	   already know about: no error, no test, no symptom, a permanent core
	   cultivated for hours and never saved. The fix moved the closed set
	   into Progression.toStore, the one place a state is ever serialised;
	   this is what keeps it closed going forward -- a field added to
	   newState with no matching line in clone or toStore is exactly the
	   shape of bug this file exists to catch before a person has to notice
	   a save silently missing a number. ]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local process_exitCode = 0

do
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
	if failed > 0 then
		process_exitCode = 1
	end
end

do
	local source = fs.readFile("src/shared/Progression.luau")

	local function bodyOf(functionPattern: string): string?
		local start = source:find(functionPattern)
		if not start then
			return nil
		end
		local stop = source:find("\nend", start)
		return source:sub(start, stop or #source)
	end

	local newStateBody = bodyOf("function Progression%.newState%(%)")
	local cloneBody = bodyOf("local function clone%(state: State%)")
	local toStoreBody = bodyOf("function Progression%.toStore%(state: State%)")

	local failed = 0
	if not (newStateBody and cloneBody and toStoreBody) then
		failed += 1
		print("FAIL closed-set: could not find newState/clone/toStore in Progression.luau")
	else
		for field in newStateBody:gmatch("(%a+)%s*=") do
			local inClone = cloneBody:find(field, 1, true) ~= nil
			local inToStore = toStoreBody:find(field, 1, true) ~= nil
			if not (inClone and inToStore) then
				failed += 1
				print(
					`FAIL closed-set: newState's "{field}" is missing from {if not inClone
						then "clone"
						else "toStore"}`
				)
			end
		end
	end

	print(`Progression.State's closed set holds: {failed} missing`)
	if failed > 0 then
		process_exitCode = 1
	end
end

process.exit(process_exitCode)
