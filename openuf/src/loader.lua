--[[
	loader.lua -- find openUF's own files by module name.

	Modules load each other with require(), resolved through package.path:
	on the device the daemon runs from /usr/share/openuf (whose "./?.lua" is
	already on the default path), and the test suite puts src/ in front.

	Model maps and model identities are not modules but scripts: each load
	runs board detection again, which require() would cache away. run()
	finds those the same way and executes them fresh.
]]--

local M = {}

-- "ufmodel.auto" -> the first matching file on package.path, or nil.
function M.path(name)
	local rel = name:gsub("%.", "/")
	for template in package.path:gmatch("[^;]+") do
		local p = template:gsub("%?", rel)
		local f = io.open(p, "r")
		if f then
			f:close()
			return p
		end
	end
	return nil
end

-- dofile() of a named script; errors when it cannot be found.
function M.run(name)
	local p = M.path(name)
	if not p then error("cannot find " .. name) end
	return dofile(p)
end

-- Put the directory holding `script` (a debug.getinfo source, "@path") on
-- package.path, for entry points started from anywhere. `up` climbs out of
-- that many subdirectories first (a hook in hook/).
function M.add_root(source, up)
	local dir = (source or ""):match("^@(.*/)") or "./"
	for _ = 1, up or 0 do dir = dir:gsub("[^/]+/$", "") end
	if dir == "" then dir = "./" end
	local entry = dir .. "?.lua"
	if not package.path:find(entry, 1, true) then
		package.path = entry .. ";" .. package.path
	end
end

return M
