-- The one rule the layout exists for: src/unifi/ is the controller's side
-- and never depends on the device's. No openwrt.* module, no UCI or ubus
-- binding, no shell commands -- anything it needs from the device arrives as
-- an argument (see wlan.parse's caps, payload.sys_stats' loadavg).
-- Run from the package directory: lua tests/run_tests.lua

-- Deliberate exceptions, each with its reason.
local ALLOWED = {
	-- The ledger creates its own directory before its first write.
	["src/unifi/unhandled.lua"] = {["os.execute"] = true},
}

local FORBIDDEN = {
	{"require%(%s*[\"']openwrt%.", "requires an openwrt.* module"},
	{"require%(%s*[\"']uci[\"']", "requires the UCI binding"},
	{"require%(%s*[\"']ubus[\"']", "requires the ubus binding"},
	{"io%.popen", "io.popen"},
	{"os%.execute", "os.execute"},
}

local function unifi_files()
	local out = {}
	local h = assert(io.popen("find src/unifi -name '*.lua' | sort"))
	for line in h:lines() do out[#out + 1] = line end
	h:close()
	return out
end

-- Code only: whole-line comments and trailing comments dropped, so prose
-- that mentions a forbidden call does not count.
local function code_lines(path)
	local f = assert(io.open(path, "r"))
	local src = f:read("*a")
	f:close()
	src = src:gsub("%-%-%[(=*)%[.-%]%1%]", "")
	local lines = {}
	for line in (src .. "\n"):gmatch("([^\n]*)\n") do
		lines[#lines + 1] = (line:gsub("%-%-.*$", ""))
	end
	return lines
end

return {
	{
		name = "architecture: nothing in src/unifi/ depends on the device",
		fn = function()
			local files = unifi_files()
			assert_true(#files >= 15, "found the unifi/ modules (" .. #files .. ")")
			local problems = {}
			for _, path in ipairs(files) do
				local allow = ALLOWED[path] or {}
				for n, line in ipairs(code_lines(path)) do
					for _, rule in ipairs(FORBIDDEN) do
						if line:find(rule[1]) and not allow[rule[2]] then
							problems[#problems + 1] = ("%s:%d %s"):format(path, n, rule[2])
						end
					end
				end
			end
			assert_eq(table.concat(problems, "; "), "", "unifi/ stays device-free")
		end
	},
	{
		name = "architecture: the unifi/ modules load without an OpenWrt underneath",
		fn = function()
			-- A require of the device side hidden behind a variable would slip
			-- past the text check; loading every module with openwrt.* made
			-- unloadable catches it.
			local blocked = {}
			local orig_require = require
			local function guarded(name)
				if type(name) == "string" and (name:match("^openwrt%.") or name == "uci" or name == "ubus") then
					blocked[#blocked + 1] = name
					error("unifi/ must not load " .. name, 2)
				end
				return orig_require(name)
			end
			_G.require = guarded
			local failures = {}
			for _, path in ipairs(unifi_files()) do
				local mod = path:gsub("^src/", ""):gsub("%.lua$", ""):gsub("/", ".")
				package.loaded[mod] = nil
				local ok, err = pcall(orig_require, mod)
				if not ok then failures[#failures + 1] = mod .. ": " .. tostring(err) end
			end
			_G.require = orig_require
			assert_eq(#blocked, 0, "no device module requested: " .. table.concat(blocked, ", "))
			assert_eq(table.concat(failures, "; "), "", "every unifi/ module loads")
		end
	},
}
