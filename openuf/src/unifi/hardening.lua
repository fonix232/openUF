--[[
	hardening.lua -- the controller's L2 hardening rules (the ebtables.* block
	of system_cfg: no STP BPDUs and no VLAN-tagged frames from Wi-Fi
	clients), parsed into what openwrt/l2guard.lua enforces.
]]--

local M = {}

M.BGA = "01:80:c2:00:00:00"

-- ─── Parsing ─────────────────────────────────────────────────────────────────

-- The ebtables.* block, or nil when the blob carries none. Each recognised
-- shape lands in its list; anything else in `unknown`, verbatim, so a new
-- rule shape is visible rather than silently dropped.
---@param sys_raw string  system_cfg
---@return EbtablesRules?
function M.parse(sys_raw)
	if type(sys_raw) ~= "string" then return nil end
	local seen = false
	local out = {enabled = true, bpdu_in = {}, bpdu_out = {}, tag_in = {}, tag_vids = {}, unknown = {}}
	for line in (sys_raw .. "\n"):gmatch("([^\n]*)\n") do
		local k, v = line:match("^([^=]+)=(.*)$")
		if k == "ebtables.status" then
			seen = true
			out.enabled = (v == "enabled")
		elseif k and k:match("^ebtables%.%d+%.cmd$") then
			seen = true
			local dev = v:match("^%-t nat %-A PREROUTING %-%-in%-interface (%S+) %-d BGA %-j DROP$")
			if dev then
				out.bpdu_in[#out.bpdu_in + 1] = dev
			else
				dev = v:match("^%-t nat %-A POSTROUTING %-%-out%-interface (%S+) %-d BGA %-j DROP$")
				if dev then
					out.bpdu_out[#out.bpdu_out + 1] = dev
				else
					dev = v:match("^%-t broute %-A BROUTING %-i (%S+) %-p 802_1Q %-j DROP$")
					if dev then
						out.tag_in[#out.tag_in + 1] = dev
					else
						local vid = v:match("^%-t broute %-A BROUTING %-%-vlan%-id (%d+) %-p 802_1Q %-j DROP$")
						if vid then
							out.tag_vids[#out.tag_vids + 1] = tonumber(vid)
						else
							out.unknown[#out.unknown + 1] = v
						end
					end
				end
			end
		end
	end
	if not seen then return nil end
	return out
end

-- What to enforce, boiled down to the two device-wide booleans state.json
-- keeps: the controller emits the BPDU pair for every VAP and the tag drop
-- for the tagged one plus bridge-wide, so per-VAP bookkeeping adds nothing.
---@param parsed EbtablesRules?
---@return HardeningSpec
function M.spec_from(parsed)
	if type(parsed) ~= "table" or not parsed.enabled then
		return {bpdu = false, tagdrop = false}
	end
	return {
		bpdu    = (#parsed.bpdu_in > 0 or #parsed.bpdu_out > 0),
		tagdrop = (#parsed.tag_in > 0 or #parsed.tag_vids > 0),
	}
end

return M
