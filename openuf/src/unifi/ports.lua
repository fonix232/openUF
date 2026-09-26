--[[
	ports.lua -- the controller's per-port configuration (the switch.* block
	of system_cfg): which VLANs each wired port carries.
]]--

local M = {}

-- Parse the `switch.*` block: per-port VLAN assignment.
--
-- Wire shape, fully mapped live 2026-07-19 by diffing system_cfg across five
-- states (see PROTOCOL-VALIDATION.md's `switch.*` section):
--
--   switch.status=enabled              -- gate, "disabled" until the DEVICE-level
--   switch.vlan.status=enabled         -- "Port VLAN" checkbox is ticked
--   switch.vlan.1.id=1                 -- <m> is a slot number, .id is the VLAN
--   switch.vlan.1.mode=untagged        -- the VLAN's device-wide default
--   switch.vlan.1.status=enabled
--   switch.vlan.2.id=20
--   switch.vlan.2.mode=tagged
--   switch.port.2.pvid=20              -- the port's untagged/native VLAN
--   switch.vlan.1.port.2.mode=tagged   -- the authoritative membership matrix:
--   switch.vlan.2.port.2.mode=untagged -- untagged | tagged | exclude
--
-- Both gates sit at "disabled" in the baseline, so -- unlike
-- wireless.<n>.mac_acl.* or radio.<n>.bcmc_l2_filter.status -- they are real
-- discriminators rather than decoys. Presence of the block is NOT the signal:
-- switch.port.<n>.name/.opmode are always emitted, one per the controller's
-- model-registry port count, and are inventory rather than control.
--
-- switch.port.<n> joins directly to port_table[].port_idx -- no devname
-- indirection, unlike macacl.*/qos.vap.*.
--
-- Returns nil when the blob carries no switch.* line at all (distinct from a
-- block that is present but gated off).
function M.parse(sys_raw)
	local seen = false
	local gate_switch, gate_vlan
	local slots, ports = {}, {}   -- slots keyed by wire slot <m>, ports by port_idx

	local function port(n)
		n = tonumber(n)
		ports[n] = ports[n] or {vlans = {}}
		return ports[n]
	end
	local function slot(m)
		m = tonumber(m)
		slots[m] = slots[m] or {members = {}}
		return slots[m]
	end

	for line in (sys_raw .. "\n"):gmatch("([^\n]*)\n") do
		if line:match("^switch%.") then
			seen = true
			-- The membership matrix must be tried BEFORE the generic
			-- switch.vlan.<m>.<key> pattern, which would otherwise swallow it
			-- with key="port.2.mode" -- the same ordering care qos.vap.<m>
			-- needs against qos.if/qos.ebt.
			local m, n, mode = line:match("^switch%.vlan%.(%d+)%.port%.(%d+)%.mode=(.*)$")
			if m then
				slot(m).members[tonumber(n)] = mode
			else
				local sm, skey, sval = line:match("^switch%.vlan%.(%d+)%.([^=]+)=(.*)$")
				if sm then
					slot(sm)[skey] = sval
				else
					local pn, pkey, pval = line:match("^switch%.port%.(%d+)%.([^=]+)=(.*)$")
					if pn then
						port(pn)[pkey] = pval
					elseif line:match("^switch%.vlan%.status=") then
						gate_vlan = line:match("=(.*)$")
					elseif line:match("^switch%.status=") then
						gate_switch = line:match("=(.*)$")
					end
				end
			end
		end
	end

	if not seen then return nil end

	-- Resolve slot numbers to real VLAN ids, and fold the membership matrix
	-- onto the ports it belongs to.
	local vlans = {}
	for _, s in pairs(slots) do
		local id = tonumber(s.id)
		if id then
			vlans[id] = {mode = s.mode, enabled = s.status == "enabled"}
			for pidx, mode in pairs(s.members) do
				port(pidx).vlans[id] = mode
			end
		end
	end

	local out = {
		enabled = (gate_switch == "enabled") and (gate_vlan == "enabled"),
		vlans   = vlans,
		ports   = {},
	}
	-- Keep only ports carrying an actual override. The name/opmode-only
	-- entries are inventory for every registry port and mean nothing.
	for idx, p in pairs(ports) do
		if p.pvid or next(p.vlans) then
			out.ports[idx] = {pvid = tonumber(p.pvid), vlans = p.vlans}
		end
	end
	return out
end

return M
