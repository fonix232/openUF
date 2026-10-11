--[[
	Pick the UniFi access point this board most resembles.

	The controller files, draws and configures a device by its model: which
	radios it has, how fast they are, how many Ethernet ports and whether they
	form a switch (Port VLAN, the Ports view and the "PoE In" uplink only exist
	on models whose registry entry says so). Claiming a model that differs from
	the hardware costs something either way -- a radio the controller shows but
	that never comes up, a switch that does not exist, WiFi 6 modes pushed at an
	802.11ac phy -- so the closest match is the one to claim.

	The facts come from OpenWrt's own /etc/board.json (board.d writes the
	Ethernet layout and, per radio, the antenna masks, bands, PHY generations
	and maximum width). The candidates are catalog.lua, generated from
	the controller's own model registry (tools/uidb-catalog.py). Scoring, in
	order of weight:

	  bands        the same set of 2.4/5/6 GHz radios            -40 per miss
	  switch       a multi-socket board wants a model with a
	               built-in switch, a one/two-socket board not    -25
	  generation   n / ac / ax / be of the best radio             -30 per step
	  ports        Ethernet port count                            -5 per port
	  speed        per band, streams x per-stream PHY rate vs the
	               registry's max speed, in doublings             -10 per 2x
	  form         outdoor and mesh models only when nothing
	               else fits                                      -6

	Exact ties go to the models in M.PREFER.
]]--

local M = {}

-- Per-stream PHY rate in Mbit/s at the top MCS, short GI, by generation and
-- channel width -- the figures the registry's max speeds are built from.
M.RATE = {
	n  = {[20] = 72,  [40] = 150},
	ac = {[20] = 87,  [40] = 200, [80] = 433, [160] = 867},
	ax = {[20] = 143, [40] = 287, [80] = 600, [160] = 1201},
	be = {[20] = 172, [40] = 344, [80] = 721, [160] = 1441, [320] = 2882},
}
M.GEN_RANK = {n = 1, ac = 2, ax = 3, be = 4}
local BAND_KEY = {["2G"] = "ng", ["5G"] = "na", ["6G"] = "6e"}
-- Tie-breaks only: U6IW is the identity validated end to end, the U6-Pro the
-- most common single-port WiFi 6 AP.
M.PREFER = {U6IW = 0.5, UAP6MP = 0.3}

local function popcount(n)
	n = tonumber(n) or 0
	local c = 0
	while n > 0 do
		if n % 2 == 1 then c = c + 1 end
		n = math.floor(n / 2)
	end
	return c
end

local function rate(gen, width)
	local t = M.RATE[gen] or M.RATE.n
	local best = 0
	for w, r in pairs(t) do
		if w <= (tonumber(width) or 20) and r > best then best = r end
	end
	return best
end

-- The board's sockets, in the same order board.lua uses.
function M.sockets(board)
	local net = type(board) == "table" and board.network or {}
	local list, seen = {}, {}
	local function add(i)
		if type(i) == "string" and i ~= "" and not seen[i] then
			seen[i] = true
			list[#list + 1] = i
		end
	end
	if type(net.wan) == "table" then add(net.wan.device) end
	if type(net.lan) == "table" then
		for _, p in ipairs(net.lan.ports or {}) do add(p) end
		add(net.lan.device)
	end
	return list
end

-- Facts from a decoded /etc/board.json: {bands = {ng = {gen, nss, width,
-- speed}, ...}, gen = best generation, sockets = n}. nil when the board
-- describes no radio (an old OpenWrt without board.json `wlan` info).
function M.facts(board)
	if type(board) ~= "table" or type(board.wlan) ~= "table" then return nil end
	local bands, best = {}, nil
	for _, phy in pairs(board.wlan) do
		local info = type(phy) == "table" and phy.info
		if type(info) == "table" and type(info.bands) == "table" then
			local nss = math.max(1, popcount(info.antenna_tx))
			for name, b in pairs(info.bands) do
				local key = BAND_KEY[name]
				if key and type(b) == "table" then
					local gen = (b.eht and "be") or (b.he and "ax")
						or (b.vht and key ~= "ng" and "ac") or "n"
					local width = tonumber(b.max_width) or 20
					local speed = nss * rate(gen, width)
					local cur = bands[key]
					if not cur or speed > cur.speed then
						bands[key] = {gen = gen, nss = nss, width = width, speed = speed}
					end
					if not best or M.GEN_RANK[gen] > M.GEN_RANK[best] then best = gen end
				end
			end
		end
	end
	if not best then return nil end
	return {bands = bands, gen = best, sockets = math.max(1, #M.sockets(board))}
end

local function log2(x) return math.log(x) / math.log(2) end

-- Score one catalogue model against the facts (higher is closer).
function M.score(model, facts)
	local s = 0
	local have = {}
	for _, b in ipairs(model.bands or {}) do have[b] = true end
	for b in pairs(facts.bands) do
		if not have[b] then s = s - 40 end
	end
	for b in pairs(have) do
		if not facts.bands[b] then s = s - 40 end
	end
	s = s - 30 * math.abs((M.GEN_RANK[facts.gen] or 1) - (M.GEN_RANK[model.gen] or 1))
	local multi = facts.sockets >= 3
	if multi ~= (model.switch == true) then s = s - 25 end
	s = s - math.min(20, 5 * math.abs(facts.sockets - (tonumber(model.ports) or 1)))
	for b, f in pairs(facts.bands) do
		local ms = model.speed and tonumber(model.speed[b])
		if have[b] and ms and ms > 0 and f.speed > 0 then
			s = s - 10 * math.abs(log2(f.speed / ms))
		end
	end
	if model.outdoor then s = s - 6 end
	if model.mesh then s = s - 6 end
	s = s + (M.PREFER[model.model] or 0)
	return s
end

-- The best model, its score and the ranked list ({model, score} pairs).
function M.best(catalog, facts)
	local ranked = {}
	for _, m in ipairs((catalog and catalog.models) or {}) do
		ranked[#ranked + 1] = {model = m, score = M.score(m, facts)}
	end
	table.sort(ranked, function(a, b)
		if a.score ~= b.score then return a.score > b.score end
		return a.model.model < b.model.model
	end)
	if #ranked == 0 then return nil end
	return ranked[1].model, ranked[1].score, ranked
end

function M.find(catalog, code)
	for _, m in ipairs((catalog and catalog.models) or {}) do
		if m.model == code then return m end
	end
	return nil
end

-- An identity table for a catalogue entry.
function M.identity(m)
	return {
		platform         = m.platform or m.model,
		model            = m.model,
		model_display    = (m.sku ~= nil and m.sku ~= "") and m.sku or m.name,
		sysid            = m.sysid,
		fw = {
			pre        = m.model .. ".",
			-- The catalogue's release; openUF learns newer ones from the
			-- controller's own upgrade commands (upgrade.lua).
			ver        = (m.fw ~= nil and m.fw ~= "") and m.fw or "6.0.0.0",
			buildtime  = "000000.0000",
			factoryver = "6.0.0",
		},
		bootver          = "",
		required_version = "6.0.0",
		-- Port layout the controller's registry has for this model: a model
		-- with a built-in switch takes its uplink on the LAST port ("PoE In +
		-- Data" on U6IW), a plain AP on port 1.
		ports            = m.ports,
		switch           = m.switch,
		uplink_idx       = m.switch and m.ports or 1,
	}
end

return M
