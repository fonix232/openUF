#!/bin/sh
#
# Give luci-app-usteer something to show in the test container, which has no
# Wi-Fi and no usteerd: an rpcd ucode plugin that answers as usteer's ubus
# object would (fixtures/usteer.uc), usteer's config and init script, and
# names/addresses in /etc/ethers for some of its clients so the page's host
# hints resolve like on a real AP.
#
#   sh test/fake-usteer.sh CONTAINER

set -eu

here=$(cd "$(dirname "$0")" && pwd)
name=$1

docker exec -i "$name" sh -c 'cat > /usr/share/rpcd/ucode/usteer.uc' < "$here/fixtures/usteer.uc"
docker exec -i "$name" sh -c 'cat > /etc/config/usteer' < "$here/fixtures/usteer.config"
docker exec -i "$name" sh -c 'cat > /etc/init.d/usteer && chmod 755 /etc/init.d/usteer' < "$here/fixtures/usteer.init"

docker exec -i "$name" sh -c '
	grep -q "^a4:83:e7:2f:91:0c " /etc/ethers 2>/dev/null || cat >> /etc/ethers
	/etc/init.d/rpcd restart
' <<'EOF'
a4:83:e7:2f:91:0c 192.168.1.142
a4:83:e7:2f:91:0c iPhone
3c:22:fb:7a:10:4e 192.168.1.118
3c:22:fb:7a:10:4e MacBook-Air
f0:18:98:44:c2:71 192.168.1.157
dc:a6:32:11:5e:9b 192.168.1.60
dc:a6:32:11:5e:9b octopi
50:02:91:a8:3c:17 shelly-plug-s
9c:b6:d0:e1:07:33 192.168.1.131
9c:b6:d0:e1:07:33 thinkpad-x1
EOF

echo "faked usteer"
