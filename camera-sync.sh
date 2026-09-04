#!/bin/bash
set -euo pipefail

# ─── Load configuration from config.yml ────────────────────────────────────────
# Resolve the directory where this script lives, so config.yml is found
# regardless of the working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yml"

# ─── Prometheus metrics (node_exporter textfile collector) ─────────────────────
# Written as a .prom file that node_exporter picks up and Prometheus scrapes, so
# a run's progress, outcome and error counts are visible in Grafana without
# reading the journal. Entirely optional: if the directory is not there, or is
# not writable, every function below becomes a no-op and the script behaves
# exactly as it did before. That is what keeps this repo standalone.
#
# This block sits above the config parse deliberately, so the validation exits
# further down are still recorded rather than vanishing silently.
umask 022
METRICS_DIR="${CANON_SYNC_METRICS_DIR:-/var/lib/node_exporter/textfile_collector}"
METRICS_FILE="$METRICS_DIR/canon_camera_sync.prom"

# The probe is the whole portability mechanism. A dev box with no such
# directory, a non-root run, or a systemd unit whose ProtectSystem=strict was
# never given a matching ReadWritePaths= all land here and quietly disable
# metrics instead of failing the sync or spraying redirection errors.
METRICS_ENABLED=0
if [[ -d "$METRICS_DIR" && -w "$METRICS_DIR" && "${DRY_RUN:-0}" != 1 ]]; then
    METRICS_ENABLED=1
fi

# Run-scoped state. All initialised here so the EXIT trap can never trip over an
# unset variable under `set -u`, whichever exit it fires on.
M_IN_PROGRESS=1
M_PHASE=startup
M_CAMERA_REACHABLE=0
M_CAMERA_ABSENT=0
M_SYNC_OK=0
M_RUN_TOTAL=0
M_RUN_DOWNLOADED=0
M_RUN_FAILED=0
M_FINALIZED=0
M_LAST_EMIT=0
# Comfortably under Prometheus's 30s scrape interval, so every scrape sees a
# progress value at most this stale.
M_MIN_INTERVAL=10
printf -v M_RUN_START '%(%s)T' -1

# Values that must survive between runs — cumulative counters and "when did this
# last work" timestamps. Most runs are polls that find no camera and exit within
# seconds; they must not reset any of this. The .prom file is its own state
# store, which keeps the number of paths this script needs to write at one.
declare -A MSTATE=()
metrics_load() {
    (( METRICS_ENABLED )) || return 0
    [[ -r "$METRICS_FILE" ]] || return 0
    local k v
    while read -r k v; do
        [[ "$k" == canon_sync_* ]] || continue
        # Anything not a plain number is ignored, so a truncated or corrupted
        # file degrades to a counter reset rather than poisoning the state.
        [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || continue
        MSTATE["${k#canon_sync_}"]="$v"
    done < "$METRICS_FILE"
    return 0
}

metrics_emit() {
    (( METRICS_ENABLED )) || return 0
    local tmp now dl fl label key p
    printf -v now '%(%s)T' -1

    # The cumulative counters always carry what this run has done so far, so
    # `rate()` moves during a long download instead of only at the end. MSTATE
    # holds the previous runs' totals and is never folded into, so there is no
    # path that counts this run twice.
    dl=$(( ${MSTATE[files_downloaded_total]:-0} + M_RUN_DOWNLOADED ))
    fl=$(( ${MSTATE[files_failed_total]:-0} + M_RUN_FAILED ))

    tmp="$METRICS_DIR/.canon_camera_sync.$$.tmp"
    {
        printf '# HELP canon_sync_in_progress 1 while a sync run is executing.\n'
        printf '# TYPE canon_sync_in_progress gauge\n'
        printf 'canon_sync_in_progress %d\n' "$M_IN_PROGRESS"

        printf '# HELP canon_sync_phase Stage of the run; exactly one value is 1.\n'
        printf '# TYPE canon_sync_phase gauge\n'
        for label in idle startup detect listing scan download; do
            p=0
            [[ "$label" == "$M_PHASE" ]] && p=1
            printf 'canon_sync_phase{phase="%s"} %d\n' "$label" "$p"
        done

        printf '# HELP canon_sync_camera_reachable 1 if the camera answered on a transport this run.\n'
        printf '# TYPE canon_sync_camera_reachable gauge\n'
        printf 'canon_sync_camera_reachable %d\n' "$M_CAMERA_REACHABLE"

        # Both label values are always emitted so neither series goes stale when
        # the transport changes; all-zero means no camera was found.
        printf '# HELP canon_sync_transport Transport in use; 1 on the active one.\n'
        printf '# TYPE canon_sync_transport gauge\n'
        for label in usb ccapi; do
            p=0
            [[ "${ACTIVE_TRANSPORT:-}" == "$label" ]] && p=1
            printf 'canon_sync_transport{transport="%s"} %d\n' "$label" "$p"
        done

        printf '# HELP canon_sync_files_on_camera Files seen on the card by the last successful listing.\n'
        printf '# TYPE canon_sync_files_on_camera gauge\n'
        printf 'canon_sync_files_on_camera %d\n' "${CAMERA_COUNT:-0}"

        printf '# HELP canon_sync_files_pending Files on the camera not yet in the destination.\n'
        printf '# TYPE canon_sync_files_pending gauge\n'
        printf 'canon_sync_files_pending %s\n' "${MSTATE[files_pending]:-0}"

        printf '# HELP canon_sync_run_files_queued Files this run set out to download.\n'
        printf '# TYPE canon_sync_run_files_queued gauge\n'
        printf 'canon_sync_run_files_queued %d\n' "$M_RUN_TOTAL"

        printf '# HELP canon_sync_run_files_downloaded Files downloaded so far by this run.\n'
        printf '# TYPE canon_sync_run_files_downloaded gauge\n'
        printf 'canon_sync_run_files_downloaded %d\n' "$M_RUN_DOWNLOADED"

        printf '# HELP canon_sync_run_files_failed Files this run gave up on after a retry.\n'
        printf '# TYPE canon_sync_run_files_failed gauge\n'
        printf 'canon_sync_run_files_failed %d\n' "$M_RUN_FAILED"

        printf '# HELP canon_sync_run_files_gone Files listed but vanished from the card before fetching.\n'
        printf '# TYPE canon_sync_run_files_gone gauge\n'
        printf 'canon_sync_run_files_gone %s\n' "${GONE:-0}"

        printf '# HELP canon_sync_run_start_timestamp_seconds Unix time this run started.\n'
        printf '# TYPE canon_sync_run_start_timestamp_seconds gauge\n'
        printf 'canon_sync_run_start_timestamp_seconds %d\n' "$M_RUN_START"

        printf '# HELP canon_sync_last_run_timestamp_seconds Unix time the last run finished.\n'
        printf '# TYPE canon_sync_last_run_timestamp_seconds gauge\n'
        printf 'canon_sync_last_run_timestamp_seconds %s\n' "${MSTATE[last_run_timestamp_seconds]:-0}"

        printf '# HELP canon_sync_last_run_duration_seconds Wall-clock duration of the last completed run.\n'
        printf '# TYPE canon_sync_last_run_duration_seconds gauge\n'
        printf 'canon_sync_last_run_duration_seconds %s\n' "${MSTATE[last_run_duration_seconds]:-0}"

        printf '# HELP canon_sync_last_run_aborted 1 if the last run stopped early on repeated failures.\n'
        printf '# TYPE canon_sync_last_run_aborted gauge\n'
        printf 'canon_sync_last_run_aborted %s\n' "${MSTATE[last_run_aborted]:-0}"

        printf '# HELP canon_sync_last_exit_code Exit status of the last completed run.\n'
        printf '# TYPE canon_sync_last_exit_code gauge\n'
        printf 'canon_sync_last_exit_code %s\n' "${MSTATE[last_exit_code]:-0}"

        printf '# HELP canon_sync_last_success_timestamp_seconds Unix time of the last run that left the destination in sync; 0 if never.\n'
        printf '# TYPE canon_sync_last_success_timestamp_seconds gauge\n'
        printf 'canon_sync_last_success_timestamp_seconds %s\n' "${MSTATE[last_success_timestamp_seconds]:-0}"

        printf '# HELP canon_sync_last_download_timestamp_seconds Unix time of the last run that downloaded a file; 0 if never.\n'
        printf '# TYPE canon_sync_last_download_timestamp_seconds gauge\n'
        printf 'canon_sync_last_download_timestamp_seconds %s\n' "${MSTATE[last_download_timestamp_seconds]:-0}"

        printf '# HELP canon_sync_last_camera_seen_timestamp_seconds Unix time the camera was last reachable; 0 if never.\n'
        printf '# TYPE canon_sync_last_camera_seen_timestamp_seconds gauge\n'
        printf 'canon_sync_last_camera_seen_timestamp_seconds %s\n' "${MSTATE[last_camera_seen_timestamp_seconds]:-0}"

        printf '# HELP canon_sync_files_downloaded_total Files successfully downloaded since this file was created.\n'
        printf '# TYPE canon_sync_files_downloaded_total counter\n'
        printf 'canon_sync_files_downloaded_total %d\n' "$dl"

        printf '# HELP canon_sync_files_failed_total Files abandoned or gone since this file was created.\n'
        printf '# TYPE canon_sync_files_failed_total counter\n'
        printf 'canon_sync_files_failed_total %d\n' "$fl"

        printf '# HELP canon_sync_runs_total Completed runs by outcome since this file was created.\n'
        printf '# TYPE canon_sync_runs_total counter\n'
        for result in success nothing_to_do no_camera partial aborted error startup_error; do
            key="runs_total{result=\"$result\"}"
            printf 'canon_sync_runs_total{result="%s"} %s\n' "$result" "${MSTATE[$key]:-0}"
        done
    } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 0; }

    # Rename within the same directory is atomic, so node_exporter never reads a
    # half-written file. The temp name deliberately does not end in .prom, which
    # is the suffix the collector filters on.
    mv -f "$tmp" "$METRICS_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    M_LAST_EMIT="$now"
    return 0
}

# Throttled emit for use inside the download loop.
metrics_tick() {
    (( METRICS_ENABLED )) || return 0
    local now
    printf -v now '%(%s)T' -1
    if (( now - M_LAST_EMIT >= M_MIN_INTERVAL )); then
        metrics_emit
    fi
    return 0
}

metrics_final() {
    (( METRICS_ENABLED )) || return 0
    (( M_FINALIZED )) && return 0
    local rc="${1:-0}" now result pending
    printf -v now '%(%s)T' -1

    # Classify the outcome. M_CAMERA_ABSENT distinguishes "no camera plugged in"
    # from "died while looking for one" — ABSENT_EXIT_CODE is 1 in both cases,
    # so the exit status alone cannot separate them.
    if [[ "$M_PHASE" == startup ]]; then
        result=startup_error
    elif (( M_CAMERA_ABSENT )); then
        result=no_camera
    elif (( M_CAMERA_REACHABLE == 0 )); then
        result=error
    elif (( ${ABORTED:-0} )); then
        result=aborted
    elif (( M_RUN_FAILED > 0 )); then
        result=partial
    elif (( M_SYNC_OK && M_RUN_DOWNLOADED > 0 )); then
        result=success
    elif (( M_SYNC_OK )); then
        result=nothing_to_do
    else
        result=error
    fi

    key="runs_total{result=\"$result\"}"
    MSTATE[$key]=$(( ${MSTATE[$key]:-0} + 1 ))
    MSTATE[last_run_timestamp_seconds]="$now"
    MSTATE[last_run_duration_seconds]=$(( now - M_RUN_START ))
    MSTATE[last_exit_code]="$rc"
    MSTATE[last_run_aborted]="${ABORTED:-0}"
    (( M_CAMERA_REACHABLE )) && MSTATE[last_camera_seen_timestamp_seconds]="$now"
    (( M_RUN_DOWNLOADED > 0 )) && MSTATE[last_download_timestamp_seconds]="$now"
    # M_SYNC_OK is set before the trailing chown, so a run that synced everything
    # and then failed only on chown is still recorded as a success — with its
    # non-zero exit code visible separately.
    (( M_SYNC_OK )) && MSTATE[last_success_timestamp_seconds]="$now"

    if (( M_SYNC_OK )); then
        pending=0
    elif (( M_RUN_TOTAL > 0 )); then
        pending=$(( M_RUN_TOTAL - M_RUN_DOWNLOADED ))
    else
        pending="${MSTATE[files_pending]:-0}"
    fi
    MSTATE[files_pending]="$pending"

    M_IN_PROGRESS=0
    M_PHASE=idle
    M_FINALIZED=1
    metrics_emit
    return 0
}

metrics_load
# No emit here: the lock has not been taken yet, and a run that goes on to lose
# it must not have already stamped zeroed progress over the winner's gauges.
# The first emit happens immediately after the lock is held. Exits before that
# point are still recorded, by metrics_final from the EXIT trap.

# ─── Exit handling ─────────────────────────────────────────────────────────────
# One EXIT trap for the whole script, installed here rather than further down so
# it also covers the config-validation exits below. It only touches variables
# that are guarded with :-, so it is safe this early.
cleanup() {
    # Must be the first statement: it captures the status that triggered the
    # trap, before `local` overwrites $?.
    local rc=$?
    metrics_final "$rc" || true
    [[ -n "${STAGING_DIR:-}" && -d "$STAGING_DIR" ]] && rm -rf "$STAGING_DIR"
    # Never let the handler change the script's exit status.
    return 0
}
trap cleanup EXIT
# Without this a SIGTERM (systemd timeout, `systemctl stop`, reboot) kills bash
# outright and the EXIT trap never runs, leaking the staging directory and
# leaving in_progress stuck at 1 forever. Converting the signal to a normal
# exit lets cleanup do its job. 143 = 128 + SIGTERM, the conventional status.
trap 'exit 143' TERM INT HUP

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: config.yml not found at $CONFIG_FILE"
    echo "Copy config.example.yml to config.yml and edit it for your setup."
    exit 1
fi

# Parse a value from flat YAML (key: value). Strips comments and quotes.
yml_get() {
    local val
    val=$(grep -E "^${1}:" "$CONFIG_FILE" | head -1 | sed "s/^${1}:[[:space:]]*//" | sed 's/[[:space:]]*#.*//' | sed 's/^["'\'']\(.*\)["'\'']$/\1/')
    echo "$val"
}

# Read user-specific settings from config.yml
DEST_BASE="$(yml_get dest_base)"
OWNER_USER="$(yml_get owner_user)"
OWNER_GROUP="$(yml_get owner_group)"
# Camera brand/name used to verify detection (e.g. "canon", "nikon")
CAMERA_DETECT_NAME="$(yml_get camera_detect_name)"

# Transport used to reach the camera: auto | usb | ccapi.
# "auto" (the default, and what an absent key resolves to) prefers USB whenever
# the camera is plugged in — it is faster and needs no camera-side setup — and
# falls back to Wi-Fi automatically. Pin usb/ccapi only to force one.
TRANSPORT="$(yml_get transport)"
TRANSPORT="${TRANSPORT:-auto}"
TRANSPORT="${TRANSPORT,,}"

# The camera is identified by its Wi-Fi MAC and its address looked up in the ARP
# table at run time, so it can stay on DHCP with no router reservation.
CAMERA_MAC="$(yml_get camera_mac)"

# CCAPI listens on 8080 unless changed in the camera's Camera Control API menu.
CCAPI_PORT="$(yml_get ccapi_port)"
CCAPI_PORT="${CCAPI_PORT:-8080}"
# Only needed if an account is registered under the camera's Account settings;
# with none registered CCAPI is open on the LAN and these stay empty.
CCAPI_USER="$(yml_get ccapi_user)"
CCAPI_PASSWORD="$(yml_get ccapi_password)"

STATE_FILE="$DEST_BASE/.last_sync_count"

# ─── Validate configuration ────────────────────────────────────────────────────
if [[ "$DEST_BASE" == "/path/to/your/photo/destination" || -z "$DEST_BASE" ]]; then
    echo "ERROR: 'dest_base' in config.yml is not configured."
    exit 1
fi
if [[ "$DEST_BASE" != /* ]]; then
    echo "ERROR: dest_base must be an absolute path."
    exit 1
fi
if ! id -u "$OWNER_USER" &>/dev/null; then
    echo "ERROR: owner_user '$OWNER_USER' does not exist on this system."
    exit 1
fi
if ! getent group "$OWNER_GROUP" &>/dev/null; then
    echo "ERROR: owner_group '$OWNER_GROUP' does not exist on this system."
    exit 1
fi
case "$TRANSPORT" in
    usb|auto) ;;
    ccapi)
        if [[ -z "$CAMERA_MAC" ]]; then
            echo "ERROR: transport is pinned to 'ccapi' but 'camera_mac' is not set in config.yml."
            exit 1
        fi
        ;;
    *)
        echo "ERROR: transport must be 'auto', 'usb' or 'ccapi' (got '$TRANSPORT')."
        exit 1
        ;;
esac
if ! [[ "$CCAPI_PORT" =~ ^[0-9]{1,5}$ ]] || (( CCAPI_PORT < 1 || CCAPI_PORT > 65535 )); then
    echo "ERROR: ccapi_port must be a TCP port number (got '$CCAPI_PORT')."
    exit 1
fi
# Accepts colon- or dash-separated; normalised to lower-case colons for lookup.
if [[ -n "$CAMERA_MAC" ]]; then
    if ! [[ "$CAMERA_MAC" =~ ^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$ ]]; then
        echo "ERROR: camera_mac must be a MAC address (e.g. 74:38:B7:E2:73:5F)."
        exit 1
    fi
    CAMERA_MAC="${CAMERA_MAC//-/:}"
    CAMERA_MAC="${CAMERA_MAC,,}"
fi
# The two forms the rest of the script needs, derived once: colon-separated for
# the kernel's neighbour table, bare hex for the MAC the camera embeds in its
# UPnP UUID. Empty when no camera_mac is configured, which is handled upstream.
CAMERA_MAC_HEX="${CAMERA_MAC//:/}"

# Ensure destination base exists
mkdir -p "$DEST_BASE"

# Only one sync at a time. STAGING_DIR is a fixed path that cleanup() wipes, so
# two overlapping runs (udev USB plus the Wi-Fi timer, say) would delete each
# other's in-flight downloads. The lock lives in /run rather than on DEST_BASE:
# that mount is fuseblk without 'flock', where locking can silently no-op.
#
# Two candidates, in order. The systemd units set RuntimeDirectory=, which gives
# a writable /run/canon-camera-sync even under ProtectSystem=strict — that makes
# the whole of /run read-only, so the bare /run path below would fail the probe
# and silently drop locking altogether. The flat path is the fallback for a
# manual root run outside systemd.
#
# Probe writability first: bash reports a failed redirection on the real stderr
# regardless of 2>/dev/null, and a manual non-root run should not be noisy about
# a lock it cannot take. Locking is best-effort; the systemd path runs as root.
# One path, always. The systemd units create /run/canon-camera-sync via
# RuntimeDirectory= (the only way it can exist when ProtectSystem=strict makes
# the rest of /run read-only); a manual root run creates it with the mkdir. A
# second candidate path was deliberately removed: two runs picking different
# lock files exclude nothing, which is the exact failure this lock prevents.
#
# Non-root runs cannot write /run and so run unlocked — best-effort by design,
# since the systemd path is what actually runs in production. The probe is what
# keeps that quiet: bash reports a failed redirection on the real stderr no
# matter how it is redirected.
LOCK_DIR="/run/canon-camera-sync"
LOCK_FILE="$LOCK_DIR/lock"
LOCK_HELD=0
mkdir -p "$LOCK_DIR" 2>/dev/null || true
if [[ -w "$LOCK_DIR" ]]; then
    exec 9>"$LOCK_FILE" && LOCK_HELD=1
fi
if (( LOCK_HELD )) && ! flock -n 9; then
    echo "Another sync is already running — exiting."
    # Emit nothing: the run that holds the lock owns the metrics file, and
    # writing idle values here would stamp over its live progress.
    METRICS_ENABLED=0
    exit 0
fi

# Safe to publish now that this run owns the lock.
metrics_emit

# ─── Kill gvfs-gphoto2-volume-monitor ──────────────────────────────────────────
# GNOME's gvfs grabs exclusive USB access to the camera and blocks gphoto2
# from connecting. Killing it here allows gphoto2 to take over.
# It will respawn automatically later when needed by GNOME.
# This has to happen before the USB probe below, since gvfs holding the device
# is exactly what makes that probe fail. Skipped only when the config pins
# ccapi, where USB is never touched at all.
# Only worth doing when gvfs is actually up. With transport: auto this block is
# reached by every Wi-Fi poll too, and killing a desktop service and sleeping 2s
# before even checking whether a camera is on USB costs ~96s a day and restarts
# a GNOME daemon dozens of times for nothing.
if [[ "$TRANSPORT" != ccapi ]] && pgrep -f 'gvfs-gphoto2-volume-monitor' >/dev/null 2>&1; then
    pkill -f gvfs-gphoto2-volume-monitor 2>/dev/null || true
    sleep 2
fi

# ─── Tunables ──────────────────────────────────────────────────────────────────
# Consecutive download failures tolerated before the script checks whether the
# camera is still attached (see the download loop below).
MAX_CONSECUTIVE_FAILS=3
# Total failures tolerated in one run. A camera that stays enumerated but never
# delivers a file would otherwise burn two attempts plus a 3s sleep on every
# remaining file — hours of no progress on a full card.
MAX_TOTAL_FAILS=25

# A polling trigger (the Wi-Fi timer) asks "is there anything to do?" — for it,
# "no camera right now" is a normal answer, not a failure, and must not log a
# failed unit on every tick. The udev/USB path never sets this variable.
ABSENT_EXIT_CODE=1
if [[ "${CAMERA_SYNC_POLL:-0}" == 1 ]]; then
    ABSENT_EXIT_CODE=0
fi

# Seconds allowed for the liveness probe and for each class of CCAPI call. A
# stalled wireless link has to fail rather than hang the whole run.
PROBE_TIMEOUT=5
CCAPI_CONNECT_TIMEOUT=10
CCAPI_LIST_TIMEOUT=120
CCAPI_FETCH_TIMEOUT=900

ACTIVE_TRANSPORT=""
CAMERA_IP=""        # discovered from camera_mac at run time
CCAPI_CONTENTS=""   # the /contents URL, discovered from GET /ccapi

# ─── CCAPI (Canon Camera Control API) ──────────────────────────────────────────
# Canon's official HTTP API, and the only wireless route that works on recent
# bodies: gphoto2's PTP/IP cannot complete Canon's EOS Utility pairing (see the
# Troubleshooting section of README.md). Files are addressed by path here, so
# the stale-index problem the USB path has to handle simply does not arise.

# Build an absolute URL from a path the camera handed back. Canon returns bare
# paths on some firmware and full URLs on others; accept either.
# Read one header out of a curl -D dump. Always the LAST match: with an account
# configured, curl --anyauth replays the request after a 401 and -D appends both
# header blocks to the same file, so the first match describes the challenge and
# not the response. Getting this wrong makes every download look truncated.
http_header() {
    awk -v k="$2:" 'tolower($1)==k {sub(/^[^:]*:[[:space:]]*/,""); gsub(/\r/,""); v=$0} END{if (v != "") print v}' "$1" 2>/dev/null
}

ccapi_url() {
    local p="$1"
    if [[ "$p" == http://* || "$p" == https://* ]]; then
        printf '%s' "$p"
    else
        printf 'http://%s:%s%s' "$CAMERA_IP" "$CCAPI_PORT" "$p"
    fi
}

# curl with the options every CCAPI call shares. $1 is the max time in seconds.
ccapi_curl() {
    local t="$1"; shift
    local auth=()
    # Only sent when an account is registered on the camera; with none, CCAPI is
    # open on the LAN and --anyauth would just add a wasted round trip.
    if [[ -n "$CCAPI_USER" ]]; then
        auth=(--anyauth --user "$CCAPI_USER:$CCAPI_PASSWORD")
    fi
    curl -sS -f --connect-timeout "$CCAPI_CONNECT_TIMEOUT" --max-time "$t" \
        "${auth[@]+"${auth[@]}"}" "$@"
}

# Pull every CCAPI path out of a listing response, whatever key it hides under.
# Canon wraps these in an array whose key has differed between firmware
# versions, so match on the value's shape rather than on a key name.
json_ccapi_paths() {
    python3 -c '
import json, sys
def walk(o):
    if isinstance(o, str):
        if o.startswith("/ccapi/") or o.startswith("http://") or o.startswith("https://"):
            print(o)
    elif isinstance(o, dict):
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
try:
    walk(json.load(sys.stdin))
except Exception:
    sys.exit(1)
' 2>/dev/null
}

# First YYYY-MM found anywhere in a JSON document.
json_year_month() {
    python3 -c '
import json, re, sys
from email.utils import parsedate_to_datetime

pat = re.compile(r"(19|20)\d\d[-:/](0[1-9]|1[0-2])[-:/](0[1-9]|[12]\d|3[01])")

def norm(s):
    m = pat.search(s)
    if m:
        t = m.group(0)
        return t[0:4] + "-" + t[5:7]
    # The M50 II reports lastmodifieddate as an HTTP-date rather than ISO:
    #   "Thu, 03 Sep 2026 17:31:58 GMT"
    try:
        d = parsedate_to_datetime(s)
    except Exception:
        return None
    if d is None or not (1990 <= d.year <= 2100):
        return None
    return "%04d-%02d" % (d.year, d.month)

def walk(o):
    if isinstance(o, str):
        return norm(o)
    if isinstance(o, dict):
        for v in o.values():
            r = walk(v)
            if r: return r
    elif isinstance(o, list):
        for v in o:
            r = walk(v)
            if r: return r
    return None

try:
    r = walk(json.load(sys.stdin))
except Exception:
    sys.exit(1)
if not r:
    sys.exit(1)
print(r)
' 2>/dev/null
}

# EXIF stores DateTimeOriginal as literal "YYYY:MM:DD HH:MM:SS" ASCII in both
# JPEG and CR3, so a bounded scan of the header finds it without a TIFF parser
# or an exiftool dependency (exiftool is not installed on the target host).
exif_year_month() {
    python3 -c '
import re, sys
try:
    data = open(sys.argv[1], "rb").read(262144)
except Exception:
    sys.exit(1)
m = re.search(rb"(19|20)\d\d:(0[1-9]|1[0-2]):(0[1-9]|[12]\d|3[01]) [0-2]\d:[0-5]\d:[0-5]\d", data)
if not m:
    sys.exit(1)
s = m.group(0).decode("ascii")
print(s[0:4] + "-" + s[5:7])
' "$1" 2>/dev/null
}

# Locate the CCAPI /contents endpoint. Both the version segment (ver100, ver110,
# ...) and the storage name (sd, card1, ...) vary by model and firmware, so ask
# the camera instead of hardcoding either.
ccapi_discover() {
    local root p best=""
    root=$(ccapi_curl 20 "http://$CAMERA_IP:$CCAPI_PORT/ccapi" 2>/dev/null) || return 1
    [[ -n "$root" ]] || return 1
    while IFS= read -r p; do
        [[ "$p" == */contents ]] || continue
        # Sorted, so a later API version wins over an earlier one.
        best="$p"
    done < <(printf '%s' "$root" | json_ccapi_paths | sort)
    [[ -n "$best" ]] || return 1
    CCAPI_CONTENTS="$(ccapi_url "$best")"
    return 0
}

# A directory holding thousands of frames comes back paginated; keep asking
# until a page repeats or comes back empty. Firmware that ignores ?page returns
# everything at once, which the repeat check collapses to a single copy.
ccapi_list_dir() {
    local d="$1" page=1 out prev=""
    while (( page <= 100 )); do
        out=$(ccapi_curl "$CCAPI_LIST_TIMEOUT" "$(ccapi_url "$d")?page=$page" 2>/dev/null \
              | json_ccapi_paths) || out=""
        [[ -n "$out" ]] || break
        [[ "$out" == "$prev" ]] && break
        printf '%s\n' "$out"
        prev="$out"
        page=$(( page + 1 ))
    done
    if (( page == 1 )); then
        ccapi_curl "$CCAPI_LIST_TIMEOUT" "$(ccapi_url "$d")" 2>/dev/null | json_ccapi_paths || true
    fi
}

ccapi_camera_present() {
    [[ -n "$CAMERA_IP" ]] || return 1
    # Liveness only: a bare TCP connect, so a camera that has gone away fails in
    # seconds rather than hanging the abort logic on an HTTP timeout.
    timeout "$PROBE_TIMEOUT" \
        bash -c "exec 3<>/dev/tcp/$CAMERA_IP/$CCAPI_PORT" 2>/dev/null
}

# ─── Camera helpers ────────────────────────────────────────────────────────────
usb_camera_present() {
    gphoto2 --auto-detect 2>/dev/null | grep -qi "$CAMERA_DETECT_NAME"
}

# Look a MAC up in the neighbour table. Empty output means "not currently known".
mac_to_ip() {
    # Already colon-lowered by the config validation above.
    local mac="$1"
    ip neigh show 2>/dev/null \
        | awk -v m="$mac" 'tolower($5)==m && $1 ~ /^[0-9]+\./ {print $1; exit}'
}

# Ask the network directly: one SSDP multicast packet, answered only by Canon
# cameras running CCAPI. This is the primary discovery path because it beats the
# ARP route on every axis — one packet instead of 254 pings, no dependence on
# what the neighbour table happens to hold, and the reply identifies the camera
# by MAC rather than by us inferring it.
#
# The MAC is carried in the UPnP USN, which the M50 II builds from it:
#   uuid:00000000-0000-0000-0001-7438B7E2735F  ->  74:38:B7:E2:73:5F
# so matching is a separator-stripped, case-insensitive substring test.
#
# Prints the address on success, nothing on failure.
ssdp_find_camera() {
    local mac="$1"
    python3 -c '
import re, socket, sys, time

want = sys.argv[1].lower()
ST = "urn:schemas-canon-com:device:ICPO-CameraControlAPIService:1"
msg = ("M-SEARCH * HTTP/1.1\r\n"
       "HOST:239.255.255.250:1900\r\n"
       "MAN:\"ssdp:discover\"\r\n"
       "MX:1\r\n"
       "ST:" + ST + "\r\n\r\n").encode()

try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    s.settimeout(0.5)
    s.sendto(msg, ("239.255.255.250", 1900))
except Exception:
    sys.exit(1)

# MX:1 tells responders to spread replies over one second; give it two, since a
# camera that has just joined the network can be slow to answer the first probe.
deadline = time.time() + 2.0
while time.time() < deadline:
    try:
        data, addr = s.recvfrom(4096)
    except socket.timeout:
        continue
    except Exception:
        break
    text = data.decode("utf-8", "replace")
    if want and want not in re.sub(r"[:-]", "", text).lower():
        continue
    m = re.search(r"(?im)^Location:\s*http://([0-9.]+)[:/]", text)
    print(m.group(1) if m else addr[0])
    sys.exit(0)
sys.exit(1)
' "$mac" 2>/dev/null
}

# The camera only appears in the ARP table once something has talked to it.
# A short parallel sweep of the local /24 makes the kernel learn every host,
# which is enough for the lookup above to succeed on a cold cache. This is the
# fallback for a camera that does not answer UPnP, or a network where multicast
# is filtered; SSDP handles the normal case without the sweep.
prime_arp_cache() {
    local gw net
    gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
    [[ -n "$gw" ]] || return 0
    net="${gw%.*}"
    echo "Looking for $CAMERA_MAC on $net.0/24..."
    seq 1 254 | xargs -P 64 -I{} timeout 1 ping -c1 -W1 -n "$net.{}" >/dev/null 2>&1 || true
}

# Resolve CAMERA_IP for this run from the configured MAC. Discovering the
# address rather than configuring it is what lets the camera stay on DHCP.
resolve_camera_ip() {
    local found
    # Escape hatch for testing and one-off debugging: supply an address in the
    # environment to skip discovery entirely. Not a config key — normal runs are
    # meant to find the camera by MAC so it can stay on DHCP.
    if [[ -n "${CAMERA_IP_OVERRIDE:-}" ]]; then
        CAMERA_IP="$CAMERA_IP_OVERRIDE"
        return 0
    fi
    [[ -n "$CAMERA_MAC" ]] || return 1

    # Ask over SSDP first — one packet, and the camera answers with its own
    # address. The neighbour table is the free second guess.
    found=$(ssdp_find_camera "$CAMERA_MAC_HEX" || true)
    if [[ -z "$found" ]]; then
        found=$(mac_to_ip "$CAMERA_MAC")
    fi

    # The sweep is a last resort for a camera that is switched on but does not
    # answer UPnP — 254 pings and twice as many process spawns. A switched-off
    # camera reaches here on every single tick, so a polling trigger must never
    # pay for it: for the timer and the SSDP watcher, "SSDP silent and nothing
    # in the neighbour table" already means "no camera", and the watcher only
    # fires at all because the camera just announced itself. A run started by
    # hand still sweeps, because there the user is asserting a camera is there.
    if [[ -z "$found" && "${CAMERA_SYNC_POLL:-0}" != 1 ]]; then
        prime_arp_cache
        found=$(mac_to_ip "$CAMERA_MAC")
    fi
    [[ -n "$found" ]] || return 1
    CAMERA_IP="$found"
    return 0
}

# Liveness of the transport already chosen. The download loop calls this and
# must never switch transports mid-run: a gphoto2 index belongs to one camera
# session, so a swap would silently invalidate every queued locator.
camera_present() {
    case "$ACTIVE_TRANSPORT" in
        usb)   usb_camera_present ;;
        ccapi) ccapi_camera_present ;;
        *)     return 1 ;;
    esac
}

# Pick a transport once, at startup. USB wins whenever the camera is plugged in:
# it is faster, needs no camera-side setup, and has no session timeouts. CCAPI
# over Wi-Fi is the automatic fallback.
resolve_transport() {
    if [[ "$TRANSPORT" == usb || "$TRANSPORT" == auto ]] && usb_camera_present; then
        ACTIVE_TRANSPORT=usb
        echo "Camera found on USB."
        return 0
    fi
    if [[ "$TRANSPORT" == ccapi || "$TRANSPORT" == auto ]] \
       && resolve_camera_ip && ccapi_camera_present; then
        ACTIVE_TRANSPORT=ccapi
        echo "Camera found on the network at $CAMERA_IP (CCAPI port $CCAPI_PORT)."
        return 0
    fi
    return 1
}

# Map each camera filename to a locator and a size hint.
#
# The locator is opaque to the download loop: a gphoto2 index number on USB, a
# CCAPI URL path over Wi-Fi. Indices are only meaningful within a single camera
# session — after a USB reconnect, or any add/delete on the card, they shift,
# and fetching by a stale one silently downloads the wrong image — so the USB
# path re-reads the listing whenever the session may have changed. CCAPI paths
# do not have that problem.
declare -A LOC_FOR_NAME
declare -A KB_FOR_NAME
CAMERA_NAMES=()
CAMERA_COUNT=0
LAST_CAMERA_FILE=""

# gphoto2 --list-files emits e.g.
#   #1     IMG_0001.JPG               rd  5162 KB image/jpeg
# Parsed with a single bash regex rather than per-line greps: it forks nothing,
# and unlike `awk '{print $2}'` it keeps filenames that contain spaces intact.
LIST_RE='^#([0-9]+)[[:space:]]+(.+)[[:space:]]+[a-zA-Z-]{2}[[:space:]]+([0-9]+)[[:space:]]+KB'

# Returns 0 with an index, 2 when the camera answered but the card holds no
# files, and 1 when the listing itself failed. Callers must keep 1 and 2 apart:
# an empty card is a successful sync, an unreadable one is not.
build_index_usb() {
    local list raw line num name kb dupes=0 rc=0
    # Capture gphoto2's own status before the pipeline hides it — piping into
    # grep would report grep's status, which is 1 for "no matches" either way.
    raw=$(gphoto2 --list-files 2>/dev/null) || rc=$?
    (( rc == 0 )) || return 1
    list=$(printf '%s\n' "$raw" | grep "^#" || true)

    LOC_FOR_NAME=()
    KB_FOR_NAME=()
    CAMERA_NAMES=()
    CAMERA_COUNT=0
    LAST_CAMERA_FILE=""

    while IFS= read -r line; do
        [[ $line =~ $LIST_RE ]] || continue
        num="${BASH_REMATCH[1]}"
        name="${BASH_REMATCH[2]}"
        kb="${BASH_REMATCH[3]}"
        # Trim the column padding the regex leaves on the name.
        name="${name%"${name##*[![:space:]]}"}"
        [[ -n "$num" && -n "$name" ]] || continue

        CAMERA_COUNT=$(( CAMERA_COUNT + 1 ))
        LAST_CAMERA_FILE="$name"

        # Two camera folders can hold the same basename (100CANON/IMG_0001.JPG
        # and 101CANON/IMG_0001.JPG after a counter reset). Both would map to
        # one destination path, so keep the first and report the collision
        # rather than fetching one index twice and calling it a success.
        if [[ -n "${LOC_FOR_NAME[$name]+x}" ]]; then
            dupes=$(( dupes + 1 ))
            continue
        fi
        LOC_FOR_NAME["$name"]="$num"
        KB_FOR_NAME["$name"]="$kb"
        CAMERA_NAMES+=("$name")
    done <<< "$list"

    if (( dupes > 0 )); then
        echo "WARNING: $dupes camera file(s) share a basename with another file and cannot both be stored; only the first of each is synced."
    fi

    (( CAMERA_COUNT > 0 )) && return 0
    return 2
}

# Walk storage -> directories -> files over CCAPI. No size is taken from the
# listing: the download's Content-Length is exact, which makes a stronger
# truncation guard than the USB path's whole-KB approximation.
build_index_ccapi() {
    local storages=() dirs=() files=() s d p name dupes=0

    ccapi_discover || return 1

    mapfile -t storages < <(ccapi_curl "$CCAPI_LIST_TIMEOUT" "$CCAPI_CONTENTS" 2>/dev/null \
                            | json_ccapi_paths)
    (( ${#storages[@]} > 0 )) || return 1

    LOC_FOR_NAME=()
    KB_FOR_NAME=()
    CAMERA_NAMES=()
    CAMERA_COUNT=0
    LAST_CAMERA_FILE=""

    for s in "${storages[@]}"; do
        mapfile -t dirs < <(ccapi_curl "$CCAPI_LIST_TIMEOUT" "$(ccapi_url "$s")" 2>/dev/null \
                            | json_ccapi_paths)
        for d in "${dirs[@]}"; do
            mapfile -t files < <(ccapi_list_dir "$d")
            for p in "${files[@]}"; do
                name="${p##*/}"
                # Directory entries carry no extension; only real files do.
                [[ "$name" == *.* ]] || continue

                CAMERA_COUNT=$(( CAMERA_COUNT + 1 ))
                LAST_CAMERA_FILE="$name"

                if [[ -n "${LOC_FOR_NAME[$name]+x}" ]]; then
                    dupes=$(( dupes + 1 ))
                    continue
                fi
                LOC_FOR_NAME["$name"]="$p"
                KB_FOR_NAME["$name"]=0
                CAMERA_NAMES+=("$name")
            done
        done
    done

    if (( dupes > 0 )); then
        echo "WARNING: $dupes camera file(s) share a basename with another file and cannot both be stored; only the first of each is synced."
    fi

    (( CAMERA_COUNT > 0 ))
}

# Passes the transport's status through unchanged, including build_index_usb's
# 2 for "reachable, but the card is empty".
build_index() {
    case "$ACTIVE_TRANSPORT" in
        usb)   build_index_usb ;;
        ccapi) build_index_ccapi ;;
        *)     return 1 ;;
    esac
}

# ─── Staging area ──────────────────────────────────────────────────────────────
# gphoto2 leaves a partial file in place when a transfer dies mid-way. Because
# the "already synced" test below matches on basename alone, such a stub would
# look complete on every later run and never be re-fetched — a silently
# truncated photo. Downloading into a staging directory and moving the result
# into place only on success keeps DEST_BASE free of partial files.
#
# The name is fixed rather than PID-based so that a directory orphaned by a
# killed run is cleared by the next one instead of lingering and being scanned
# as if it held synced photos.
STAGING_NAME=".staging"
STAGING_DIR="$DEST_BASE/$STAGING_NAME"

LAST_DEST_DIR=""

# mkdir only when the month actually changes. Consecutive photos overwhelmingly
# share a month, and the destination is a fuseblk mount on an SMR disk where
# every metadata operation is a userspace round trip.
ensure_dest_dir() {
    [[ "$1" == "$LAST_DEST_DIR" ]] && return 0
    mkdir -p "$1" || return 1
    LAST_DEST_DIR="$1"
    return 0
}


# Download one file by index, verify it is the file that was asked for and that
# it arrived whole, then move it into DEST_BASE preserving gphoto2's YYYY/MM
# layout. Returns 0 on success, 2 if the index was stale, 1 otherwise.
fetch_file_usb() {
    local num="$1" expect="$2" expect_kb="$3"
    local staged=() src got rel dst bytes min_bytes

    rm -rf "${STAGING_DIR:?}"
    mkdir -p "$STAGING_DIR"
    gphoto2 --get-file "$num" --filename "$STAGING_DIR/%Y/%m/%f.%C" || return 1

    mapfile -d '' -t staged < <(find "$STAGING_DIR" -type f -print0)
    if (( ${#staged[@]} != 1 )); then
        echo "WARNING: expected exactly one file for '$expect' (#$num), got ${#staged[@]} — discarding."
        return 1
    fi

    src="${staged[0]}"
    got="$(basename "$src")"
    if [[ "$got" != "$expect" ]]; then
        echo "WARNING: asked for '$expect' (#$num) but camera returned '$got' — index is stale."
        return 2
    fi

    # Truncation guard: gphoto2 can exit 0 after a short read on some PTP
    # transport errors, which would defeat the whole point of staging. The
    # listing reports whole KB; requiring 95% of size*1000 catches a real
    # truncation while tolerating both 1000- and 1024-byte KB conventions.
    if [[ "$expect_kb" =~ ^[0-9]+$ ]] && (( expect_kb > 0 )); then
        bytes=$(stat -c %s "$src")
        min_bytes=$(( expect_kb * 950 ))
        if (( bytes < min_bytes )); then
            echo "WARNING: '$expect' (#$num) arrived as $bytes bytes but the camera lists ~$(( expect_kb * 1000 )) — truncated, discarding."
            return 1
        fi
    fi

    rel="${src#"$STAGING_DIR"/}"
    dst="$DEST_BASE/$rel"
    ensure_dest_dir "${dst%/*}" || return 1
    mv -f "$src" "$dst" || return 1
    return 0
}

# Capture month for a file. EXIF DateTimeOriginal first: it is the actual
# capture time rather than a proxy, it costs nothing because the bytes are
# already local, and it was verified to agree with the existing archive on 60
# of 60 real CR3/JPG files spanning three years. Last-Modified and the camera's
# own metadata are fallbacks for a file whose EXIF cannot be read.
# Prints YYYY-MM, or fails if no source yields a date.
ccapi_year_month() {
    local loc="$1" hdr="$2" file="$3" lm ym
    ym=$(exif_year_month "$file" || true)
    if [[ "$ym" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
        printf '%s' "$ym"; return 0
    fi
    lm=$(http_header "$hdr" last-modified)
    if [[ -n "$lm" ]]; then
        ym=$(date -u -d "$lm" +%Y-%m 2>/dev/null || true)
        if [[ "$ym" =~ ^[0-9]{4}-[0-9]{2}$ && "$ym" != "1970-01" ]]; then
            printf '%s' "$ym"; return 0
        fi
    fi
    ym=$(ccapi_curl 30 "$(ccapi_url "$loc")?kind=info" 2>/dev/null | json_year_month || true)
    if [[ "$ym" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
        printf '%s' "$ym"; return 0
    fi
    return 1
}

# Download one file over CCAPI into staging, verify it arrived whole, work out
# which month it belongs to, then move it into place. Never returns 2: CCAPI
# addresses files by path, so there is no index to go stale.
fetch_file_ccapi() {
    local loc="$1" expect="$2"
    local url tmp hdr bytes clen ym dst

    url="$(ccapi_url "$loc")"
    tmp="$STAGING_DIR/$expect"
    hdr="$STAGING_DIR/.headers"
    # Clear just this file's two artefacts. The staging directory itself is
    # created once per run and wiped by the EXIT trap; tearing it down and
    # recreating it per file cost two metadata operations each on a fuseblk
    # mount, for no benefit.
    rm -f "$tmp" "$hdr"

    ccapi_curl "$CCAPI_FETCH_TIMEOUT" -D "$hdr" -o "$tmp" "$url" || return 1
    if [[ ! -s "$tmp" ]]; then
        echo "WARNING: '$expect' came back empty — discarding."
        return 1
    fi

    # Content-Length is exact, so a short read is caught outright rather than by
    # the tolerance the USB path needs for gphoto2's whole-KB reporting.
    bytes=$(stat -c %s "$tmp")
    clen=$(http_header "$hdr" content-length)
    if [[ "$clen" =~ ^[0-9]+$ ]] && (( clen > 0 )) && (( bytes != clen )); then
        echo "WARNING: '$expect' is $bytes bytes but Content-Length said $clen — truncated, discarding."
        return 1
    fi

    # The YYYY/MM layout is keyed on capture date. gphoto2 supplied it through
    # %Y/%m; CCAPI has to be asked. Filing a photo under the wrong month is
    # worse than not filing it, so a file with no determinable date is dropped
    # and retried rather than being parked under some epoch default.
    ym="$(ccapi_year_month "$loc" "$hdr" "$tmp")" || {
        echo "WARNING: no capture date for '$expect' — discarding rather than filing it wrongly."
        return 1
    }

    dst="$DEST_BASE/${ym%%-*}/${ym##*-}/$expect"
    ensure_dest_dir "${dst%/*}" || return 1
    mv -f "$tmp" "$dst" || return 1
    return 0
}

# $1 locator, $2 expected filename, $3 size hint (USB only).
fetch_file() {
    case "$ACTIVE_TRANSPORT" in
        usb)   fetch_file_usb "$1" "$2" "${3:-0}" ;;
        ccapi) fetch_file_ccapi "$1" "$2" ;;
        *)     return 1 ;;
    esac
}

# ─── Detect camera ─────────────────────────────────────────────────────────────
# USB: gphoto2 auto-detect, checking for the camera brand name.
# Change CAMERA_DETECT_NAME in config.yml if you use a non-Canon camera.
# ccapi: a TCP probe of the camera's CCAPI port (see camera_present).
M_PHASE=detect
metrics_tick
if ! resolve_transport; then
    echo "ERROR: no $CAMERA_DETECT_NAME camera found."
    if [[ "$TRANSPORT" != ccapi ]]; then
        echo "  USB:   not connected (or gvfs is holding the device)."
    fi
    if [[ "$TRANSPORT" != usb ]]; then
        if [[ -z "$CAMERA_MAC" ]]; then
            echo "  Wi-Fi: no camera_mac set in config.yml, so nothing to look for."
        elif [[ -z "$CAMERA_IP" ]]; then
            echo "  Wi-Fi: MAC $CAMERA_MAC is not on this network."
            echo "         Switch the camera on and check it has joined Wi-Fi."
        else
            echo "  Wi-Fi: $CAMERA_IP is up but nothing answers on port $CCAPI_PORT."
            echo "         On the camera: MENU > Wi-Fi settings > Camera Control API"
            echo "         > Connect. If that menu entry is missing, CCAPI has not"
            echo "         been activated — see the Wi-Fi section of README.md."
        fi
    fi
    M_CAMERA_ABSENT=1
    exit "$ABSENT_EXIT_CODE"
fi

M_CAMERA_REACHABLE=1
M_PHASE=listing
metrics_tick

# Wait for the filesystem to stabilize. USB only: this exists to let device
# enumeration settle, and there is no network equivalent.
if [[ "$ACTIVE_TRANSPORT" == usb ]]; then
    sleep 2
fi

INDEX_RC=0
build_index || INDEX_RC=$?
if (( INDEX_RC != 0 )); then
    if (( INDEX_RC == 2 )); then
        # USB only: gphoto2 talked to the camera and it reported no files.
        # Nothing to fetch, and nothing wrong — a genuine in-sync outcome.
        echo "No files found on camera (card is empty)."
        M_SYNC_OK=1
        exit 0
    fi
    if [[ "$ACTIVE_TRANSPORT" == ccapi ]]; then
        # Over USB an empty listing genuinely means an empty card. Over CCAPI it
        # far more often means the request failed — and reporting that as success
        # would have a polling timer silently claim everything is fine forever.
        echo "First listing failed; retrying once in 5s..."
        sleep 5
        if ! build_index; then
            echo "ERROR: reached $CAMERA_IP but could not read the file listing."
            echo "Check the camera shows [Wi-Fi on] for Camera Control API, then"
            echo "try by hand:"
            echo "  curl -sS http://$CAMERA_IP:$CCAPI_PORT/ccapi"
            exit 1
        fi
    else
        echo "ERROR: the camera is connected but its file listing could not be read."
        echo "gvfs may have grabbed the device, or the USB link dropped mid-listing."
        echo "Try by hand:  gphoto2 --list-files"
        exit 1
    fi
fi

M_PHASE=scan
metrics_tick

# ─── Read previous sync state (format: count:last_filename) ────────────────────
LAST_COUNT=0
LAST_FILE=""
if [[ -f "$STATE_FILE" ]]; then
    STATE=$(cat "$STATE_FILE")
    LAST_COUNT=${STATE%%:*}
    LAST_FILE=${STATE#*:}
    # Validate that count is numeric
    if ! [[ "$LAST_COUNT" =~ ^[0-9]+$ ]]; then
        LAST_COUNT=0
        LAST_FILE=""
    fi
fi

# Quick exit: nothing changed on camera
if (( CAMERA_COUNT == LAST_COUNT )) && [[ "$LAST_CAMERA_FILE" == "$LAST_FILE" ]]; then
    echo "No new files ($CAMERA_COUNT on camera, all previously synced)."
    M_SYNC_OK=1
    exit 0
fi

# Only now touch the destination drive: a run triggered with no camera attached
# should fail on the detect check above, not on creating directories here.
mkdir -p "$STAGING_DIR"

# ─── Work out what is missing ──────────────────────────────────────────────────
# Build set of local filenames for fast lookup. Anything under the staging
# directory is in-flight, not synced, so it must not count as present — matched
# on the relative path as a plain string, since a dest_base containing glob
# metacharacters would defeat find's -path pattern.
declare -A LOCAL_SET
while IFS=$'\t' read -r relpath fname; do
    [[ "$relpath" == "$STAGING_NAME/"* ]] && continue
    LOCAL_SET["$fname"]=1
done < <(find "$DEST_BASE" -type f -printf '%P\t%f\n')

MISSING_NAMES=()
for name in "${CAMERA_NAMES[@]}"; do
    if [[ -z "${LOCAL_SET[$name]+x}" ]]; then
        MISSING_NAMES+=("$name")
    fi
done

# Snapshot the listing these MISSING_NAMES were derived from. The download loop
# re-runs build_index on a stale index or after a reconnect, which refreshes
# CAMERA_COUNT and LAST_CAMERA_FILE — but not MISSING_NAMES. Writing the newer
# figures to the state file would tell the next run that a listing it never
# worked through is fully synced, and its quick-exit would skip those files for
# good. The state file must describe what this run actually covered.
SYNCED_COUNT="$CAMERA_COUNT"
SYNCED_LAST_FILE="$LAST_CAMERA_FILE"

M_RUN_TOTAL=${#MISSING_NAMES[@]}
M_PHASE=download
# Hard emit, not a tick: this publishes run_files_queued, the denominator the
# progress gauge divides by. Suppressing it would leave the dashboard at 0/0
# for the first stretch of a long download.
metrics_emit

# DRY_RUN=1 reports what would be fetched and stops. Worth having whenever the
# transport or destination changes, before committing to a long transfer.
if [[ "${DRY_RUN:-0}" == 1 ]]; then
    echo "DRY RUN: ${#MISSING_NAMES[@]} of $CAMERA_COUNT camera file(s) missing locally."
    if (( ${#MISSING_NAMES[@]} > 0 )); then
        printf '  %s\n' "${MISSING_NAMES[@]}"
    fi
    exit 0
fi

# ─── Download ──────────────────────────────────────────────────────────────────
ABORTED=0
FAILED=()

if [[ ${#MISSING_NAMES[@]} -eq 0 ]]; then
    echo "All $CAMERA_COUNT files already exist locally."
else
    echo "Downloading ${#MISSING_NAMES[@]} new file(s)..."
    CONSECUTIVE_FAILS=0
    ATTEMPTED=0
    GONE=0

    for name in "${MISSING_NAMES[@]}"; do
        # Throttled internally, so once per file is cheap and every outcome
        # branch below is covered without repeating the call in each.
        metrics_tick
        loc="${LOC_FOR_NAME[$name]:-}"
        if [[ -z "$loc" ]]; then
            echo "WARNING: '$name' is no longer on the camera — skipping."
            FAILED+=("$name")
            GONE=$(( GONE + 1 ))
            M_RUN_FAILED=$(( M_RUN_FAILED + 1 ))
            continue
        fi

        ATTEMPTED=$(( ATTEMPTED + 1 ))
        rc=0
        fetch_file "$loc" "$name" "${KB_FOR_NAME[$name]:-0}" || rc=$?

        # A stale index means the listing, not the file, is wrong: re-read it
        # and retry immediately with the correct locator rather than burning
        # this file (and the next two) on the generic retry path. Only the USB
        # path can produce this; CCAPI addresses files by path.
        if (( rc == 2 )); then
            if build_index; then
                loc="${LOC_FOR_NAME[$name]:-}"
                if [[ -n "$loc" ]]; then
                    rc=0
                    fetch_file "$loc" "$name" "${KB_FOR_NAME[$name]:-0}" || rc=$?
                else
                    rc=1
                fi
            else
                rc=1
            fi
        fi

        if (( rc == 0 )); then
            CONSECUTIVE_FAILS=0
            M_RUN_DOWNLOADED=$(( M_RUN_DOWNLOADED + 1 ))
            continue
        fi

        echo "WARNING: Failed '$name', retrying in 3s..."
        sleep 3
        rc=0
        fetch_file "$loc" "$name" "${KB_FOR_NAME[$name]:-0}" || rc=$?
        if (( rc == 0 )); then
            CONSECUTIVE_FAILS=0
            M_RUN_DOWNLOADED=$(( M_RUN_DOWNLOADED + 1 ))
            continue
        fi

        echo "ERROR: Skipping '$name' after retry failure."
        FAILED+=("$name")
        CONSECUTIVE_FAILS=$(( CONSECUTIVE_FAILS + 1 ))
        M_RUN_FAILED=$(( M_RUN_FAILED + 1 ))

        # A dropped USB link fails every remaining file. Without this check the
        # loop would burn two attempts plus a 3s sleep on each one, turning a
        # momentary disconnect into a long run that needlessly marks hundreds of
        # files as failed. Stop as soon as the camera is confirmed gone.
        if (( CONSECUTIVE_FAILS >= MAX_CONSECUTIVE_FAILS )); then
            if ! camera_present; then
                echo "ERROR: camera no longer detected after $CONSECUTIVE_FAILS consecutive failures — aborting run."
                ABORTED=1
                break
            fi
            # Still reachable, so this was likely a reconnect: any indices from
            # the previous session are stale and must be re-read.
            echo "Camera still attached; re-reading file index after $CONSECUTIVE_FAILS consecutive failures..."
            if build_index; then
                CONSECUTIVE_FAILS=0
            else
                echo "ERROR: could not re-read camera listing — aborting run."
                ABORTED=1
                break
            fi
        fi

        if (( ${#FAILED[@]} >= MAX_TOTAL_FAILS )); then
            echo "ERROR: ${#FAILED[@]} failures this run — aborting rather than sweeping the whole card."
            ABORTED=1
            break
        fi
    done

    if (( ABORTED == 1 )) || (( ${#FAILED[@]} > 0 )); then
        echo "WARNING: ${#FAILED[@]} file(s) failed: ${FAILED[*]}"
        if (( ABORTED == 1 )); then
            NOT_ATTEMPTED=$(( ${#MISSING_NAMES[@]} - ATTEMPTED - GONE ))
            (( NOT_ATTEMPTED > 0 )) && echo "$NOT_ATTEMPTED file(s) not attempted (run aborted early)."
        fi
        echo "State file NOT updated — next run will retry."
        chown -R "$OWNER_USER:$OWNER_GROUP" "$DEST_BASE"
        exit 1
    fi
fi

# Update sync state only on full success (count:last_filename). Deliberately the
# snapshot taken before the download loop, not the live values — see above.
echo "${SYNCED_COUNT}:${SYNCED_LAST_FILE}" > "$STATE_FILE"
M_SYNC_OK=1

# Set ownership so the non-root user can access the downloaded files
chown -R "$OWNER_USER:$OWNER_GROUP" "$DEST_BASE"

echo "Sync complete. Files saved to $DEST_BASE"
