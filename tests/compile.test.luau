--!strict
--[[ Run with: lune run tests/compile.test

	Every script under src/ must COMPILE, not merely lint.

	This exists because of a gate failure. A client build reached the document
	gate with no HUD at all -- no vitals, no bar, no reticle -- and the cause was
	not a runtime throw but the Luau compiler refusing the script outright:

	    Out of local registers when trying to allocate startSubsystem:
	    exceeded limit 200

	Luau caps a single function at 200 locals, and `init.client.luau`'s
	top-level chunk had crossed it. Four suites, selene and stylua were all
	green on a script that could not run one line: Lune never loads the Roblox
	scripts, selene does not count registers, and rojo does not compile. The
	only instrument that saw it was a person starting a client and looking at
	the screen, twenty minutes into a gate.

	Lune ships the same compiler. Compiling each file here costs nothing and
	turns that twenty minutes into a red line in the suite. It does not run
	anything -- Roblox services are not available -- so it catches compile
	failures only: register limits, syntax errors, malformed constants. That
	is the class it was written for. ]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local function walk(dir: string, out: { string })
	for _, name in fs.readDir(dir) do
		local path = `{dir}/{name}`
		if fs.isDir(path) then
			walk(path, out)
		elseif name:match("%.luau$") then
			table.insert(out, path)
		end
	end
end

local files: { string } = {}
walk("src", files)
table.sort(files)

local failed = 0
for _, path in files do
	local ok, err = pcall(luau.compile, fs.readFile(path))
	if not ok then
		failed += 1
		-- First line only; the compiler's message names the file's line itself.
		local message = tostring(err):gsub("\n.*", "")
		print(`FAIL {path}: {message}`)
	end
end

print(`{#files} files compiled, {failed} failed`)
process.exit(if failed == 0 then 0 else 1)
