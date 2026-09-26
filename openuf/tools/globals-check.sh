#!/bin/sh
# Report every global a module reads or writes that is not standard Lua or
# one of openUF's few deliberate ones. A typo'd local, or a `local` declared
# after the function that uses it, compiles fine and fails only at runtime;
# luac's listing shows it as a GETGLOBAL.
#
#   sh tools/globals-check.sh        (from the package directory; exits 1 on findings)

LUAC=$(command -v luac5.1 || command -v luac || true)
[ -n "$LUAC" ] || { echo "globals-check: no luac" >&2; exit 2; }

# Lua 5.1's own, and openUF's deliberate globals: the test-mode switches, the
# lib.lua packet helper, and the `config`/`dev` pair local.lua works on.
ALLOWED='^(_G|_VERSION|arg|assert|collectgarbage|coroutine|debug|dofile|error|getfenv|getmetatable|io|ipairs|load|loadfile|loadstring|math|module|next|os|package|pairs|pcall|print|rawequal|rawget|rawset|require|select|setfenv|setmetatable|string|table|tonumber|tostring|type|unpack|xpcall|OPENUF_TEST_MODE|SYSWRAPPER_TEST_MODE|config|dev)$'

status=0
for f in $(find src -name '*.lua' | sort); do
	names=$("$LUAC" -l -p "$f" | sed -n 's/.*[GS]ETGLOBAL.*; \([A-Za-z_][A-Za-z0-9_]*\)$/\1/p' | sort -u \
		| grep -Ev "$ALLOWED")
	if [ -n "$names" ]; then
		echo "$f: $(echo $names)"
		status=1
	fi
done
[ $status = 0 ] && echo "globals-check: no stray globals"
exit $status
