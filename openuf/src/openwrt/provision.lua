--[[
	provision.lua -- the controller's answers, carried out on the device:
	setparam config pushes (network, WiFi, per-port VLANs, system settings,
	L2 hardening, rate limits) and the commands (locate, kick, block,
	upgrade, set-inform, ...). Returns whether the caller should inform again
	at once.

	handle(ctx, ...) takes inform.lua's module table as ctx: the platform
	modules it works through, which tests replace, and inform.lua's own
	helpers (the dropped-key report, cfgversion settlement, ...).
]]--

local cjson      = require("cjson")
local wire       = require("unifi.wire")
local recognized = require("unifi.recognized")
local wlan       = require("unifi.wlan")
local is_mac, is_hex32 = wire.is_mac, wire.is_hex32

local M = {}

function M.handle(ctx, json_str, st, cfg)
	-- Tracks the config rather than latching on: a caller that stops passing
	-- debug_dump_file stops getting dropped-key reports too.
	ctx._debug_dropped_keys = not not (cfg and cfg.config and cfg.config.debug_dump_file)

	-- Untagged: the line shape every documented grep recipe expects.
	ctx._debug_append(cfg, nil, json_str)

	local ok, resp = pcall(cjson.decode, json_str)
	if not ok or type(resp) ~= "table" then
		return false
	end

	local _type = resp._type
	if not recognized.KNOWN_TYPES[_type] then
		ctx._ledger("response", tostring(_type), resp)
	end
	ctx._note_unknown_fields(resp)

	if _type == "noop" then
		-- The controller's next-inform interval for this device and its "come
		-- back now" flag. Bounded: a garbled value must not park the daemon.
		local iv = tonumber(resp.interval)
		if iv and iv >= 1 and iv <= 300 then ctx._next_interval = iv end
		if resp.immediate == true then ctx._immediate = true end
		return false
	end

	if _type == "setparam" then
		-- mgmt_cfg is a newline-delimited key=value string (real controller format,
		-- confirmed by amd989/unifi-gateway _parse_mgmt_cfg).
		local mgmt_raw = resp.mgmt_cfg
		local newly_adopted = false
		-- What this push is judged on (ctx._settle_cfgversion): the version we
		-- reported before it, and whether every apply step ran clean.
		local cfg_before = st.cfgversion
		local apply_ok = true
		if type(mgmt_raw) == "string" then
			for line in (mgmt_raw .. "\n"):gmatch("([^\n]*)\n") do
				local k, v = line:match("^([^=]+)=(.*)$")
				if k and v then
					if k == "inform_url" then
						-- NOT "mgmt_url" -- confirmed live against a real controller
						-- (2026-07-14) that mgmt_url is the web UI deep link
						-- (https://host:8443/manage/site/default), a completely
						-- different endpoint from the actual inform target.
						-- Aliasing the two here previously made the device
						-- overwrite its own working inform_url with the UI link on
						-- the very next routine setparam cycle after adoption,
						-- breaking the inform loop for good (http-only builds have
						-- no luasec, so switching to that https URL is fatal).
						if v ~= "" then st.inform_url = v end
					elseif k == "stun_url" then
						-- The controller's STUN service, where the device keeps the
						-- binding the controller wakes it through (stun.lua).
						if v ~= "" then st.stun_url = v end
					elseif k == "use_aes_gcm" then
						st.use_gcm = (v == "true")
					elseif k == "cfgversion" then
						if v ~= "" then st.cfgversion = v end
					elseif k == "led_enabled" then
						local enabled = (v == "true")
						st.led_enabled = enabled
						ctx._led.set_enabled(cfg and cfg.led, enabled)
					elseif k == "authkey" then
						-- Only trusted pre-adoption. Real L3 adoption has no SSH
						-- step at all (controller logs "skip SSH adoption" for
						-- L3-discovered devices) and delivers the new key this
						-- way instead -- confirmed against amd989/unifi-gateway's
						-- _parse_mgmt_cfg (which does exactly this, no SSH
						-- anywhere in that codebase) and live testing against a
						-- real controller. See PROTOCOL-VALIDATION.md. Restricted
						-- to the unadopted case: while unadopted the device is
						-- still using the well-known DEFAULT_KEY, so this
						-- exchange carries no less confidentiality than the rest
						-- of L3 provisioning already assumes. Once adopted, only
						-- SSH set-adopt may rotate the key (matches real L2
						-- hardware behavior).
						if not st.adopted and is_hex32(v) then
							st.authkey = v
							st.adopted = true
							newly_adopted = true
						elseif st.adopted and is_hex32(v) and v ~= st.authkey
							and st.authkey ~= ctx._state.DEFAULT_KEY then
							-- A rotation. This setparam decrypted under the
							-- current, secret key, so it is authenticated in a
							-- way the default-key adoption exchange is not; the
							-- controller pushes a new key whenever the one an
							-- inform arrived under differs from its x_authkey,
							-- and refusing it leaves the device on a key the
							-- controller may stop trying.
							st.authkey = v
							newly_adopted = true   -- re-inform now, under the new key
						end
					end
				end
			end
		end

		-- IP Settings (DHCP vs Static, in the real controller UI) arrive via
		-- system_cfg, not mgmt_cfg -- a separate flat OpenWrt-UCI-style
		-- key=value blob, confirmed live against a real controller (see
		-- PROTOCOL-VALIDATION.md). Only present when the controller is
		-- actually pushing a network-config change, not on every inform.
		ctx._report_dropped_keys("mgmt_cfg", mgmt_raw, recognized.RECOGNIZED_MGMT_CFG)

		-- blocked_sta: the site's COMPLETE blocked-client list, newline-joined,
		-- carried by the provisioning push on every (re)connect and by every
		-- full config. It is authoritative -- block-sta/unblock-sta are only
		-- the live deltas -- so a block or unblock issued while this AP was
		-- offline, or lost with state.json, converges here. Absent means
		-- "not part of this push", never "unblock everyone".
		if type(resp.blocked_sta) == "string" then
			local list, seen = {}, {}
			for mac in resp.blocked_sta:gmatch("[^%s,]+") do
				mac = mac:lower()
				if is_mac(mac) and not seen[mac] then
					seen[mac] = true
					list[#list + 1] = mac
				end
			end
			table.sort(list)
			local before = {}
			for _, m in ipairs(st.blocked_stas or {}) do before[tostring(m):lower()] = true end
			local same = true
			for _, m in ipairs(list) do if not before[m] then same = false end end
			local n_before = 0
			for _ in pairs(before) do n_before = n_before + 1 end
			if n_before ~= #list then same = false end
			if not same then
				st.blocked_stas = list
				ctx._state.save(st)
				ctx._firewall.reconcile(list)
				local ufuci = ctx._ucihelper
				for _, m in ipairs(list) do
					if not before[m] and ufuci and ufuci.disconnect_station then
						pcall(ufuci.disconnect_station, m)
					end
				end
			end
		end

		local sys_raw = resp.system_cfg
		if type(sys_raw) == "string" then
			ctx._report_dropped_keys("system_cfg", sys_raw, recognized.RECOGNIZED_SYSTEM_CFG)

			local ip, netmask, gateway
			local dhcp = false
			local device_name
			-- DNS servers, keyed by their wire index so the controller's
			-- ordering (primary/secondary) survives -- resolv.conf's order is
			-- the resolver's preference order, so it is load-bearing. Same
			-- index-keyed-then-sorted treatment as macacl's acl.<k> list.
			local dns_by_idx = {}
			for line in (sys_raw .. "\n"):gmatch("([^\n]*)\n") do
				local k, v = line:match("^([^=]+)=(.*)$")
				if k and v then
					local dns_idx = k:match("^resolv%.nameserver%.(%d+)%.ip$")
					if dns_idx then
						if v ~= "" then dns_by_idx[tonumber(dns_idx)] = v end
					elseif k == "netconf.1.ip" then ip = v
					elseif k == "netconf.1.netmask" then netmask = v
					elseif k == "route.1.gateway" then gateway = v
					elseif k == "dhcpc.1.status" then
						-- Only an enabled-ish value means DHCP. The key's
						-- presence alone used to set dhcp=true, so a
						-- hypothetical dhcpc.1.status=disabled alongside a
						-- netconf.1.ip would have misread a static push as
						-- DHCP and flushed the working static address. Every
						-- capture so far carries =enabled; this is defensive
						-- for the static-mode shape that hasn't been
						-- captured yet.
						dhcp = wire.bool(v) == true
					elseif k == "resolv.host.1.name" then
						-- The controller's own idea of this device's name
						-- (its local network hostname) -- already present
						-- in every capture (e.g. "U6IW" when never
						-- renamed). Reused as the WPS Device Name value
						-- when advertise_ap_name is on, since it's the
						-- only controller-assigned "AP name" string
						-- available on this wire protocol.
						if v ~= "" then device_name = v end
					end
				end
			end
			-- Flatten the index-keyed DNS table into controller order.
			local dns = {}
			do
				local idxs = {}
				for i in pairs(dns_by_idx) do idxs[#idxs + 1] = i end
				table.sort(idxs)
				for _, i in ipairs(idxs) do dns[#dns + 1] = dns_by_idx[i] end
			end

			-- Shape check BEFORE anything is recorded or run. These three
			-- values are interpolated into `ip addr` / `ip route` command
			-- lines by netconfig.lua (which refuses them again itself), and
			-- this is what keeps a malformed push out of state.json as well:
			-- with the record written first, a refused apply would still leave
			-- ip_mode=static and a bogus static_ip behind for the DHCP-revert
			-- logic to act on. Feature-detected, so a test double standing in
			-- for netconfig need not carry the validator.
			local ipv4 = ctx._netconfig.is_ipv4
			if ip and ipv4 and not (ipv4(ip)
					and (netmask == nil or netmask == "" or ipv4(netmask))
					and (gateway == nil or gateway == "" or ipv4(gateway))) then
				io.stderr:write(("inform: ignoring IP Settings push with a malformed "
					.. "address (ip=%q netmask=%q gateway=%q)\n"):format(
					tostring(ip), tostring(netmask), tostring(gateway)))
				ip = nil
			end

			-- The vlan_filtering backend (netmodel.lua): the controller's whole L2
			-- model -- bridges, VLANs, Management VLAN, port matrix, management
			-- addressing -- rendered as UCI on one filtering bridge, taking over
			-- whatever bridge held the sockets before. When it produces a plan
			-- the legacy IP-settings, per-VLAN-bridge and switchvlan passes below
			-- stand aside: they describe a different layout of the same ports.
			local netplan = nil
			-- Set when the controller's network could not be applied: every
			-- pass below that assumes a layout (addressing, the WiFi pass that
			-- attaches VAPs, per-port VLANs) stays out of it, and the push is
			-- not reported as applied.
			local net_blocked = false
			local nm = ctx._netmodel
			if nm and nm.backend(cfg) == "vlan_filtering" then
				local model = nm.parse(sys_raw)
				if model then
					local s = model.static
					if s and ipv4 and not (ipv4(s.ip or "")
							and (s.netmask == nil or s.netmask == "" or ipv4(s.netmask))
							and (s.gateway == nil or s.gateway == "" or ipv4(s.gateway))) then
						io.stderr:write("inform: netmodel: ignoring a malformed static address\n")
						model.static = nil
					end
					local lan = cfg and cfg.net and cfg.net.lan_cpueth
					local ok_br, br = pcall(ctx._sysinfo.bridge_of, lan)
					local up = nil
					if ok_br and br then
						local ok_up, u = pcall(ctx._sysinfo.uplink_bridge_port, br)
						if ok_up then up = u end
					end
					local ok_nm, changed, plan, outcome = pcall(nm.converge, model,
						ctx._parse_switch_system_cfg(sys_raw), cfg, st,
						{uplink_ifname = up, identity_mac = st.mac, current_ip = st.ip})
					if not ok_nm then
						io.stderr:write("inform: netmodel: " .. tostring(changed) .. "\n")
						apply_ok, net_blocked = false, true
					elseif outcome == "rejected" or outcome == "failed" then
						apply_ok, net_blocked = false, true
					elseif plan then
						netplan = plan
						-- The per-VLAN-bridge ledgers describe a layout that no
						-- longer exists; their restore paths must never run on it.
						st.dsa_brlan_ports, st.swvlan_backup = nil, nil
						st.ip_mode, st.static_ip, st.static_netmask = nil, nil, nil
						st.static_gateway, st.static_dns = nil, nil
						ip = nil   -- addressing is part of the plan, as UCI
						if changed then
							ctx._sysinfo.forget_uplink_cache()
							-- A new plan is only proven once its rollback window
							-- closes (ctx._netmodel_check).
							if type(st.netmodel_pending) == "table" then
								st.netmodel_pending.effective_before = st.cfgversion_effective
							end
							ctx._state.save(st)
						end
					end
				end
			end

			if net_blocked then
				io.stderr:write("inform: the controller's network was not applied; its"
					.. " addressing, WiFi and port settings wait for the next push\n")
				ip = nil
			end

			if ip then
				local iface = cfg and cfg.net and cfg.net.lan_cpueth
				if dhcp then
					-- Only genuinely ACT when reverting our own prior static
					-- config -- a fresh device's first-ever system_cfg (and
					-- every steady-state reaffirmation) also carries
					-- dhcpc.1.status=enabled, but real hardware already runs
					-- its own DHCP client continuously; flushing+re-leasing
					-- on every "still DHCP" push is needless and, worse,
					-- destructive wherever no DHCP server actually exists to
					-- grant a new lease (confirmed live: this validation
					-- container's Docker bridge has none -- udhcpc timed out
					-- and left the interface with no address at all).
					if st.ip_mode == "static" then
						ctx._netconfig.apply_dhcp(iface)
						ctx._populate_net_info(st, cfg)  -- re-read the freshly-leased address
					end
					st.ip_mode = "dhcp"
					st.static_ip, st.static_netmask, st.static_gateway = nil, nil, nil
					-- DNS is deliberately NOT touched here: the lease supplies
					-- it, and rewriting resolv.conf on every steady-state "still
					-- DHCP" push would fight the DHCP client for ownership --
					-- the same hazard as the flush+re-lease guarded above.
					st.static_dns = nil
				else
					st.ip_mode = "static"
					st.static_ip, st.static_netmask, st.static_gateway = ip, netmask, gateway
					st.static_dns = (#dns > 0) and dns or nil
					if ctx._netconfig.apply_static(iface, ip, netmask, gateway, dns) then
						st.ip = ip  -- known directly, no need to re-read the interface
					end
				end
				-- Persisted HERE, not at the end of handle_response.
				--
				-- The interface has already been reconfigured by this point,
				-- and state.json is the only record that it was: ctx.run's
				-- startup reapply is what puts a static address back after a
				-- reboot, and it reads exactly these fields. Everything
				-- between here and the save at the end of this function --
				-- the WiFi pass, switchvlan, usteer, bcfilter, shaper -- shells
				-- out or reaches into UCI and can raise, and _tick pcalls this
				-- whole function by design, so an error there costs one log
				-- line and nothing else. Leaving the write until the end meant
				-- any such error left the kernel reconfigured and the record
				-- lost, which is precisely the state the reapply cannot
				-- recover from.
				--
				-- Observed exactly that in the validation lab on 2026-09-10:
				-- usteer raised midway, the AP moved to its pushed static
				-- address, and state.json never learned about it.
				ctx._state.save(st)
			end

			-- Parsed once, out here: the switch pass below needs the vap_table
			-- too (for the VLANs tagged SSIDs sit on), and scoping it inside
			-- the wifi branch left that consumer reading a nil table -- an
			-- empty trunk list that fails silently.
			local radio_table, vap_table = ctx._parse_wifi_system_cfg(sys_raw)

			-- VLANs that a WIRED port is assigned to. Computed before the
			-- WiFi pass because their L2 is the same bridge a tagged SSID
			-- uses, and apply_config prunes any bridge no WLAN wants --
			-- which would delete the one a per-port assignment is about to
			-- need, on every push, then have switchvlan rebuild it. DSA
			-- only: on swconfig a port VLAN is a switch table entry, not a
			-- bridge. Safe when nothing is pushed (an empty set).
			local port_vlans = {}
			if not netplan and not net_blocked and ctx._switchvlan and ctx._switchvlan.dsa_members
				and not (cfg and cfg.vlan and cfg.vlan.ports) then
				local br = ctx._sysinfo.bridge_of(cfg and cfg.net and cfg.net.lan_cpueth)
				local up = br and ctx._sysinfo.uplink_bridge_port(br) or nil
				local ok_pv, m = pcall(ctx._switchvlan.dsa_members,
					ctx._parse_switch_system_cfg(sys_raw), cfg, up)
				if ok_pv then
					for vid in pairs(m or {}) do port_vlans[vid] = true end
				end
			end

			local ufuci = ctx._ucihelper
			if ufuci and ufuci.apply_config and not net_blocked then
				if #radio_table > 0 or #vap_table > 0 then
					-- Band Steering (wireless.<n>.no2ghz_oui) is confirmed
					-- live to be a per-WLAN wire field, not a per-device
					-- one -- but usteer (the daemon that actually
					-- implements steering on OpenWrt) is a single
					-- device-wide config, so band steering is treated as
					-- active for the whole device whenever ANY WLAN has it
					-- enabled.
					local steering_active = false
					for _, vap in ipairs(vap_table) do
						if vap.no2ghz_oui then steering_active = true end
					end
					ctx._usteer.set_enabled(steering_active, cfg)
					local ok_ac, err_ac = pcall(ufuci.apply_config,
						{radio_table = radio_table, vap_table = vap_table, network_table = {}},
						cfg, {band_steering_active = steering_active,
							device_name = device_name, keep_vlans = port_vlans,
							netmodel = netplan})
					if not ok_ac then
						io.stderr:write("inform: WiFi config failed: " .. tostring(err_ac) .. "\n")
						apply_ok = false
					end
				end
			end

			-- Per-port VLAN, after the WiFi pass so that any VLAN interface
			-- ensure_vlan_network() creates for a tagged SSID already exists
			-- before a switch port is put on the same VLAN.
			if ctx._switchvlan and not netplan and not net_blocked then
				local ok_sv, err_sv = pcall(function()
					-- Every VLAN a tagged SSID lands on. The switch drops
					-- frames for a VID it has no entry for, so these need
					-- trunking whether or not per-port VLAN is in use.
					local wireless_vlans, seen = {}, {}
					for _, vap in ipairs(vap_table or {}) do
						if vap.vlan_enabled and vap.vlan and not seen[vap.vlan] then
							seen[vap.vlan] = true
							wireless_vlans[#wireless_vlans + 1] = vap.vlan
						end
					end
					-- Which socket the uplink cable is in, so a pushed port
					-- VLAN can never be applied to it (see physical_port).
					-- Asked of whichever source this board has: the switch's
					-- ARL table on swconfig, the bridge FDB on DSA.
					local uplink_phys, uplink_ifname = nil, nil
					if cfg and cfg.vlan and cfg.vlan.ports then
						local swst = ctx._sysinfo.switch_status(cfg.vlan.device)
						uplink_phys = ctx._sysinfo.uplink_phys_port(swst.arl)
					else
						local br = ctx._sysinfo.bridge_of(cfg and cfg.net and cfg.net.lan_cpueth)
						if br then uplink_ifname = ctx._sysinfo.uplink_bridge_port(br) end
					end
					local sw = ctx._parse_switch_system_cfg(sys_raw)
					-- Turning Port VLAN off does not always announce itself.
					-- The gates were once observed staying on the wire at
					-- =disabled, but a device that has HAD the feature on and
					-- then has it unticked gets a full system_cfg with no
					-- switch.* keys at all -- confirmed live on the AX3000T,
					-- where the teardown therefore never ran and br-lan kept
					-- openUF's port list forever.
					--
					-- So absence counts as off too, but only when openUF holds
					-- a reversibility ledger: that is proof it applied
					-- something, which in turn is proof the controller was
					-- sending switch.* until now. With no ledger there is
					-- nothing to undo and this is a no-op anyway. Safe on a
					-- partial push -- the worst case is a restore to stock
					-- that the next full push re-applies -- and it cannot
					-- flap, since restore() spends the ledger. Reachable only
					-- inside `type(sys_raw) == "string"`, never on a noop.
					local had_applied = st.swvlan_backup ~= nil
						or st.dsa_brlan_ports ~= nil
					if (sw and not sw.enabled) or (sw == nil and had_applied) then
						-- Explicit disable: unticking the device-level "Port
						-- VLAN" box keeps the switch.* block on the wire with
						-- both gates at =disabled (confirmed live -- the
						-- baseline capture carries them that way). Tear our
						-- sections down and put the stock port strings back,
						-- or the switch stays segmented forever after the
						-- user turns the feature off. A blob with no switch.*
						-- lines at all (sw == nil: older controller, partial
						-- push) still leaves everything alone -- restore only
						-- ever runs on an affirmative off signal, and its own
						-- empty-ledger no-op keeps steady-state disabled
						-- pushes free of switch reloads.
						-- ...unless a tagged SSID still needs its VLAN
						-- trunked. restore() puts the stock port strings
						-- back and drops every openuf section, which would
						-- take the wireless trunk with it and silently kill
						-- the IoT WLAN's uplink. apply() reconciles both
						-- concerns in one pass.
						--
						-- That hazard is SWCONFIG-ONLY, and gating on the
						-- wireless VLANs alone got it wrong on DSA: there the
						-- tagged SSID needs no trunk at all and its bridge
						-- belongs to ucihelper, so restore() cannot harm it --
						-- it only hands br-lan its original port list back.
						-- Skipping restore there meant the reversibility
						-- ledger was never spent and br-lan kept the port
						-- ORDER openUF had left it in, so unticking Port VLAN
						-- looked like it had done nothing.
						if (cfg and cfg.vlan and cfg.vlan.ports)
							and #wireless_vlans > 0 then
							ctx._switchvlan.apply(sw, cfg, st, wireless_vlans,
								uplink_phys, uplink_ifname)
						else
							ctx._switchvlan.restore(st, cfg)
						end
					else
						ctx._switchvlan.apply(sw, cfg, st, wireless_vlans,
							uplink_phys, uplink_ifname)
					end
					-- Either branch may have moved a socket into or out of a
					-- VLAN bridge, which is the one thing bridge_of's 300 s TTL
					-- cannot notice on its own.
					ctx._sysinfo.forget_uplink_cache()
				end)
				if not ok_sv then
					io.stderr:write("inform: per-port VLAN failed: " .. tostring(err_sv) .. "\n")
					apply_ok = false
				end
			end

			-- Controller-managed system settings: timezone, NTP servers and
			-- the nightly `syswrapper.sh 11k-scan` cron job (sysconf.lua),
			-- gated by the system_timezone / system_ntp / system_cron options.
			local gate = cfg and cfg.config and cfg.config.controller_system
			if ctx._sysconf and gate ~= false then
				local ok_sc, err_sc = pcall(function()
					local sc = ctx._sysconf.parse(sys_raw)
					if sc then ctx._sysconf.apply(sc, gate) end
				end)
				if not ok_sc then
					io.stderr:write("inform: system settings failed: " .. tostring(err_sc) .. "\n")
					apply_ok = false
				end
			end

			-- The ebtables.* hardening block (l2guard.lua): BPDU and VLAN-tag
			-- drop on every AP VAP. Kernel state, so the intent and the VAP
			-- names go to state.json for the startup rebuild. After the WiFi
			-- pass on purpose: a VAP the push just added has its netdev by now.
			if ctx._l2guard and not (cfg and cfg.config and cfg.config.l2guard == false) then
				local ok_l2, err_l2 = pcall(function()
					local eb = ctx._l2guard.parse(sys_raw)
					if not eb then return end
					for _, u in ipairs(eb.unknown or {}) do
						io.stderr:write("l2guard: unrecognised ebtables rule shape, not applied: "
							.. ("%q"):format(u) .. "\n")
					end
					local spec = ctx._l2guard.spec_from(eb)
					local names = (ctx._ucihelper and ctx._ucihelper.all_vap_ifnames)
						and ctx._ucihelper.all_vap_ifnames() or {}
					if #names == 0 and st.l2guard and type(st.l2guard.ifnames) == "table" then
						names = st.l2guard.ifnames   -- wireless not answering yet: last known
					end
					spec.ifnames = names
					st.l2guard = spec
					ctx._l2guard.reconcile(spec, names)
					-- A push lands mid `wifi reload`, before the VAPs exist: try
					-- again on a later heartbeat instead of waiting for the
					-- next push, which may be days away.
					ctx._l2guard_retry = (#names == 0) and (spec.bpdu or spec.tagdrop) or nil
				end)
				if not ok_l2 then
					io.stderr:write("inform: L2 hardening failed: " .. tostring(err_l2) .. "\n")
					apply_ok = false
				end
			end
		end

		if type(sys_raw) == "string" then
			ctx._settle_cfgversion(st, cfg, cfg_before, apply_ok)
		end
		ctx._state.save(st)
		-- Re-inform at once after adopting (new key) and after applying a
		-- config push: the controller holds the device in PROVISIONING until it
		-- sees its cfgversion echoed, and real firmware reports straight back.
		return newly_adopted or type(sys_raw) == "string"
	end

	if _type == "setdefault" then
		-- Controller requested factory reset.  Reset state on disk and in-memory.
		io.stderr:write("inform: controller requested factory reset\n")
		-- mac/ip/hostname are populated once at ctx.run() startup by
		-- _populate_net_info and never persisted to state.json -- preserve them
		-- across the reset rather than losing the device's identity mid-run.
		local mac, ip, hostname = st.mac, st.ip, st.hostname
		local fresh = ctx._state.reset()
		for k in pairs(st) do st[k] = nil end
		for k, v in pairs(fresh) do st[k] = v end
		st.mac, st.ip, st.hostname = mac, ip, hostname
		ctx._sync_bootstrap_account(false, cfg and cfg.config and cfg.config.bootstrap_adopt_user)
		ctx._firewall.reconcile(st.blocked_stas)
		return false
	end

	if _type == "reboot" then
		io.stderr:write("inform: controller requested reboot\n")
		os.execute("reboot")
		os.exit(0)
	end

	if _type == "upgrade" then
		-- Store only -- never download/verify/flash/reboot. A real controller's
		-- upgrade URL targets genuine Ubiquiti firmware; applying it to this
		-- (non-Ubiquiti) hardware would brick it. See amd989/unifi-gateway,
		-- which handles this identically (log + store, no real upgrade path).
		st.upgrade_requested_version = tostring(resp.version or "")
		st.upgrade_requested_url     = tostring(resp.url or "")
		-- The catalogue version the controller wants this model on, reported
		-- from now on: the controller calls a device upgradable whenever its
		-- version differs from the catalogue's by so much as a character, so a
		-- stale built-in version meant a permanent Upgrade badge (upgrade.lua).
		local wanted = type(resp.version) == "string" and resp.version:match("^%d+%.%d+%.%d+%.%d+$")
		if wanted then st.fw_version = wanted end
		-- config.upgrade_mode = "owut": the controller's upgrade becomes an
		-- attended sysupgrade of THIS board's OpenWrt (upgrade.lua). The UniFi
		-- URL itself is never fetched.
		local conf = cfg and cfg.config
		if conf and conf.upgrade_mode == "owut" then
			local ok_u, started, why = pcall(ctx._upgrade.start, conf)
			io.stderr:write("inform: upgrade requested -- "
				.. ((ok_u and started) and ("owut upgrade started, log in " .. ctx._upgrade.LOG_FILE)
					or ("not upgrading: " .. tostring(ok_u and why or started))) .. "\n")
		else
			io.stderr:write("inform: upgrade requested (version=" .. st.upgrade_requested_version
				.. ") -- stored only, not applying\n")
		end
		ctx._state.save(st)
		return false
	end

	if _type == "cmd" then
		local cmd = resp.cmd or ""
		io.stderr:write("inform: cmd: " .. tostring(cmd) .. "\n")
		if not recognized.KNOWN_CMDS[cmd] then ctx._ledger("cmd", tostring(cmd), resp) end

		if cmd == "set-locate" or cmd == "unset-locate" then
			local led_path = cfg and cfg.led
			if cmd == "set-locate" then
				-- The trigger the LED was on is persisted, not just held in
				-- memory: the controller sends set-locate and unset-locate as
				-- two independent commands with nothing bounding the gap, so
				-- a restart can easily land between them, and only this copy
				-- then knows what to put back. See ctx.run's startup handling.
				local _, prev = ctx._led.locate_start(led_path)
				st.locate_prev_trigger = prev
			else
				ctx._led.locate_stop(led_path, st.locate_prev_trigger)
				st.locate_prev_trigger = nil
				-- Restoring the TRIGGER is not the whole idle state. An LED
				-- whose normal look is "trigger none, brightness on" -- which
				-- is exactly what set_enabled leaves behind, and what a
				-- dedicated status LED like blue:status or green:system sits
				-- at -- comes back from a Locate on trigger none and
				-- brightness 0, i.e. dark. So re-assert the steady state the
				-- operator actually chose, the same way ctx.run does at
				-- startup. nil means never pushed: leave the board alone.
				if st.led_enabled ~= nil then
					ctx._led.set_enabled(led_path, st.led_enabled)
				end
			end
			st.locating = (cmd == "set-locate")
			ctx._state.save(st)
		elseif cmd == "block-sta" or cmd == "unblock-sta" then
			-- One-shot command, confirmed live: block/unblock never appears
			-- as a persistent field on any inform response (a candidate
			-- top-level `include_blocks` list stays empty even while a
			-- client is genuinely blocked) -- the device itself is expected
			-- to remember the block, the same way real hardware would.
			-- Persisted in state.blocked_stas and re-applied at ctx.run()
			-- startup (ctx._firewall.reconcile), so it survives a restart.
			local mac = resp.mac
			if type(mac) == "string" then
				st.blocked_stas = st.blocked_stas or {}
				if cmd == "block-sta" then
					local already = false
					for _, m in ipairs(st.blocked_stas) do
						if m == mac then already = true break end
					end
					if not already then
						st.blocked_stas[#st.blocked_stas + 1] = mac
					end
				else
					local kept = {}
					for _, m in ipairs(st.blocked_stas) do
						if m ~= mac then kept[#kept + 1] = m end
					end
					st.blocked_stas = kept
				end
				ctx._state.save(st)
				ctx._firewall.reconcile(st.blocked_stas)
				if cmd == "block-sta" then
					-- Kick it immediately if it's currently associated --
					-- the nft drop rule alone stops future traffic, but
					-- doesn't tear down an existing association.
					local ufuci = ctx._ucihelper
					if ufuci and ufuci.get_radio_table then
						local ok_r, radios = pcall(ufuci.get_radio_table)
						if ok_r then
							local ifnames = {}
							for _, radio in ipairs(radios) do
								local ok_if, ifname = pcall(ufuci.get_ifname_for_radio, radio.name)
								if ok_if and ifname then ifnames[#ifnames + 1] = ifname end
							end
							ctx._firewall.deauth(mac, ifnames)
						end
					end
				end
			end
		elseif cmd == "kick-sta" then
			-- "Reconnect Client": drop the association, allow it straight back.
			local mac = type(resp.mac) == "string" and resp.mac:lower() or nil
			local ufuci = ctx._ucihelper
			if is_mac(mac) and ufuci and ufuci.disconnect_station then
				pcall(ufuci.disconnect_station, mac)
			end
		elseif cmd == "spectrum-scan" or cmd == "quick-scan" then
			-- quick-scan is the RF Environment view's own "Scan"; openUF runs
			-- the same sweep for both.
			-- Trigger a scan per radio (sweeps every channel), then read back
			-- per-channel survey data and build a spectrum_table entry per
			-- radio, cached for the next build_json() call.
			--
			-- Field names (spectrum_table/spectrum_table_time/
			-- spectrum_scan_timestamp/channel/center_freq/width/utilization/
			-- interference) are confirmed against the real UniFi Network
			-- Application's own Java bytecode (10.4.57's ace.jar/
			-- internal-dependencies.jar constant pool -- see
			-- PROTOCOL-VALIDATION.md's radio_table_stats reference), not
			-- guessed. The exact numeric semantics of `width` and
			-- `interference` are still a best-effort approximation (radio's
			-- configured htmode, and raw noise-floor dBm, respectively) --
			-- verify against a live controller capture before trusting the
			-- values, not just the key names.
			local ufuci = ctx._ucihelper
			if ufuci and ufuci.get_radio_table then
				local ok_r, radios = pcall(ufuci.get_radio_table)
				if ok_r then
					local now = os.time()
					for _, radio in ipairs(radios) do
						local ok_if, ifname = pcall(ufuci.get_ifname_for_radio, radio.name)
						if ok_if and ifname then
							-- Survey counters are cumulative and exist
							-- independently of the sweep, so sample them BEFORE
							-- it as well: immediately after a scan the radio has
							-- just come back from off-channel and the OPERATING
							-- channel's noise reads as 0 -- confirmed on real
							-- hardware, where the same channel reports 0 right
							-- after the sweep and -106 dBm moments later. 0 dBm
							-- is not a plausible noise floor, and this value is
							-- reported to the controller as `interference`.
							local pre_noise = {}
							local ok_pre, pre_stats = pcall(ctx._sysinfo.radio_stats, ifname)
							if ok_pre then
								for _, s in ipairs(pre_stats) do
									if s.freq and s.noise and s.noise ~= 0 then
										pre_noise[s.freq] = s.noise
									end
								end
							end
							ufuci._popen("iw dev " .. ifname .. " scan")
							local ok_rs, stats = pcall(ctx._sysinfo.radio_stats, ifname)
							if ok_rs then
								local width = wlan.width_from_htmode(radio.ht)
								local table_entries = {}
								for _, s in ipairs(stats) do
									local total = s.channel_time or 0
									local busy  = s.channel_time_busy or 0
									table_entries[#table_entries + 1] = {
										channel     = ctx._sysinfo.channel_from_freq(s.freq),
										center_freq = s.freq,
										width       = width,
										utilization = total > 0 and math.floor(busy * 100 / total) or 0,
										-- Post-sweep 0 falls back to the
										-- pre-sweep reading for that frequency.
										interference = (s.noise ~= 0 and s.noise)
											or pre_noise[s.freq] or 0,
									}
								end
								ctx._spectrum_cache[radio.name] = {
									table          = table_entries,
									table_time     = now,
									scan_timestamp = now,
								}
							end
						end
					end
				end
			end
		end
		-- other cmd values (e.g. mfi-output, restart): no-op
		--
		-- Per fxkr/unifi-protocol-reverse-engineering's documented inform
		-- semantics: "Upon receiving a command message, an AP will execute a
		-- command and then send another inform immediately" -- regardless of
		-- which cmd it was, including ones we treat as a no-op. Matches the
		-- cfgversion branch below, which already does this correctly.
		return true
	end

	-- Config update: check cfgversion. WiFi config itself is applied from
	-- system_cfg above, not here -- a real controller never sends the
	-- resp.vap_table/radio_table/network_table JSON this branch used to gate
	-- on, so all that is left to do is record the version we have caught up to.
	if type(resp.cfgversion) == "string" and resp.cfgversion ~= st.cfgversion then
		st.cfgversion = resp.cfgversion
		ctx._state.save(st)
		return true  -- signal: send follow-up inform immediately
	end

	return false
end

return M
