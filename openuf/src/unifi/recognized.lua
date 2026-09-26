--[[
	recognized.lua -- the controller's surface openUF understands: the
	system_cfg and mgmt_cfg keys some part of it reads, and the response
	types, top-level fields and commands it acts on. Everything else is
	reported as dropped or recorded in the unhandled ledger.
]]--

local M = {}

-- Key shapes some pass in openUF actually reads. Everything else in a config
-- blob is dropped on the floor.
--
-- Until 2026-07-18 that included macacl.* and qos.vap.* -- two whole features
-- sitting in every capture, unnoticed for months, because no tokenizer here
-- has an `else` branch and nothing ever counted what fell through. This list
-- plus _report_dropped_keys() is the missing feedback loop.
--
-- The keys openUF drops ON PURPOSE (switch.*, qos.if.*, qos.ebt.*, vlan.*,
-- bridge.*, mcastrate, cwm.mode, pmf.cipher, mac_acl.* and the other decoys)
-- are deliberately NOT listed here: they show up in the report, which is the
-- honest picture of what is ignored. Each one's reasoning is in
-- PROTOCOL-VALIDATION.md's `system_cfg` section.
M.RECOGNIZED_SYSTEM_CFG = {
	"^aaa%.%d+%.",       -- per-SSID security
	"^wireless%.%d+%.",  -- per-SSID radio binding and behavior
	"^radio%.%d+%.",     -- per-radio config
	"^stamgr%.%d+%.",    -- Minimum RSSI
	"^macacl%.%d+%.",    -- MAC Address Filter
	"^qos%.vap%.%d+%.",  -- WiFi Speed Limit
	"^netconf%.1%.",     -- IP Settings
	"^route%.1%.gateway$",
	"^dhcpc%.1%.",
	"^resolv%.nameserver%.%d+%.ip$",
	"^resolv%.host%.1%.name$",
	-- Per-port VLAN. Deliberately narrow: switch.dot1x.status and
	-- switch.jumboframes are in every capture and openUF implements neither,
	-- so they stay in the dropped-key report rather than being whitelisted
	-- along with the block they share a prefix with.
	"^switch%.status$",
	"^switch%.vlan%.status$",
	"^switch%.vlan%.%d+%.",
	"^switch%.port%.%d+%.",
	-- The L2 model the vlan_filtering backend renders (netmodel.lua).
	"^bridge%.",
	"^vlan%.%d+%.",
	"^netconf%.%d+%.",
	"^dhcpc%.%d+%.",
	-- Controller-managed system settings (sysconf.lua). cron.<n>.user is
	-- deliberately NOT here: the pushed account does not exist and the jobs
	-- run as root, so the key stays in the ledger as ignored.
	"^system%.timezone$",
	"^locale%.timezone$",
	"^ntpclient%.status$",
	"^ntpclient%.%d+%.",
	"^cron%.status$",
	"^cron%.%d+%.status$",
	"^cron%.%d+%.job%.%d+%.",
	-- The ebtables hardening block (l2guard.lua).
	"^ebtables%.status$",
	"^ebtables%.%d+%.cmd$",
}

M.RECOGNIZED_MGMT_CFG = {
	"^inform_url$", "^use_aes_gcm$", "^cfgversion$", "^led_enabled$", "^authkey$",
	"^stun_url$",
}

-- Set from handle_response when cfg.config.debug_dump_file is on -- the
-- dropped-key report is a diagnostic for exactly the same workflow (diffing
-- full captures against what openUF acts on), so it shares that gate rather
-- than adding a second knob.
M._debug_dropped_keys = false

-- Ceiling for that dump. It is append-only and the inform loop writes to it
-- every few seconds, so left on it grows without bound -- and its usual home
-- is /tmp, which on these boards is a RAM disk. Measured on an Archer C5 after
-- five weeks: 31.7 MB, 55% of a 59 MB tmpfs, on course to starve state.json
-- writes and apk alike. Past the cap the file RESTARTS rather than rotating:
-- keeping a second generation would double the peak footprint on exactly the
-- boards least able to afford it, and a capture is read from its tail anyway.
-- Override per device with config.debug_dump_max_bytes; 0 disables the cap.
M.DEBUG_DUMP_MAX_BYTES = 4 * 1024 * 1024

-- Every response _type the controller sends and the top-level fields openUF
-- reads on the ones that carry any. Anything else goes to unhandled.lua's
-- ledger (/etc/openuf/unhandled.json) with its body, always -- that file is
-- how a new controller verb gets noticed.
M.KNOWN_TYPES = {
	noop = true, setparam = true, cmd = true, upgrade = true, reboot = true,
	setdefault = true,
}
M.KNOWN_TOP_FIELDS = {
	noop     = {_type = true, interval = true, immediate = true, server_time_in_utc = true,
	            live_update = true, include_blocks = true, exclude_blocks = true,
	            fingerprint = true},
	setparam = {_type = true, mgmt_cfg = true, system_cfg = true, cfgversion = true,
	            server_time_in_utc = true, blocked_sta = true, include_blocks = true},
}
-- Commands with a handler below; everything else is ledgered with its body.
M.KNOWN_CMDS = {
	["set-locate"] = true, ["unset-locate"] = true, ["block-sta"] = true,
	["unblock-sta"] = true, ["kick-sta"] = true, ["spectrum-scan"] = true,
	["quick-scan"] = true,
}

return M
