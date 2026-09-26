-- Consistency between the package's pieces: the files the Makefile installs,
-- the copies the ASU first-boot script embeds, and the options the LuCI
-- settings page writes versus the ones the daemon reads.
-- Run from the package directory: lua tests/run_tests.lua

local config = dofile("src/config.lua")

local function read(p)
	local f = assert(io.open(p, "r"), p)
	local s = f:read("*a")
	f:close()
	return s
end

return {
	{
		name = "package: the first-boot script embeds the package's bootstrap service and feed key verbatim",
		fn = function()
			local fb = read("contrib/asu/openuf-firstboot.sh")
			local service = fb:match("cat > /etc/init.d/openuf%-bootstrap <<'SERVICE'\n(.-)\nSERVICE\n")
			assert_not_nil(service, "service heredoc found")
			assert_eq(service, (read("files/openuf-bootstrap.init"):gsub("\n+$", "")),
				"service drifted: copy files/openuf-bootstrap.init into openuf-firstboot.sh")
			assert_true(fb:find(read("files/feed/openuf.pem"):gsub("\n+$", ""), 1, true) ~= nil,
				"apk key drifted")
		end
	},
	{
		name = "package: the feed key, keep-list and Makefile agree on the key and repository files",
		fn = function()
			local mk, keep = read("Makefile"), read("files/openuf.keep")
			for _, path in ipairs({"/etc/apk/keys/openuf.pem", "/etc/apk/repositories.d/openuf.list"}) do
				assert_true(mk:find(path, 1, true) ~= nil, "Makefile installs " .. path)
				assert_true(keep:find(path, 1, true) ~= nil, "sysupgrade keeps " .. path)
			end
			for _, path in ipairs({"/etc/openuf/", "/etc/config/openuf",
					"/etc/init.d/openuf-bootstrap", "/etc/rc.d/S98openuf-bootstrap"}) do
				assert_true(keep:find(path, 1, true) ~= nil, "sysupgrade keeps " .. path)
			end
		end
	},
	{
		name = "package: every option the LuCI settings page writes is one the daemon reads",
		fn = function()
			local known = {}
			for _, o in ipairs(config.OPTIONS) do known[o[1]] = true end
			local js = read("../luci-app-openuf/htdocs/luci-static/resources/view/openuf/settings.js")
			local n = 0
			for name in js:gmatch("taboption%('[%w_]+', form%.[%w]+, '([%w_]+)'") do
				assert_true(known[name], "settings.js writes '" .. name .. "', which config.lua does not know")
				n = n + 1
			end
			for name in js:gmatch("flag%(s, '[%w_]+', '([%w_]+)'") do
				assert_true(known[name], "settings.js writes '" .. name .. "', which config.lua does not know")
				n = n + 1
			end
			assert_true(n >= 25, "the page's options were found (" .. n .. ")")
		end
	},
	{
		name = "package: the shipped UCI config parses to the daemon's defaults",
		fn = function()
			local s = {}
			for k, v in read("files/openuf.config"):gmatch("option ([%w_]+) '([^']*)'") do s[k] = v end
			assert_nil(s.modelmap, "no model map option")
			local c = config.options(s)
			assert_eq(c.inform_url, "http://unifi:8080/inform", "default inform URL")
		end
	},
	{
		name = "package: removal takes sysconf's marked cron block out of root's crontab, and nothing else",
		fn = function()
			-- The markers live in sysconf.lua and in the prerm's sed; a drifted
			-- one leaves a nightly job calling the syswrapper.sh the removal
			-- took away, or deletes the operator's lines after it. So the
			-- prerm's own expression runs on the block apply_cron writes.
			local prerm = read("Makefile"):match("define Package/openuf/prerm\n(.-)\nendef")
			assert_not_nil(prerm, "prerm found")
			local expr = prerm:match("sed %-i '(/%^# openuf%-cron%-begin/[^']*)' /etc/crontabs/root")
			assert_not_nil(expr, "the prerm edits root's crontab")
			expr = expr:gsub("%$%$", "$")   -- make's escape
			local sysconf = dofile("src/openwrt/sysconf.lua")
			local files = {[sysconf.CRONTAB] = "# mine\n30 3 * * * /usr/bin/backup.sh\n"}
			sysconf._read_file = function(p) return files[p] end
			sysconf._write_file = function(p, c) files[p] = c; return true end
			sysconf._exec = function() return 0 end
			local real = io.stderr
			io.stderr = {write = function() end}
			local ok = sysconf.apply_cron({enabled = true, jobs = {
				{schedule = "0 4 * * *", cmd = "syswrapper.sh 11k-scan", enabled = true}}})
			io.stderr = real
			assert_true(ok, "block written")
			local tmp = "/tmp/openuf_test_prerm_crontab"
			local f = assert(io.open(tmp, "w"))
			f:write(files[sysconf.CRONTAB], "15 2 * * * /usr/bin/after.sh\n")
			f:close()
			local p = assert(io.popen("sed -e '" .. expr .. "' " .. tmp))
			local out = p:read("*a")
			p:close()
			os.remove(tmp)
			assert_eq(out, "# mine\n30 3 * * * /usr/bin/backup.sh\n15 2 * * * /usr/bin/after.sh\n",
				"the block is gone, the lines around it stay")
		end
	},
	{
		name = "package: every install path the LuCI backend reads is a file the package ships",
		fn = function()
			local src = read("../luci-app-openuf/root/usr/share/rpcd/ucode/luci.openuf")
			local n = 0
			for rel in src:gmatch("%${OPENUF}/([%w_/%.%-]+)") do
				if rel ~= "BUILD" then   -- written at build time
					local f = io.open("src/" .. rel, "r")
					assert_not_nil(f, "the backend reads " .. rel .. ", which src/ does not have")
					if f then f:close() end
					n = n + 1
				end
			end
			assert_true(n >= 2, "found the backend's paths (" .. n .. ")")
		end
	},
}
