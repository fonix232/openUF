--[[
	Device identity chosen at first start: the UniFi access point closest to
	this board (modelmatch.lua against catalog.lua, the controller's own model
	registry).

	The choice is written to /etc/openuf/ufmodel-auto.json and read back on
	every later start -- an adopted device must never change model under the
	controller. Only the model CODE is kept: its firmware version and the rest
	come from the catalogue, so a newer catalogue updates them. Delete the file
	(and re-adopt) to choose again.

	Falls back to u6iw.lua when the board describes no radios (board.json
	without `wlan` info) or anything else goes wrong.
]]--

local STATE_FILE = "/etc/openuf/ufmodel-auto.json"

-- A sibling script by its path under the install directory ("ufmodel/auto.lua"),
-- run fresh: see loader.lua.
local function sibling(rel)
	return require("loader").run((rel:gsub("%.lua$", ""):gsub("/", ".")))
end

local function read(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local ok, uap = pcall(function()
	local cjson = require("cjson")
	local match = sibling("modelmatch.lua")
	local catalog = sibling("ufmodel/catalog.lua")
	local saved = read(STATE_FILE)
	local ok_s, st = pcall(cjson.decode, saved or "")
	local chosen = ok_s and type(st) == "table" and match.find(catalog, st.model) or nil
	if not chosen then
		local ok_b, board = pcall(cjson.decode, read("/etc/board.json") or "")
		local facts = ok_b and match.facts(board) or nil
		if not facts then return nil end
		local score
		chosen, score = match.best(catalog, facts)
		if not chosen then return nil end
		io.stderr:write(string.format("openuf: identity: %s (%s), closest UniFi AP to this board "
			.. "(score %.1f)\n", chosen.model, chosen.name, score))
		local f = io.open(STATE_FILE, "w")
		if f then
			f:write(cjson.encode({model = chosen.model, uidb = catalog.uidb}))
			f:close()
		end
	end
	return match.identity(chosen)
end)

if ok and uap then return uap end
if not ok then io.stderr:write("openuf: identity: auto match failed (" .. tostring(uap) .. "), using u6iw\n") end
return sibling("ufmodel/u6iw.lua")
