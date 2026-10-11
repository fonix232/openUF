--[[
	Small helpers the device-side modules share.
]]--

local M = {}

-- Whether os.execute's result means success. Lua 5.1, the target, returns
-- the raw exit status: 0 for success and a non-zero number for failure, both
-- truthy, so a bare `if os.execute(...)` takes every failure for success.
-- 5.2+ returns true (or nil) first. Anything else is a failure.
function M.exec_ok(status)
	return status == true or status == 0
end

-- Exactly "aa:bb:cc:dd:ee:ff": what may be spliced into an nft script.
function M.is_mac(s)
	return type(s) == "string" and s:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

-- A netdev name safe to splice into a script line.
function M.valid_ifname(s)
	return type(s) == "string" and #s <= 15 and s:match("^[%w%-%._]+$") ~= nil
end

-- Run an nft script (`nft -f`) through exec, the caller's os.execute seam.
-- quiet discards nft's error text. True when nft accepted all of it.
function M.nft_run(script, exec, quiet)
	local path = os.tmpname()
	local f = io.open(path, "w")
	if not f then return false end
	f:write(script)
	f:close()
	local ok = M.exec_ok((exec or os.execute)("nft -f " .. path .. (quiet and " 2>/dev/null" or "")))
	os.remove(path)
	return ok
end

--[[
	Replace the nft table(s) tables (a name such as "bridge openuf", or a list
	of them) with fresh ones holding stmts: nft commands without the leading
	`nft` and without shell quoting ("add rule bridge openuf block ether saddr
	@blocked_macs drop"). nil stmts only deletes. exec is the caller's
	os.execute seam.

	One `nft -f`, one transaction: the old table goes and the new one comes in
	the same commit, so the traffic it filters never sees a gap with no
	table, and one fork replaces one per command. `add table` before `delete
	table` makes the delete succeed whether or not the table exists.

	The transaction is all or nothing, and the modules want what they have
	always had when a rule cannot be installed (on an image without
	kmod-nft-bridge, typically): every other rule in place, and a warning
	naming the one that is not. So when the batch fails, the statements are
	re-run one at a time, with nft's own error text going to the log.
	Returns ok, failed: failed[i] is true for each rejected stmts[i].
]]--
function M.nft_apply(tables, stmts, exec)
	if type(tables) ~= "table" then tables = {tables} end
	local clear, create = {}, {}
	for _, t in ipairs(tables) do
		clear[#clear + 1] = "add table " .. t .. "\ndelete table " .. t .. "\n"
		create[#create + 1] = "add table " .. t .. "\n"
	end
	clear, create = table.concat(clear), table.concat(create)
	if not stmts then return M.nft_run(clear, exec, true), {} end
	local body = #stmts > 0 and table.concat(stmts, "\n") .. "\n" or ""
	if M.nft_run(clear .. create .. body, exec, true) then return true, {} end
	M.nft_run(clear, exec, true)
	M.nft_run(create, exec)
	local ok, failed = true, {}
	for i, s in ipairs(stmts) do
		if not M.nft_run(s .. "\n", exec) then
			ok = false
			failed[i] = true
		end
	end
	return ok, failed
end


return M
