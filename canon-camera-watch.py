#!/usr/bin/env python3
"""Start a camera sync the moment the camera appears on the network.

Canon bodies with CCAPI enabled announce themselves over SSDP (UPnP multicast)
when they join a network, and re-announce periodically while they stay on. This
listens for those announcements and triggers the sync unit, which replaces
polling the network on a timer.

The camera is identified by the MAC in its UPnP USN, which the M50 II builds
from the interface address:

    uuid:00000000-0000-0000-0001-7438B7E2735F  ->  74:38:B7:E2:73:5F

The MAC is read from the same config.yml the sync script uses, so there is only
ever one source of truth for which camera this host cares about.
"""
import os
import re
import socket
import struct
import subprocess
import sys
import time

SSDP_GROUP = "239.255.255.250"
SSDP_PORT = 1900
SYNC_UNIT = os.environ.get("CANON_SYNC_UNIT", "canon-camera-sync-wifi.service")
# One power-on produces a burst of announcements (8 observed on the M50 II), and
# the camera re-announces roughly every 15 minutes while it stays switched on.
# The window has to clear that re-announce, or every powered-on camera triggers
# a full card enumeration four times an hour on top of the 30-minute timer.
#
# The cost of a long window is narrow: it only delays a power-cycle that happens
# within it, since a camera that has been off for longer than this fires
# immediately. The 30-minute timer is the backstop for that case, which is why
# this sits below it.
DEBOUNCE_SECONDS = int(os.environ.get("CANON_WATCH_DEBOUNCE", "1200"))
CONFIG = os.environ.get(
    "CANON_SYNC_CONFIG",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.yml"),
)


def log(msg):
    print(msg, flush=True)


def read_camera_mac(path):
    """Pull camera_mac out of the flat YAML config, normalised to bare hex."""
    try:
        with open(path) as fh:
            for line in fh:
                if not line.startswith("camera_mac:"):
                    continue
                val = line.split(":", 1)[1]
                val = val.split("#", 1)[0].strip().strip("\"'")
                return re.sub(r"[:-]", "", val).lower()
    except OSError as exc:
        log(f"ERROR: cannot read {path}: {exc}")
    return ""


def lan_address():
    """Source address the default route would use.

    This host has around two dozen Docker bridges, so joining the multicast
    group on an unspecified interface is a coin flip. Connecting a UDP socket
    makes the kernel consult its own routing table and pick the interface for
    us; no packet is sent, and the address dialled only has to be off-LAN.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 9))
        return s.getsockname()[0]
    except OSError:
        return "0.0.0.0"
    finally:
        s.close()


def open_listener(local_ip):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("", SSDP_PORT))
    mreq = struct.pack("4s4s", socket.inet_aton(SSDP_GROUP), socket.inet_aton(local_ip))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    return s


def trigger():
    # --no-block matters: the sync unit is Type=oneshot and a full card can take
    # an hour, so a blocking start would stop us listening for the duration.
    try:
        subprocess.run(
            ["systemctl", "start", "--no-block", SYNC_UNIT],
            check=True, capture_output=True, text=True, timeout=30,
        )
        log(f"Triggered {SYNC_UNIT}.")
    except subprocess.CalledProcessError as exc:
        log(f"ERROR: could not start {SYNC_UNIT}: {(exc.stderr or '').strip()}")
    except Exception as exc:
        log(f"ERROR: could not start {SYNC_UNIT}: {exc}")


def main():
    mac = read_camera_mac(CONFIG)
    if not mac:
        log(f"ERROR: no camera_mac in {CONFIG} — nothing to watch for.")
        return 1

    local_ip = lan_address()
    try:
        sock = open_listener(local_ip)
    except OSError as exc:
        log(f"ERROR: cannot listen on {SSDP_GROUP}:{SSDP_PORT} via {local_ip}: {exc}")
        return 1

    pretty = ":".join(mac[i:i + 2] for i in range(0, len(mac), 2)).upper()
    log(f"Watching {SSDP_GROUP}:{SSDP_PORT} on {local_ip} for {pretty}.")
    last = 0.0

    while True:
        try:
            data, addr = sock.recvfrom(4096)
        except OSError as exc:
            log(f"ERROR: receive failed: {exc}")
            return 1

        if data[:6].upper() != b"NOTIFY":
            continue
        text = data.decode("utf-8", "replace")
        if mac not in re.sub(r"[:-]", "", text).lower():
            continue

        if re.search(r"(?im)^NTS:\s*ssdp:byebye", text):
            log(f"Camera at {addr[0]} announced ssdp:byebye (leaving the network).")
            continue
        if not re.search(r"(?im)^NTS:\s*ssdp:alive", text):
            continue

        now = time.time()
        if now - last < DEBOUNCE_SECONDS:
            continue
        last = now
        log(f"Camera {pretty} is up at {addr[0]}.")
        trigger()

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
