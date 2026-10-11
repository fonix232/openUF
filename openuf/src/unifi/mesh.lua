--[[
	mesh.lua -- the controller's wireless uplink ("mesh"), its side only: the
	`mesh.*` block of a system_cfg, the two backhaul VAPs the push adds to the
	wireless.<n> list (unifi/wlan.lua hands them over instead of provisioning
	them as access points), the neutral plan the device side writes
	(openwrt/ucihelper.lua backhaul_apply), and the payload fields that report
	a wireless uplink back.

	Ported from yesrab/openUF (backhaul.lua, 2026-10-03), where it was captured
	against a UCG Ultra on Network 10.6.106 and verified end to end on two
	MT7986 boards (PROTOCOL-VALIDATION.md § Wireless uplink). Sent only to a
	device claiming wifi_caps 0x1 (VWIRE) + 0x800 (MESHV3), which openUF does
	only with the wireless_uplink option on (openwrt/report.lua).

	The push, child = the device receiving it, 5 GHz radio = radio.2:

	  mesh.status=enabled  mesh.version=3
	  mesh.essid=vwire-<16 hex>      the site's connectivity.x_mesh_essid
	  mesh.psk=<32 chars>            the site's connectivity.x_mesh_psk
	  mesh.serial1=<parent MAC>      only while a priority-1 parent is set
	  connectivity.status=enabled  connectivity.uplink_wds=ath4 ...
	  wireless.<n>  mode=master  usage=downlink wds=enabled vwire=enabled
	                ssid=<mesh.essid> hide_ssid=true devname=vwire3, and its
	                aaa.<n> a WPA2-PSK block carrying the same PSK
	  wireless.<m>  mode=managed usage=uplink wds=enabled vport=enabled
	                ssid=vport-<own MAC> devname=ath4, aaa.<m>.status=disabled

	Both are classic 4-address WDS: a hidden WPA2-PSK AP a child joins with a
	4-address station, a transparent L2 pipe. Not 802.11s.
]]--

local wire = require("unifi.wire")

local M = {}

-- The `mesh` block, or nil when the push carries no mesh.* key at all (the
-- bits not claimed, or a partial push). status is false for anything but
-- "enabled".
---@param sys_raw string  system_cfg
---@return MeshIntent?
function M.parse(sys_raw)
	if type(sys_raw) ~= "string" then return nil end
	local mesh, seen = {}, false
	for line in (sys_raw .. "\n"):gmatch("([^\n]*)\n") do
		local k, v = line:match("^mesh%.([%w_]+)=(.*)$")
		if k then
			seen = true
			if k == "status" then mesh.status = (v == "enabled")
			elseif k == "essid" or k == "psk" or k == "serial1" then mesh[k] = v end
		end
	end
	if not seen then return nil end
	mesh.status = mesh.status == true
	return mesh
end

-- Whether one wireless.<n> block is a backhaul VAP rather than a WLAN, and
-- which side: "downlink" (the hidden AP children join), "uplink" (the
-- 4-address station toward a parent), or nil for an ordinary WLAN. Every
-- WLAN of a wired push carries mode=master and usage=user.
---@param w table<string,string>  one wireless.<n> block, keys without the prefix
---@return "downlink"|"uplink"|nil
function M.role(w)
	if type(w) ~= "table" then return nil end
	local backhaul = (w.mode ~= nil and w.mode ~= "master")
		or (w.usage ~= nil and w.usage ~= "user")
	if not backhaul then return nil end
	if w.usage == "downlink" or (w.mode == "master" and w.usage ~= "uplink") then
		return "downlink"
	end
	return "uplink"
end

-- One backhaul VAP as unifi/wlan.lua hands it over.
---@param role "downlink"|"uplink"
---@param w table<string,string>  wireless.<n>
---@param a table<string,string>  aaa.<n>
---@return BackhaulEntry
function M.entry(role, w, a)
	return {
		role    = role,
		radio   = w.parent,
		ssid    = w.ssid,
		devname = w.devname,
		-- The downlink carries the site PSK; the uplink's aaa block is
		-- disabled and keyless (the station uses mesh.psk).
		psk     = a and a["wpa.psk"] or nil,
		hidden  = wire.bool(w.hide_ssid),
	}
end

-- hostapd's and wpa_supplicant's own limits: 8..63 printable characters, or
-- the PSK itself as 64 hex digits. The key lands in UCI and their configs.
local function psk_ok(k)
	if type(k) ~= "string" or not k:match("^[ -~]+$") then return false end
	return (#k >= 8 and #k <= 63) or (#k == 64 and k:match("^%x+$") ~= nil)
end

local function devname_ok(d)
	return type(d) == "string" and d:match("^[%w_%.%-]+$") ~= nil and d or nil
end

-- What the device side writes: a downlink AP and/or an uplink station, or
-- nil when the push has no enabled mesh block with a usable ESSID and PSK,
-- or no backhaul entry. The station is planned ENABLED only while the device
-- is already on its wireless uplink (`wireless`), so a push to a wired
-- device never brings a second uplink up; openwrt/backhaul.lua switches it
-- when the wire goes.
---@param mesh MeshIntent?
---@param entries BackhaulEntry[]?
---@param wireless boolean?  the device is on its wireless uplink now
---@return BackhaulPlan?
function M.plan(mesh, entries, wireless)
	if type(mesh) ~= "table" or not mesh.status then return nil end
	if type(mesh.essid) ~= "string" or mesh.essid == "" or #mesh.essid > 32 then return nil end
	if not psk_ok(mesh.psk) then return nil end
	local plan = {}
	for _, e in ipairs(entries or {}) do
		if type(e) == "table" and type(e.radio) == "string" and e.radio ~= "" then
			if e.role == "downlink" and not plan.downlink then
				plan.downlink = {
					radio   = e.radio,
					ssid    = (type(e.ssid) == "string" and e.ssid ~= "" and #e.ssid <= 32)
						and e.ssid or mesh.essid,
					key     = psk_ok(e.psk) and e.psk or mesh.psk,
					-- The controller's own name for it (vwire3), reported back
					-- as the downlink VAP's `name`.
					devname = devname_ok(e.devname),
				}
			elseif e.role == "uplink" and not plan.uplink then
				plan.uplink = {
					radio   = e.radio,
					-- The station joins the mesh ESSID, not its own vport-<mac>
					-- name, and keys with mesh.psk (its aaa block is empty).
					ssid    = mesh.essid,
					key     = mesh.psk,
					devname = devname_ok(e.devname),
					enabled = wireless == true,
				}
			end
		end
	end
	if not plan.downlink and not plan.uplink then return nil end
	return plan
end

-- The controller's priority-1 parent (mesh.serial1), lower-cased, or "" when
-- the push names none. Only a fallback for naming the parent: it describes
-- the push's topology, not the BSS the station actually joined.
---@param mesh MeshIntent?
---@return string
function M.parent(mesh)
	local p = type(mesh) == "table" and mesh.serial1 or nil
	return wire.is_mac(p) and p:lower() or ""
end

-- The payload's top-level uplink fields for a wireless uplink, or nil.
-- Decompiled from 10.6.106's UAP inform processor (yesrab/openUF,
-- PROTOCOL-VALIDATION.md § Wireless uplink): `uplink` is a STRING, the name
-- of the uplink interface. Naming a vap_table entry of usage `uplink` takes
-- the wireless path, whose link is that VAP's one station (the parent's
-- downlink BSS, resolved by its `serialno`). An object here is read as the
-- default "eth0". uplink_bssid is stored verbatim. A wired uplink sends
-- nothing: the default "eth0" and the gateway's LLDP describe it, as before.
---@param link {name: string, bssid: string?}?
---@return table?
function M.uplink_fields(link)
	if type(link) ~= "table" or type(link.name) ~= "string" or link.name == "" then
		return nil
	end
	return {
		uplink       = link.name,
		uplink_bssid = wire.is_mac(link.bssid) and link.bssid:lower() or nil,
	}
end

return M
