#!/usr/bin/env python3
"""Request an OpenWrt image with openUF from an Attended SysUpgrade server.

The image carries packages.txt and openuf-firstboot.sh (as the first-boot
uci-defaults script), with the script's settings filled in from the command
line. Standard library only.

  # target/profile/version from a running device
  contrib/asu/asu-build.py --from-device root@192.0.2.3 \\
      --inform-url http://192.0.2.1:8080/inform --bridge-backend vlan_filtering

  # or spelled out
  contrib/asu/asu-build.py --target mediatek/mt7622 --profile linksys_e8450-ubi \\
      --version SNAPSHOT --inform-url http://192.0.2.1:8080/inform

  # print the request instead of sending it
  contrib/asu/asu-build.py ... --dry-run

For an image that also keeps everything else already installed on a device,
run `owut upgrade -a "$(grep -v '^#' packages.txt | xargs)" -I openuf-firstboot.sh`
on the device instead -- owut knows the installed package set, this tool does not.
"""

import argparse
import json
import pathlib
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
DEFAULT_SERVER = "https://sysupgrade.openwrt.org"


def packages(path):
    out = []
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            out.append(line)
    return out


def firstboot(path, settings):
    """The first-boot script with its Settings block filled in.

    Only lines between the "# ─── Settings" marker and the next "# ───" rule
    are touched (the script repeats the names further down), and a comment is
    always separated by whitespace: in sh, `VAR="x"# note` makes "# note" part
    of the value, not a comment.
    """
    lines, inside = [], False
    for line in path.read_text().splitlines():
        if line.startswith("# ─── Settings"):
            inside = True
        elif inside and line.startswith("# ───"):
            inside = False
        elif inside:
            for key, value in settings.items():
                if value is not None and line.startswith(key + "="):
                    if any(c in value for c in "\"$`\\\n"):
                        sys.exit(f"{key}: value must not contain quotes, $, backquotes or newlines")
                    comment = line[line.index("#"):] if "#" in line else ""
                    line = (f'{key}="{value}"'.ljust(31) + " " + comment).rstrip()
        lines.append(line)
    return "\n".join(lines) + "\n"


def device_facts(ssh_target):
    board = json.loads(subprocess.check_output(
        ["ssh", "-o", "BatchMode=yes", ssh_target, "ubus call system board"], text=True))
    release = board.get("release", {})
    return {
        "target": release.get("target"),
        "profile": board.get("board_name", "").replace(",", "_"),
        "version": release.get("version"),
    }


def call(server, method, path, body=None):
    req = urllib.request.Request(
        server.rstrip("/") + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Content-Type": "application/json", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except ValueError:
            return e.code, {"detail": str(e)}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--server", default=DEFAULT_SERVER)
    ap.add_argument("--from-device", metavar="SSH_TARGET",
                    help="read target/profile/version from `ubus call system board`")
    ap.add_argument("--target")
    ap.add_argument("--profile")
    ap.add_argument("--version")
    ap.add_argument("--packages", type=pathlib.Path, default=HERE / "packages.txt")
    ap.add_argument("--extra", default="", help="more packages, space-separated")
    ap.add_argument("--script", type=pathlib.Path, default=HERE / "openuf-firstboot.sh")
    ap.add_argument("--repo", help="OPENUF_REPO")
    ap.add_argument("--ref", help="OPENUF_REF (latest, a tag, branch:<name>)")
    ap.add_argument("--sha256", help="OPENUF_SHA256")
    ap.add_argument("--url", help="OPENUF_URL (a mirror)")
    ap.add_argument("--inform-url", help="INFORM_URL")
    ap.add_argument("--modelmap", help="MODELMAP")
    ap.add_argument("--bridge-backend", choices=["auto", "vlan_filtering", "bridges"])
    ap.add_argument("--l2-announce", choices=["0", "1"])
    ap.add_argument("--ssh-adopt", choices=["0", "1"],
                    help="SSH_ADOPT: 1 = temporary ubnt/ubnt account for SSH (L2) adoption")
    ap.add_argument("--ap-mode", choices=["0", "1"],
                    help="AP_MODE: 1 = a fresh board boots as a bridge with no SSIDs, ready to adopt")
    ap.add_argument("--rootfs-size", type=int, help="rootfs_size_mb (READ the ASU docs first)")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    facts = device_facts(a.from_device) if a.from_device else {}
    target = a.target or facts.get("target")
    profile = a.profile or facts.get("profile")
    version = a.version or facts.get("version")
    if not (target and profile and version):
        ap.error("need --target, --profile and --version (or --from-device)")

    script = firstboot(a.script, {
        "OPENUF_REPO": a.repo, "OPENUF_REF": a.ref, "OPENUF_SHA256": a.sha256,
        "OPENUF_URL": a.url, "INFORM_URL": a.inform_url, "MODELMAP": a.modelmap,
        "BRIDGE_BACKEND": a.bridge_backend, "L2_ANNOUNCE": a.l2_announce,
        "AP_MODE": a.ap_mode, "SSH_ADOPT": a.ssh_adopt,
    })
    body = {
        "target": target, "profile": profile, "version": version,
        "packages": packages(a.packages) + a.extra.split(),
        "defaults": script, "client": "openuf-asu-build/1",
    }
    if a.rootfs_size:
        body["rootfs_size_mb"] = a.rootfs_size
    if len(script.encode()) > 40960:
        sys.exit(f"first-boot script is {len(script.encode())} bytes; the public server allows 40960")

    if a.dry_run:
        print(json.dumps(body, indent=2))
        return

    status, res = call(a.server, "POST", "/api/v1/build", body)
    request_hash = res.get("request_hash")
    while status == 202:
        print(f"  {res.get('imagebuilder_status') or res.get('detail') or 'queued'} ...", file=sys.stderr)
        time.sleep(5)
        status, res = call(a.server, "GET", f"/api/v1/build/{request_hash}")
    if status != 200:
        sys.exit(f"build failed ({status}): {res.get('detail') or res}\n{res.get('stderr', '')[-2000:]}")

    bin_dir = res.get("bin_dir") or request_hash
    print(f"built {res.get('version_number', version)} for {profile} ({target})")
    for img in res.get("images", []):
        print(f"  {img.get('type'):>12}  {a.server.rstrip('/')}/store/{bin_dir}/{img.get('name')}"
              f"  sha256 {img.get('sha256')}")


if __name__ == "__main__":
    main()
