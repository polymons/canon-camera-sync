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
# CAMERA_SYNC_REFRESH joins DRY_RUN here for the same reason: these counters
# describe the arrival of new photos, and a refresh deliberately never looks at
# the missing set. Letting metrics_final run would stamp files_pending=0 for a
# question this run never asked, move last_success_timestamp_seconds and add a
# runs_total entry. Read the environment variable directly — REFRESH_MODE is
# derived much further down, long after this line.
if [[ -d "$METRICS_DIR" && -w "$METRICS_DIR" && "${DRY_RUN:-0}" != 1 \
      && -z "${CAMERA_SYNC_REFRESH:-}" ]]; then
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
# Geo review, run-scoped. Initialised here with the M_* counters and for the
# same reason: the EXIT trap emits metrics from whichever exit it fires on, and
# under `set -u` an unset name there would replace the real failure with a
# confusing one.
G_CHECKED=0
G_CHANGED=0
G_PROMOTED=0
G_ERRORS=0
G_BYTES=0
G_BUDGET_EXHAUSTED=0
G_RAN=0
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

    # The geo one-hot series encode a string verdict as a set of labelled 0/1
    # gauges, which the numeric filter above stores under labelled keys. Fold the
    # set member back into the plain scalar the emitter reads, so a poll that
    # finds no camera — and so never opens the ledger — republishes the last
    # known verdict instead of flapping the panel back to "unknown" several
    # times an hour.
    local kk
    for kk in unknown proven disproven; do
        k="geo_premise{verdict=\"$kk\"}"
        [[ "${MSTATE[$k]:-0}" == 1 ]] && MSTATE[geo_premise]="$kk"
    done
    for kk in unknown yes no; do
        k="geo_range_supported{transport=\"ccapi\",state=\"$kk\"}"
        [[ "${MSTATE[$k]:-0}" == 1 ]] && MSTATE[geo_range_ccapi]="$kk"
    done
    return 0
}

metrics_emit() {
    (( METRICS_ENABLED )) || return 0
    local tmp now dl fl label key p gdl gpr
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
        for label in idle startup detect listing scan download geo; do
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

        # ── Geotag review ──────────────────────────────────────────────────
        # Every archive-wide figure below is read from the ledger through
        # MSTATE, never recomputed here. Two reasons. A poll that finds no
        # camera never looks at the archive, and publishing a locally-derived 0
        # would make the coverage panel collapse to zero several times an hour.
        # And a hand-run CAMERA_SYNC_REFRESH writes its findings into the ledger
        # with metrics disabled, so routing everything through MSTATE is what
        # lets the next automatic tick publish work done by hand.
        printf '# HELP canon_sync_geo_enabled 1 when the geotag review is armed to do work.\n'
        printf '# TYPE canon_sync_geo_enabled gauge\n'
        printf 'canon_sync_geo_enabled %s\n' "${MSTATE[geo_enabled]:-0}"

        # One-hot, like canon_sync_phase: every value is always emitted so no
        # series goes stale, and "never established" is a visible state rather
        # than a sentinel number.
        printf '# HELP canon_sync_geo_premise Whether the card has ever been seen to gain coordinates after capture.\n'
        printf '# TYPE canon_sync_geo_premise gauge\n'
        for label in unknown proven disproven; do
            p=0
            [[ "${MSTATE[geo_premise]:-unknown}" == "$label" ]] && p=1
            printf 'canon_sync_geo_premise{verdict="%s"} %d\n' "$label" "$p"
        done

        printf '# HELP canon_sync_geo_range_supported Whether CCAPI serves partial downloads; without it a GPS check costs a whole file.\n'
        printf '# TYPE canon_sync_geo_range_supported gauge\n'
        for label in unknown yes no; do
            p=0
            [[ "${MSTATE[geo_range_ccapi]:-unknown}" == "$label" ]] && p=1
            printf 'canon_sync_geo_range_supported{transport="ccapi",state="%s"} %d\n' "$label" "$p"
        done

        printf '# HELP canon_sync_geo_stills Local JPG/CR3 files the review considers.\n'
        printf '# TYPE canon_sync_geo_stills gauge\n'
        printf 'canon_sync_geo_stills %s\n' "${MSTATE[geo_stills]:-0}"

        printf '# HELP canon_sync_geo_geotagged Local stills that already carry coordinates.\n'
        printf '# TYPE canon_sync_geo_geotagged gauge\n'
        printf 'canon_sync_geo_geotagged %s\n' "${MSTATE[geo_geotagged]:-0}"

        printf '# HELP canon_sync_geo_candidates Stills with no coordinates that are still on the card and unresolved.\n'
        printf '# TYPE canon_sync_geo_candidates gauge\n'
        printf 'canon_sync_geo_candidates %s\n' "${MSTATE[geo_candidates]:-0}"

        printf '# HELP canon_sync_geo_settled Stills checked against the card, whose card copy has no coordinates either.\n'
        printf '# TYPE canon_sync_geo_settled gauge\n'
        printf 'canon_sync_geo_settled %s\n' "${MSTATE[geo_settled]:-0}"

        printf '# HELP canon_sync_geo_unreachable Stills with no coordinates that are no longer on the card, so the camera can never supply them.\n'
        printf '# TYPE canon_sync_geo_unreachable gauge\n'
        printf 'canon_sync_geo_unreachable %s\n' "${MSTATE[geo_unreachable]:-0}"

        printf '# HELP canon_sync_geo_ambiguous Stills whose basename exists at more than one local path.\n'
        printf '# TYPE canon_sync_geo_ambiguous gauge\n'
        printf 'canon_sync_geo_ambiguous %s\n' "${MSTATE[geo_ambiguous]:-0}"

        printf '# HELP canon_sync_geo_ledger_rows Rows in the geotag ledger.\n'
        printf '# TYPE canon_sync_geo_ledger_rows gauge\n'
        printf 'canon_sync_geo_ledger_rows %s\n' "${MSTATE[geo_ledger_rows]:-0}"

        printf '# HELP canon_sync_geo_last_pass_timestamp_seconds Unix time the candidate queue was last fully drained; 0 if never.\n'
        printf '# TYPE canon_sync_geo_last_pass_timestamp_seconds gauge\n'
        printf 'canon_sync_geo_last_pass_timestamp_seconds %s\n' "${MSTATE[geo_last_pass_timestamp_seconds]:-0}"

        printf '# HELP canon_sync_geo_last_promote_timestamp_seconds Unix time a file last gained coordinates from the card; 0 if never.\n'
        printf '# TYPE canon_sync_geo_last_promote_timestamp_seconds gauge\n'
        printf 'canon_sync_geo_last_promote_timestamp_seconds %s\n' "${MSTATE[geo_last_promote_timestamp_seconds]:-0}"

        # Per-run figures come from the live counters: they describe this run,
        # so a run that did no review should publish zeroes rather than the
        # previous run's numbers.
        printf '# HELP canon_sync_geo_run_checked Files examined on the card by this run.\n'
        printf '# TYPE canon_sync_geo_run_checked gauge\n'
        printf 'canon_sync_geo_run_checked %d\n' "$G_CHECKED"

        printf '# HELP canon_sync_geo_run_changed Files whose card-side metadata differed from the ledger.\n'
        printf '# TYPE canon_sync_geo_run_changed gauge\n'
        printf 'canon_sync_geo_run_changed %d\n' "$G_CHANGED"

        printf '# HELP canon_sync_geo_run_promoted Files replaced with a geotagged card copy by this run.\n'
        printf '# TYPE canon_sync_geo_run_promoted gauge\n'
        printf 'canon_sync_geo_run_promoted %d\n' "$G_PROMOTED"

        printf '# HELP canon_sync_geo_run_errors Card-side checks this run could not complete.\n'
        printf '# TYPE canon_sync_geo_run_errors gauge\n'
        printf 'canon_sync_geo_run_errors %d\n' "$G_ERRORS"

        printf '# HELP canon_sync_geo_run_bytes Bytes pulled from the camera by the review this run.\n'
        printf '# TYPE canon_sync_geo_run_bytes gauge\n'
        printf 'canon_sync_geo_run_bytes %d\n' "$G_BYTES"

        printf '# HELP canon_sync_geo_run_budget_exhausted 1 if the review stopped on a budget rather than finishing.\n'
        printf '# TYPE canon_sync_geo_run_budget_exhausted gauge\n'
        printf 'canon_sync_geo_run_budget_exhausted %d\n' "$G_BUDGET_EXHAUSTED"

        gdl=$(( ${MSTATE[geo_checked_total]:-0} + G_CHECKED ))
        gpr=$(( ${MSTATE[geo_promoted_total]:-0} + G_PROMOTED ))
        printf '# HELP canon_sync_geo_checked_total Card-side checks since this file was created.\n'
        printf '# TYPE canon_sync_geo_checked_total counter\n'
        printf 'canon_sync_geo_checked_total %d\n' "$gdl"

        printf '# HELP canon_sync_geo_promoted_total Files that gained coordinates from the card since this file was created.\n'
        printf '# TYPE canon_sync_geo_promoted_total counter\n'
        printf 'canon_sync_geo_promoted_total %d\n' "$gpr"

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
    # This run's own ledger write target, if it died mid-save. Only ever ours:
    # the name carries the pid, and the flock guarantees no sibling run.
    [[ -n "${GEO_DIR:-}" ]] && rm -f "$GEO_DIR/.ledger.$$.tmp" 2>/dev/null
    # A sniff is a partial file with no value beyond the check that produced it.
    [[ -n "${GEO_SNIFF_FILE:-}" ]] && rm -f "$GEO_SNIFF_FILE" "$GEO_SNIFF_FILE.headers" 2>/dev/null
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
# A sniff is 256 KiB, not a whole file, so it gets its own much shorter budget.
CCAPI_SNIFF_TIMEOUT=60

# How much of a file the geo review pulls to answer "does the card copy have
# coordinates?". This is NOT a tunable and must never become a config key: it is
# equal to HEADER_BYTES inside has_gps(), and that equality is the entire reason
# a 256 KiB sniff gives the same answer as the whole file. has_gps() cannot read
# past this offset, so a Range request exactly this long is not an approximation
# of the full test — it is the full test. Lower it and CR3s, whose GPS block
# sits around 7.5 KB in but whose Exif can be laid out differently, would start
# answering "no coordinates" for files that have them.
GEO_SNIFF_BYTES=262144

ACTIVE_TRANSPORT=""
CAMERA_IP=""        # discovered from camera_mac at run time
CCAPI_CONTENTS=""   # the /contents URL, discovered from GET /ccapi

# ─── Refresh mode ──────────────────────────────────────────────────────────────
# Normal syncing only ever fetches files that are *absent* locally. Refresh mode
# inverts that: it re-fetches files that are already here in order to pick up
# metadata the camera did not have at capture time — the case this was written
# for is a body with no GPS receiver, which records coordinates only while the
# phone's Bluetooth location feed is connected. Shots taken while that link was
# down carry a GPS block with no latitude/longitude, and the card copy only
# improves once the link is restored.
#
# It is deliberately an environment variable and not a config.yml key: no unit
# file sets it, so the udev, SSDP and timer paths cannot reach this code at all.
#
#   CAMERA_SYNC_REFRESH=probe   fetch ONE candidate, report, promote nothing
#   CAMERA_SYNC_REFRESH=run     fetch every candidate, promote the ones that gain GPS
#   CAMERA_SYNC_REFRESH_SCOPE   relative path prefix to limit the run, e.g. 2026/09
REFRESH_MODE="${CAMERA_SYNC_REFRESH:-}"
REFRESH_SCOPE="${CAMERA_SYNC_REFRESH_SCOPE:-}"
# Set while a download must land in quarantine to be compared against the copy
# it might replace, rather than on that copy's own path. The manual refresh sets
# it for its whole run; the automatic review sets it only for its own phase, so
# the new-photo download loop before it still writes straight through.
QUARANTINE_ACTIVE=0
[[ -n "$REFRESH_MODE" ]] && QUARANTINE_ACTIVE=1
# 1 only while geo_phase is executing. refresh_commit is shared by both paths
# and needs to know which one is calling it.
GEO_ACTIVE=0
# Stop a run whose premise is wrong. If this many card copies in a row turn out
# to have no coordinates either and nothing has been promoted yet, the phone
# link was not feeding the camera for this batch and the remaining files will
# be no different — there is no sense pulling gigabytes to keep proving it.
# 0 disables the guard.
REFRESH_GIVEUP="${CAMERA_SYNC_REFRESH_GIVEUP:-10}"

if [[ -n "$REFRESH_MODE" ]]; then
    if [[ "$REFRESH_MODE" != probe && "$REFRESH_MODE" != run ]]; then
        echo "ERROR: CAMERA_SYNC_REFRESH must be 'probe' or 'run' (got '$REFRESH_MODE')."
        exit 1
    fi
    # Unscoped, the candidate set is every card file whose local copy lacks GPS,
    # which on this archive is thousands of files across years that were shot
    # without the phone link and will never improve. Requiring a scope keeps a
    # refresh an explicit, bounded operation rather than a full-card sweep.
    if [[ "$REFRESH_MODE" == run && -z "$REFRESH_SCOPE" ]]; then
        echo "ERROR: CAMERA_SYNC_REFRESH=run requires CAMERA_SYNC_REFRESH_SCOPE."
        echo "       Example: CAMERA_SYNC_REFRESH_SCOPE=2026/09"
        exit 1
    fi
    # A scope is matched as a literal path prefix, so an absolute path or one
    # that climbs out of the tree is a mistake worth catching early.
    if [[ "$REFRESH_SCOPE" == /* || "$REFRESH_SCOPE" == *..* ]]; then
        echo "ERROR: CAMERA_SYNC_REFRESH_SCOPE must be a relative path inside the archive."
        exit 1
    fi
fi

# ─── Geotag review ─────────────────────────────────────────────────────────────
# Refresh mode above is the manual, scoped version of this. The review is the
# automatic one: it runs at the end of an ordinary sync, so every event that
# already starts a sync — the udev rule on USB connect, canon-camera-watch.py on
# an SSDP announcement, the safety-net timer — also asks whether the card has
# since gained coordinates for files the archive already holds.
#
# What makes that affordable is a ledger of what the card looked like last time
# (see the "Geotag ledger" block further down). A file whose card-side size and
# timestamp are unchanged cannot have gained anything and is not re-examined, so
# the steady-state cost of an event is a listing comparison and nothing else.
#
#   geo_review: auto   run when the ledger says there is something to look at
#   geo_review: off    never run; the manual CAMERA_SYNC_REFRESH path still works
#   geo_review: force  run every event, ignoring geo_min_interval_seconds
#
# CAMERA_SYNC_GEO overrides the config key and adds three operator verbs:
#
#   rearm    re-open a premise the ledger has written off, then run normally
#   plan     print what a run would examine and why; fetch and write nothing
#   status   print the ledger summary and exit; touch neither camera nor disk
GEO_MODE="${CAMERA_SYNC_GEO:-$(yml_get geo_review)}"
GEO_MODE="${GEO_MODE:-auto}"

# Read every budget through this so a config key, an environment override and a
# default all land in one place, and a non-numeric value in any of the three
# fails loudly here rather than as an arithmetic error 1200 lines later.
geo_num() {
    local key="$1" def="$2" env_name="$3" v
    v="${!env_name:-}"
    [[ -n "$v" ]] || v="$(yml_get "$key")"
    v="${v:-$def}"
    if ! [[ "$v" =~ ^[0-9]+$ ]]; then
        echo "ERROR: $key must be a non-negative integer (got '$v')."
        exit 1
    fi
    printf '%s' "$v"
}

# Per-transport, because the two events mean different things. A cable being
# plugged in is deliberate and the link runs at ~10 MB/s, so it can afford a
# long pass; a Wi-Fi announcement is incidental — the camera may be switched off
# again in a minute — so it takes a smaller bite and resumes on the next one.
GEO_BUDGET_FILES_USB="$(geo_num geo_budget_files_usb 150 CAMERA_SYNC_GEO_BUDGET_FILES_USB)"
GEO_BUDGET_FILES_CCAPI="$(geo_num geo_budget_files_ccapi 400 CAMERA_SYNC_GEO_BUDGET_FILES_CCAPI)"
# Used only when the camera turns out not to honour HTTP Range, in which case
# every check costs a whole file instead of 256 KiB and the budget has to drop
# by two orders of magnitude to match.
GEO_BUDGET_FILES_CCAPI_FULL="$(geo_num geo_budget_files_ccapi_full 20 CAMERA_SYNC_GEO_BUDGET_FILES_CCAPI_FULL)"
GEO_BUDGET_SECONDS_USB="$(geo_num geo_budget_seconds_usb 900 CAMERA_SYNC_GEO_BUDGET_SECONDS_USB)"
GEO_BUDGET_SECONDS_CCAPI="$(geo_num geo_budget_seconds_ccapi 300 CAMERA_SYNC_GEO_BUDGET_SECONDS_CCAPI)"

# The premise ladder. Whether this camera ever writes coordinates onto a card
# file after capture is an empirical question, and on this archive 93% of stills
# have an empty GPS block — so a single miss proves nothing, it is just the base
# rate. Until a hit is seen the review spends only geo_probe_files checks per
# event; after geo_giveup cumulative misses with no hit at all it writes the
# premise off and stops, which costs one wasted event's worth of traffic rather
# than a full-card sweep. Both counters live in the ledger, so they accumulate
# across events instead of resetting per run the way REFRESH_GIVEUP does.
GEO_PROBE_FILES="$(geo_num geo_probe_files 5 CAMERA_SYNC_GEO_PROBE_FILES)"
GEO_GIVEUP="$(geo_num geo_giveup 25 CAMERA_SYNC_GEO_GIVEUP)"
# A written-off premise still has to be able to come back, or a location merge
# run next year would never be noticed. Two routes, both cheap: a rotation of
# metadata-only probes over files the ledger has already settled, and — on USB,
# for free — the whole-KB sizes in the listing itself.
GEO_REARM_PROBE_FILES="$(geo_num geo_rearm_probe_files 25 CAMERA_SYNC_GEO_REARM_PROBE_FILES)"
GEO_REARM_KB_THRESHOLD="$(geo_num geo_rearm_kb_threshold 3 CAMERA_SYNC_GEO_REARM_KB_THRESHOLD)"

# One power-on produces a burst of SSDP announcements and the camera re-announces
# every ~15 minutes, so without this a settled ledger would be re-walked several
# times an hour to reach the same conclusion.
GEO_MIN_INTERVAL="$(geo_num geo_min_interval_seconds 3600 CAMERA_SYNC_GEO_MIN_INTERVAL_SECONDS)"
# Firmware updates happen; a camera that refused Range once should be asked again.
GEO_RANGE_RECHECK_DAYS="$(geo_num geo_range_recheck_days 30 CAMERA_SYNC_GEO_RANGE_RECHECK_DAYS)"
GEO_LEDGER_MAX_ROWS="$(geo_num geo_ledger_max_rows 20000 CAMERA_SYNC_GEO_LEDGER_MAX_ROWS)"
# Batched `gphoto2 --show-info` is how the USB path gets exact byte sizes. Set to
# 0 if a firmware/driver combination produces output this cannot parse; the
# review then falls back to downloading, which is correct but far more expensive.
GEO_SHOW_INFO_BATCH="$(geo_num geo_show_info_batch 1 CAMERA_SYNC_GEO_SHOW_INFO_BATCH)"

GEO_REARM_REQUESTED=0
GEO_PLAN_ONLY=0
GEO_STATUS_ONLY=0
case "$GEO_MODE" in
    auto|off|force) ;;
    rearm)  GEO_REARM_REQUESTED=1; GEO_MODE=force ;;
    plan)   GEO_PLAN_ONLY=1;       GEO_MODE=force ;;
    status) GEO_STATUS_ONLY=1;     GEO_MODE=force ;;
    *)
        echo "ERROR: geo_review must be 'auto', 'off' or 'force' (got '$GEO_MODE')."
        echo "       CAMERA_SYNC_GEO additionally accepts 'rearm', 'plan' and 'status'."
        exit 1
        ;;
esac

# A refresh is the operator doing this by hand, with their own scope and their
# own judgement about what to promote. Running the automatic review inside it
# would fight it for the quarantine directory and the budget.
[[ -n "$REFRESH_MODE" ]] && GEO_MODE=off

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

# Exact size and last-modified time for one file, out of a CCAPI ?kind=info
# response. Prints "bytes<TAB>mtime_epoch", either field 0 when absent.
#
# Shape-based, like json_ccapi_paths above, and for the same reason: the key
# names in these responses have differed between firmware versions, and this one
# is unverified on the M50 II. A walker that looks for a plausible size under
# any size-ish key survives a rename; a hardcoded key silently returns nothing
# and turns every check into a download.
json_file_info() {
    python3 -c '
import json, re, sys
from email.utils import parsedate_to_datetime
from datetime import timezone

SIZE_KEY = re.compile(r"(size|bytes|filesize|length)", re.I)
DATE_KEY = re.compile(r"(date|time|modified)", re.I)
DATE_TXT = re.compile(r"(19|20)\d\d[-:/](0[1-9]|1[0-2])[-:/](0[1-9]|[12]\d|3[01])")

best_size = 0
best_date = 0

def as_epoch(v):
    if not isinstance(v, str):
        return 0
    s = v.strip()
    m = DATE_TXT.search(s)
    if m:
        # Canon writes EXIF-style "2026:09:04 21:22:11". Normalise separators in
        # the date half ONLY: doing it across the whole string would eat the
        # colons out of the time in an ISO "2026-01-02T03:04:05".
        seg = s[m.start():m.start() + 19]
        t = (seg[:10].replace(":", "-").replace("/", "-") + seg[10:]).replace("T", " ").strip()
        try:
            import datetime as _dt
            return int(_dt.datetime.fromisoformat(t).timestamp())
        except Exception:
            pass
    try:
        d = parsedate_to_datetime(s)
    except Exception:
        return 0
    if d is None or not (1990 <= d.year <= 2100):
        return 0
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return int(d.timestamp())

def walk(o):
    global best_size, best_date
    if isinstance(o, dict):
        for k, v in o.items():
            if isinstance(v, bool):
                pass
            elif isinstance(v, int) and SIZE_KEY.search(k) and v > best_size:
                best_size = v
            elif isinstance(v, str) and SIZE_KEY.search(k) and v.isdigit() and int(v) > best_size:
                best_size = int(v)
            elif isinstance(v, str) and DATE_KEY.search(k):
                e = as_epoch(v)
                if e > best_date:
                    best_date = e
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)

try:
    walk(json.load(sys.stdin))
except Exception:
    sys.exit(1)
print("%d\t%d" % (best_size, best_date))
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

# ─── GPS coordinates ───────────────────────────────────────────────────────────
# Whether a file carries real coordinates, and what they are. Same bounded-read,
# no-exiftool approach as exif_year_month above; 256 KiB is ample, as a CR3 keeps
# its GPS block ~7.5 KB in.
#
# Presence of the GPS IFD is NOT enough. A body that records location only while
# a phone is linked still writes a GPS block when the link is down — it just has
# GPSVersionID/GPSAltitudeRef/GPSSatellites/GPSStatus/GPSMeasureMode and no
# GPSLatitude (0x2) or GPSLongitude (0x4). Distinguishing those two states is the
# entire point of this code, so it decodes the rationals and rejects 0/0.
#
# Three verdicts, because "no coordinates" and "cannot tell" are different
# answers and the geo ledger has to record them differently:
#
#   0  coordinates found
#   1  header parsed, GPS IFD reached, no usable latitude/longitude  -> settled
#   2  header not parseable at all (not a JPEG or CR3, truncated, no
#      Exif/CMT4 block, unreadable)                                  -> retry
#
# The parser is held in one variable and shared by both entry points below.
# Duplicating it would be the obvious maintenance trap: the single-file and
# whole-archive paths must never be able to disagree about whether a file is
# geotagged, because the review compares one against the other to decide whether
# to overwrite a photo.
GPS_PY='
import struct, sys

# Must stay equal to GEO_SNIFF_BYTES in the tunables block. That equality is the
# whole reason a 256 KiB sniff of a card file gives the same answer as the
# complete file: this read cannot see past the offset the Range request stops at,
# so the sniff is not an approximation of the test, it is the test.
HEADER_BYTES = 262144


def verdict(path):
    """Return (code, "lat,lon") for one file."""
    try:
        with open(path, "rb") as fh:
            d = fh.read(HEADER_BYTES)
    except Exception:
        return 2, ""

    def read_ifd(base, off):
        bo = ">" if d[base:base + 2] == b"MM" else "<"
        if base + off + 2 > len(d):
            return bo, {}
        n = struct.unpack(bo + "H", d[base + off:base + off + 2])[0]
        out = {}
        for i in range(n):
            e = base + off + 2 + i * 12
            if e + 12 > len(d):
                break
            tag, typ, cnt = struct.unpack(bo + "HHI", d[e:e + 8])
            out[tag] = (typ, cnt, d[e + 8:e + 12])
        return bo, out

    def first_ifd(base):
        if base + 8 > len(d) or d[base:base + 2] not in (b"MM", b"II"):
            return None
        bo = ">" if d[base:base + 2] == b"MM" else "<"
        return read_ifd(base, struct.unpack(bo + "I", d[base + 4:base + 8])[0])

    def coord(base, bo, entry):
        typ, cnt, raw = entry
        if typ != 5 or cnt < 3:
            return None
        off = struct.unpack(bo + "I", raw)[0]
        v = []
        for i in range(3):
            p = base + off + i * 8
            if p + 8 > len(d):
                return None
            num, den = struct.unpack(bo + "II", d[p:p + 8])
            v.append(num / den if den else 0.0)
        return v[0] + v[1] / 60 + v[2] / 3600

    def ref(gps, tag):
        if tag not in gps:
            return ""
        return gps[tag][2][:1].decode("ascii", "replace")

    base = None
    bo = "<"
    gps = None
    # True once a TIFF block has actually been decoded, which is what separates
    # "this file has no coordinates" from "this file could not be read".
    parsed = False
    if d[:2] == b"\xff\xd8":
        # JPEG: TIFF block sits after the APP1 Exif header; IFD0 tag 0x8825
        # points at the GPS IFD.
        k = d.find(b"Exif\x00\x00")
        if k >= 0:
            base = k + 6
            r = first_ifd(base)
            if r:
                bo, ifd0 = r
                parsed = True
                # No 0x8825 at all is a complete answer, not a failure: some
                # frames genuinely carry no GPS IFD.
                if 0x8825 in ifd0:
                    bo, gps = read_ifd(base, struct.unpack(bo + "I", ifd0[0x8825][2])[0])
    elif d[4:8] == b"ftyp":
        # CR3 is ISO-BMFF and has no APP1 segment. Its CMT4 box payload is a
        # bare TIFF block whose first IFD *is* the GPS IFD.
        j = d.find(b"CMT4")
        if j >= 0:
            base = j + 4
            r = first_ifd(base)
            if r:
                bo, gps = r
                parsed = True

    if not parsed:
        # Container unrecognised, or its Exif/CMT4 block was not in the first
        # HEADER_BYTES. Nothing was decoded, so nothing is known.
        return 2, ""
    if gps is None or 0x2 not in gps or 0x4 not in gps:
        return 1, ""
    lat = coord(base, bo, gps[0x2])
    lon = coord(base, bo, gps[0x4])
    if lat is None or lon is None or (lat == 0 and lon == 0):
        return 1, ""
    if ref(gps, 0x1) == "S":
        lat = -lat
    if ref(gps, 0x3) == "W":
        lon = -lon
    return 0, "%.6f,%.6f" % (lat, lon)


# Paths arrive NUL-separated on stdin, and each result carries its path back so
# the caller never has to trust that the two lists stayed in step.
#
# Field order matters. Tab is an IFS whitespace character, so bash `read`
# collapses a run of them into one separator — putting the frequently-empty
# coords between the code and the path would shift the path into the coords
# variable for every file without coordinates, which is most of them. The field
# that can be empty goes last, where losing it costs nothing.
data = sys.stdin.buffer.read()
paths = [p for p in data.split(b"\x00") if p]
out = []
for raw in paths:
    p = raw.decode("utf-8", "surrogateescape")
    code, coords = verdict(p)
    out.append("%d\t%s\t%s" % (code, p, coords))
sys.stdout.write("\n".join(out) + ("\n" if out else ""))
'

# One file. Prints "lat,lon" and returns 0/1/2 as documented above.
has_gps() {
    local line code
    line=$(printf '%s\0' "$1" | python3 -c "$GPS_PY" 2>/dev/null) || return 2
    [[ -n "$line" ]] || return 2
    code="${line%%$'\t'*}"
    case "$code" in
        0) printf '%s' "${line##*$'\t'}"; return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

# Many files, in a single interpreter. The review has to classify every card-
# resident still on a cold ledger — around 3000 files here — and at ~30 ms of
# Python startup each, per-file invocation would cost more than the interpreter
# spends actually reading the images. Paths in NUL-separated on stdin, lines of
# "code<TAB>coords<TAB>path" out.
has_gps_batch() {
    python3 -c "$GPS_PY" 2>/dev/null
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

# ─── Geo review: card-side inspection over CCAPI ───────────────────────────────

# Exact size and modification time for one file on the card, without downloading
# it. One ~200-byte request against ?kind=info, which is the cheapest question
# the review can ask and the one that settles most files: a card copy whose size
# and timestamp are unchanged cannot have gained coordinates.
#
# Prints "bytes<TAB>mtime_epoch"; either may be 0 when the firmware does not
# report it. Fails only when the request itself failed.
ccapi_file_info() {
    local loc="$1" out
    out=$(ccapi_curl 30 "$(ccapi_url "$loc")?kind=info" 2>/dev/null | json_file_info) || return 1
    [[ -n "$out" ]] || return 1
    printf '%s' "$out"
}

# Does this camera serve partial downloads? The answer decides whether settling
# the whole card costs ~600 MB or ~32 GB, so it is worth one request to find out
# and worth caching in the ledger afterwards.
#
# The hazard is a server that ignores Range and streams a 25 MB CR3 while we
# wait to discover that. Two guards, either of which is sufficient:
#
#   --max-filesize makes curl refuse before transferring a body whose advertised
#   length is too big, exiting 63. That costs headers only.
#
#   Requiring exactly 206 means a 200 (Range ignored, whole file coming) is
#   never mistaken for success even if it slips past the size guard.
#
# Sets GEO_RANGE_CCAPI and GEO_RANGE_TS. Never fails the caller: an unanswered
# question just means the expensive path, not a broken run.
ccapi_probe_range() {
    local loc="$1" code now hdr="$GEO_SNIFF_FILE.headers"
    printf -v now '%(%s)T' -1
    mkdir -p "${GEO_SNIFF_FILE%/*}" 2>/dev/null || return 0
    rm -f "$GEO_SNIFF_FILE" "$hdr"

    code=$(ccapi_curl "$CCAPI_SNIFF_TIMEOUT" \
              -H "Range: bytes=0-$(( GEO_SNIFF_BYTES - 1 ))" \
              --max-filesize $(( GEO_SNIFF_BYTES + 65536 )) \
              -o "$GEO_SNIFF_FILE" -D "$hdr" -w '%{http_code}' \
              "$(ccapi_url "$loc")" 2>/dev/null) || code=""

    GEO_RANGE_TS="$now"
    if [[ "$code" == 206 ]]; then
        GEO_RANGE_CCAPI=yes
        echo "  CCAPI serves partial downloads; a coordinate check costs $(( GEO_SNIFF_BYTES / 1024 )) KiB instead of a whole file."
    else
        GEO_RANGE_CCAPI=no
        echo "  CCAPI does not serve partial downloads (HTTP '${code:-no response}') — every check costs a whole file."
    fi
    GEO_LEDGER_DIRTY=1
    rm -f "$GEO_SNIFF_FILE" "$hdr"
    return 0
}

# Pull the first GEO_SNIFF_BYTES of a card file into GEO_SNIFF_FILE.
#
# This is not an approximation of the full GPS test — it is the full test.
# has_gps() reads exactly GEO_SNIFF_BYTES and cannot see past that offset, so it
# gives the same answer on this prefix as on the complete file, by construction.
# The two constants are commented at each other's definition for that reason.
#
# Prints the byte count fetched. Fails if the request failed or the response was
# not a 206, because a 200 here means the whole file is arriving and the caller's
# budget arithmetic would be wrong.
ccapi_sniff() {
    local loc="$1" code bytes hdr="$GEO_SNIFF_FILE.headers"
    mkdir -p "${GEO_SNIFF_FILE%/*}" 2>/dev/null || return 1
    rm -f "$GEO_SNIFF_FILE" "$hdr"

    code=$(ccapi_curl "$CCAPI_SNIFF_TIMEOUT" \
              -H "Range: bytes=0-$(( GEO_SNIFF_BYTES - 1 ))" \
              --max-filesize $(( GEO_SNIFF_BYTES + 65536 )) \
              -o "$GEO_SNIFF_FILE" -D "$hdr" -w '%{http_code}' \
              "$(ccapi_url "$loc")" 2>/dev/null) || return 1
    [[ "$code" == 206 ]] || return 1
    [[ -s "$GEO_SNIFF_FILE" ]] || return 1
    bytes=$(stat -c %s "$GEO_SNIFF_FILE" 2>/dev/null) || return 1
    printf '%s' "$bytes"
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

# Exact byte sizes for the whole card over USB, in one gphoto2 invocation.
#
# The listing that build_index_usb parses reports whole KB, and a GPS merge adds
# only ~100-200 bytes — so an unchanged KB figure is not evidence of anything and
# must never exclude a file. --show-info reports the real size, which can.
#
# Batched deliberately. Each gphoto2 run re-enumerates the camera at 1-2s, so
# per-file calls would take about an hour for this card — longer than simply
# downloading the small files. One call over an index range costs one enumeration.
#
# The output names the file it is describing, so a shifted or stale index cannot
# silently attribute one file's size to another:
#
#   Information on file 'IMG_7037.JPG' (folder '/store_00010001/DCIM/100CANON'):
#   File:
#     Size:          7717483 byte(s)
#
# Fills GEO_CARD_BYTES. Returns 1 if the call failed or produced nothing
# parseable, in which case the caller simply goes without exact sizes — correct,
# just more expensive.
declare -A GEO_CARD_BYTES=()
# Held in variables rather than written inline, the way LIST_RE is: a quote
# inside a [[ =~ ]] pattern is read by bash before the regex engine sees it.
SHOW_INFO_NAME_RE="^Information on file '(.+)' \\("
SHOW_INFO_SIZE_RE="^[[:space:]]*Size:[[:space:]]+([0-9]+)"
geo_show_info_usb() {
    local lo="$1" hi="$2" raw line name n=0
    GEO_CARD_BYTES=()
    (( GEO_SHOW_INFO_BATCH )) || return 1
    (( hi >= lo )) || return 1

    raw=$(gphoto2 --show-info "$lo-$hi" 2>/dev/null) || return 1
    name=""
    while IFS= read -r line; do
        if [[ "$line" =~ $SHOW_INFO_NAME_RE ]]; then
            name="${BASH_REMATCH[1]}"
            continue
        fi
        # Only the first Size: after a name line belongs to that file, so the
        # name is cleared as soon as it is consumed.
        if [[ -n "$name" && "$line" =~ $SHOW_INFO_SIZE_RE ]]; then
            GEO_CARD_BYTES["$name"]="${BASH_REMATCH[1]}"
            name=""
            n=$(( n + 1 ))
        fi
    done <<< "$raw"

    (( n > 0 )) || return 1
    echo "  Read exact sizes for $n of $(( hi - lo + 1 )) card file(s)."
    return 0
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

# Refresh mode needs somewhere to hold a download while it is compared against
# the copy it might replace, and somewhere to keep that copy afterwards. Both
# live inside DEST_BASE deliberately, matching the existing .deleted/ convention:
#
#   - dot-prefixed, so Immich's external-library crawler ignores them;
#   - inside DEST_BASE, so their basenames still land in LOCAL_SET and a normal
#     sync never re-downloads a file just because a copy of it sits in here;
#   - inside DEST_BASE, also because canon-camera-sync.service runs
#     ProtectSystem=strict with ReadWritePaths=<dest_base>, so anywhere else
#     would be denied outright under the udev trigger.
REFRESH_NAME=".refresh"
REFRESH_DIR="$DEST_BASE/$REFRESH_NAME"
QUARANTINE_DIR="$REFRESH_DIR/incoming"
# The geo review lives beside the refresh quarantine rather than inside it: the
# two never share a file, and keeping the ledger out of .refresh means clearing
# a stuck refresh cannot throw away everything the review has learned.
GEO_NAME=".geo"
GEO_DIR="$DEST_BASE/$GEO_NAME"
GEO_LEDGER="$GEO_DIR/ledger.tsv"
# A fixed name, never a camera basename. Sniffs are partial files, and a partial
# file carrying a real basename anywhere under DEST_BASE would land in LOCAL_SET
# and convince a later sync that a photo it never fetched is already here.
GEO_SNIFF_FILE="$GEO_DIR/sniff/current"
GEO_UNREACHABLE="$GEO_DIR/unreachable.txt"

# Timestamped so no two runs can ever overwrite each other's backups. Computed
# only when something might actually promote a file: every Wi-Fi poll reaches
# this line, and a run that replaces nothing has no use for the value.
#
# It must cover the geo review as well as refresh mode, because refresh_commit()
# is what both use to install a promoted file — and with BACKUP_DIR empty that
# function would resolve its backup path to "/2026/09/IMG_7037.JPG" and try to
# mkdir at the filesystem root. ProtectSystem=strict denies that under systemd;
# a manual root run would not.
BACKUP_DIR=""
if [[ -n "$REFRESH_MODE" || "$GEO_MODE" != off ]]; then
    BACKUP_DIR="$REFRESH_DIR/backup/$(date +%Y%m%d-%H%M%S)"
fi

# ─── Geotag ledger ─────────────────────────────────────────────────────────────
# What each file looked like — locally and on the card — the last time it was
# examined. The review is only affordable because of this. Without it, every
# camera-online event would have to re-read 3000 local images to find the ones
# without coordinates, then download each one to ask whether the card copy is
# any better. With it, a file whose local copy is unchanged and whose card-side
# size and timestamp are unchanged cannot have gained anything, and is skipped
# for nothing.
#
# TSV rather than JSON or sqlite. Bash reads it in one `read` loop with no
# subprocess, 6000 rows is ~700 KB, and it stays greppable by hand — which
# matters for a component whose job is to decide *not* to fetch things. sqlite
# would be a new dependency on a host that does not even have exiftool.
#
# Row layout, tab-separated, always 11 fields:
#
#   name  local_gps  local_bytes  local_mtime  local_rel
#         card_state  card_bytes  card_kb  card_mtime  checked_ts  attempts
#
# local_gps is the cached answer to "does the archived copy have coordinates?",
# valid only while local_bytes and local_mtime still match the file on disk.
# Anything that changes the file — including a promotion by this very review,
# which bumps the mtime for Immich — invalidates it automatically:
#
#   yes      coordinates present; nothing to do for this file, ever
#   no       GPS block reached, no usable latitude/longitude: a candidate
#   unknown  not yet read, or the file changed since it was
#
# card_state is the card-side half:
#
#   new        never examined on the card
#   settled    examined; the card copy has no coordinates either. Re-queued only
#              when the card-side metadata changes.
#   refused    the card copy has coordinates but is smaller than the local file,
#              so it is not the same image plus a GPS block. Same re-queue rule
#              as settled; never retried on its own.
#   offcard    in the archive but not on the card, so the camera can never
#              supply coordinates for it. Re-derived from the listing every run.
#   ambiguous  the basename exists at more than one local path, so there is no
#              safe answer to "which copy should be replaced"
#   error      a check failed; retried up to GEO_MAX_ATTEMPTS times
#
# No field can contain a tab: camera basenames cannot, and local_rel is a path
# under an NTFS volume, where tabs in filenames are impossible.
GEO_LEDGER_VERSION="#geo1"
GEO_ROW_FIELDS=10          # fields after the name
GEO_MAX_ATTEMPTS=3
# Never per file: the ledger is several hundred KB and DEST_BASE is a fuseblk
# mount on an SMR disk. A SIGKILL then costs at most this many seconds of
# progress, and losing progress only costs budget.
GEO_SAVE_INTERVAL=60

declare -A GEO_ROW=()
GEO_PREMISE=unknown
GEO_HITS=0
GEO_MISSES=0
GEO_RANGE_CCAPI=unknown
GEO_RANGE_TS=0
GEO_CURSOR=""
GEO_LAST_PASS_TS=0
GEO_LEDGER_DIRTY=0
GEO_LAST_SAVE=0

# Parse the header line into the scalars above. Split out from geo_ledger_load
# so geo_wants_run can read it on its own, without pulling thousands of rows
# into memory to answer a question the first line already settles.
geo_header_parse() {
    local line="$1" field
    [[ "${line%%$'\t'*}" == "$GEO_LEDGER_VERSION" ]] || return 1
    # A header written by a newer version may carry fields this one does not
    # know; ignoring them rather than failing means a downgrade degrades to
    # defaults instead of discarding the whole ledger.
    while IFS= read -r field; do
        case "$field" in
            premise=*)      GEO_PREMISE="${field#*=}" ;;
            hits=*)         GEO_HITS="${field#*=}" ;;
            misses=*)       GEO_MISSES="${field#*=}" ;;
            range_ccapi=*)  GEO_RANGE_CCAPI="${field#*=}" ;;
            range_ts=*)     GEO_RANGE_TS="${field#*=}" ;;
            cursor=*)       GEO_CURSOR="${field#*=}" ;;
            last_pass_ts=*) GEO_LAST_PASS_TS="${field#*=}" ;;
        esac
    done < <(printf '%s' "$line" | tr '\t' '\n')

    # Anything not a plain number degrades to zero rather than poisoning
    # arithmetic 300 lines away, matching metrics_load's rule for the same reason.
    [[ "$GEO_HITS"         =~ ^[0-9]+$ ]] || GEO_HITS=0
    [[ "$GEO_MISSES"       =~ ^[0-9]+$ ]] || GEO_MISSES=0
    [[ "$GEO_RANGE_TS"     =~ ^[0-9]+$ ]] || GEO_RANGE_TS=0
    [[ "$GEO_LAST_PASS_TS" =~ ^[0-9]+$ ]] || GEO_LAST_PASS_TS=0
    case "$GEO_PREMISE" in unknown|proven|disproven) ;; *) GEO_PREMISE=unknown ;; esac
    case "$GEO_RANGE_CCAPI" in yes|no|unknown) ;; *) GEO_RANGE_CCAPI=unknown ;; esac
    return 0
}

# Read just the header. Cheap enough to sit on the hot path of every poll.
geo_header_load() {
    local line
    [[ -r "$GEO_LEDGER" ]] || return 0
    IFS= read -r line < "$GEO_LEDGER" || return 0
    geo_header_parse "$line" || return 0
    return 0
}

# Load the whole ledger. Every failure mode here ends in an empty or partial
# ledger, never an error: rebuilding costs budget, and budget is recoverable in
# a way that photos are not.
geo_ledger_load() {
    local line n=0 name rest tabs
    GEO_ROW=()
    [[ -r "$GEO_LEDGER" ]] || return 0

    {
        IFS= read -r line || return 0
        if ! geo_header_parse "$line"; then
            # Either a file from a future format or a corrupted first line. Both
            # are handled by starting over — this is the version gate and the
            # corruption recovery in one.
            echo "NOTE: $GEO_NAME/ledger.tsv is not a $GEO_LEDGER_VERSION ledger — rebuilding it."
            GEO_ROW=()
            return 0
        fi
        while IFS= read -r line; do
            n=$(( n + 1 ))
            if (( n > GEO_LEDGER_MAX_ROWS )); then
                echo "NOTE: $GEO_NAME/ledger.tsv exceeds $GEO_LEDGER_MAX_ROWS rows — rebuilding it."
                GEO_ROW=()
                return 0
            fi
            name="${line%%$'\t'*}"
            rest="${line#*$'\t'}"
            [[ -n "$name" && "$rest" != "$line" ]] || continue
            # Exactly the expected field count, or the row is not trustworthy. A
            # partially corrupt file degrades one row at a time rather than
            # taking the whole ledger with it.
            tabs="${rest//[!$'\t']/}"
            (( ${#tabs} == GEO_ROW_FIELDS - 1 )) || continue
            GEO_ROW["$name"]="$rest"
        done
    } < "$GEO_LEDGER"
    return 0
}

# Unpack one row into globals. A single builtin split rather than per-field
# accessors: the review touches every field of a row it looks at, and forking
# `cut` ten times per file across thousands of files would cost more than the
# downloads this whole ledger exists to avoid.
#
# Returns 1 for a name the ledger has never seen, having set the fields to the
# defaults a new row carries, so callers can treat "absent" and "present"
# through one code path.
GR_LGPS=unknown; GR_LBYTES=0; GR_LMTIME=0; GR_REL=""
GR_CSTATE=new;   GR_CBYTES=0; GR_CKB=0; GR_CMTIME=0; GR_CHECKED=0; GR_ATTEMPTS=0
geo_row_read() {
    local row="${GEO_ROW[$1]:-}" rest
    if [[ -z "$row" ]]; then
        GR_LGPS=unknown; GR_LBYTES=0; GR_LMTIME=0; GR_REL=""
        GR_CSTATE=new;   GR_CBYTES=0; GR_CKB=0; GR_CMTIME=0; GR_CHECKED=0; GR_ATTEMPTS=0
        return 1
    fi
    # Split by hand rather than with `read -ra`. Tab is an IFS *whitespace*
    # character, so read collapses a run of them into one separator and drops
    # empty fields — a row whose local_rel has not been filled in yet would have
    # every field after it shifted left, quietly turning a card_state into a
    # byte count. Parameter expansion preserves empties exactly, and costs no
    # more than the read did.
    rest="$row"
    GR_LGPS="${rest%%$'\t'*}";    rest="${rest#*$'\t'}"
    GR_LBYTES="${rest%%$'\t'*}";  rest="${rest#*$'\t'}"
    GR_LMTIME="${rest%%$'\t'*}";  rest="${rest#*$'\t'}"
    GR_REL="${rest%%$'\t'*}";     rest="${rest#*$'\t'}"
    GR_CSTATE="${rest%%$'\t'*}";  rest="${rest#*$'\t'}"
    GR_CBYTES="${rest%%$'\t'*}";  rest="${rest#*$'\t'}"
    GR_CKB="${rest%%$'\t'*}";     rest="${rest#*$'\t'}"
    GR_CMTIME="${rest%%$'\t'*}";  rest="${rest#*$'\t'}"
    GR_CHECKED="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    GR_ATTEMPTS="$rest"
    # Defaults for anything a hand-edited or truncated row left blank, so the
    # arithmetic downstream cannot trip over an empty string under `set -u`.
    [[ -n "$GR_LGPS" ]]     || GR_LGPS=unknown
    [[ -n "$GR_CSTATE" ]]   || GR_CSTATE=new
    [[ "$GR_LBYTES"   =~ ^[0-9]+$ ]] || GR_LBYTES=0
    [[ "$GR_LMTIME"   =~ ^[0-9]+$ ]] || GR_LMTIME=0
    [[ "$GR_CBYTES"   =~ ^[0-9]+$ ]] || GR_CBYTES=0
    [[ "$GR_CKB"      =~ ^[0-9]+$ ]] || GR_CKB=0
    [[ "$GR_CMTIME"   =~ ^[0-9]+$ ]] || GR_CMTIME=0
    [[ "$GR_CHECKED"  =~ ^[0-9]+$ ]] || GR_CHECKED=0
    [[ "$GR_ATTEMPTS" =~ ^[0-9]+$ ]] || GR_ATTEMPTS=0
    return 0
}

# Write the row back from whatever geo_row_read left in the globals. Callers
# read, adjust the fields they mean to change, and write — so there is no
# partial-update path that could leave a row describing two observations at once.
geo_row_write() {
    GEO_ROW["$1"]=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "$GR_LGPS" "$GR_LBYTES" "$GR_LMTIME" "$GR_REL" \
        "$GR_CSTATE" "$GR_CBYTES" "$GR_CKB" "$GR_CMTIME" "$GR_CHECKED" "$GR_ATTEMPTS")
    GEO_LEDGER_DIRTY=1
}

# Publish the ledger. Same-directory rename, which is a single metadata
# operation on ntfs-3g, so a reader sees either the whole old file or the whole
# new one — the pattern metrics_emit already uses for the same reason.
geo_ledger_save() {
    local tmp now name row state over=0 dropped=0 ts
    (( GEO_LEDGER_DIRTY )) || return 0
    mkdir -p "$GEO_DIR" 2>/dev/null || return 0
    printf -v now '%(%s)T' -1

    # Trim to the cap by discarding rows that are pure bookkeeping before rows
    # that carry a decision: offcard is re-derived from the listing on every
    # run, so losing it costs nothing at all.
    over=$(( ${#GEO_ROW[@]} - GEO_LEDGER_MAX_ROWS ))
    if (( over > 0 )); then
        for state in offcard ambiguous settled refused; do
            (( over > 0 )) || break
            while IFS=$'\t' read -r ts name; do
                (( over > 0 )) || break
                unset 'GEO_ROW[$name]'
                over=$(( over - 1 ))
                dropped=$(( dropped + 1 ))
            done < <(for name in "${!GEO_ROW[@]}"; do
                         geo_row_read "$name" || true
                         [[ "$GR_CSTATE" == "$state" ]] || continue
                         printf '%s\t%s\n' "$GR_CHECKED" "$name"
                     done | sort -n)
        done
        (( dropped > 0 )) && echo "NOTE: ledger over $GEO_LEDGER_MAX_ROWS rows — dropped $dropped re-derivable row(s)."
    fi

    tmp="$GEO_DIR/.ledger.$$.tmp"
    {
        printf '%s\tpremise=%s\thits=%s\tmisses=%s\trange_ccapi=%s\trange_ts=%s\tcursor=%s\tlast_pass_ts=%s\tupdated=%s\n' \
            "$GEO_LEDGER_VERSION" "$GEO_PREMISE" "$GEO_HITS" "$GEO_MISSES" \
            "$GEO_RANGE_CCAPI" "$GEO_RANGE_TS" "$GEO_CURSOR" "$GEO_LAST_PASS_TS" "$now"
        # Sorted, so the file is diffable between runs and a save is
        # deterministic given the same state.
        for name in "${!GEO_ROW[@]}"; do
            printf '%s\t%s\n' "$name" "${GEO_ROW[$name]}"
        done | sort
    } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 0; }

    if mv -f "$tmp" "$GEO_LEDGER" 2>/dev/null; then
        GEO_LEDGER_DIRTY=0
        GEO_LAST_SAVE="$now"
    else
        rm -f "$tmp" 2>/dev/null || true
    fi
    return 0
}

# Throttled save for use inside the review loop, mirroring metrics_tick.
geo_ledger_tick() {
    local now
    printf -v now '%(%s)T' -1
    (( now - GEO_LAST_SAVE >= GEO_SAVE_INTERVAL )) && geo_ledger_save
    return 0
}

# Should the review run at all? Deliberately answerable from the header alone,
# because this sits on the path of every poll — including the ones that find
# nothing new, which is most of them.
#
# $1 is 1 when the sync found nothing new. A run that just downloaded photos
# skips the interval check: a camera that has given us new files is worth asking
# about the old ones, whatever the clock says.
geo_wants_run() {
    local nothing_new="${1:-1}" now
    [[ "$GEO_MODE" == off ]] && return 1
    [[ "$GEO_MODE" == force ]] && return 0

    geo_header_load
    # A written-off premise with no way back would be a dead feature, so the
    # re-arm rotation is what keeps it alive — but only if it has a budget.
    if [[ "$GEO_PREMISE" == disproven ]] && (( GEO_REARM_PROBE_FILES == 0 )); then
        return 1
    fi
    if (( nothing_new )); then
        printf -v now '%(%s)T' -1
        (( now - GEO_LAST_PASS_TS < GEO_MIN_INTERVAL )) && return 1
    fi
    return 0
}

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

    # A file being re-fetched for comparison must NOT land on its final path:
    # the whole point is to weigh it against the copy already there before
    # deciding to replace it, and moving it here would destroy that copy first.
    if (( QUARANTINE_ACTIVE )); then
        dst="$QUARANTINE_DIR/$expect"
        mv -f "$src" "$dst" || return 1
        return 0
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

    # When re-fetching for comparison the destination is already known — it is
    # the path of the local copy being considered for replacement — so the
    # capture-date lookup is both unnecessary and an extra way for the run to
    # fail. Divert to quarantine instead; the promote step decides where (and
    # whether) it lands.
    if (( QUARANTINE_ACTIVE )); then
        dst="$QUARANTINE_DIR/$expect"
        mv -f "$tmp" "$dst" || return 1
        return 0
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

# Decide whether a quarantined download is allowed to replace the local copy.
# This is the guard that makes a refresh incapable of losing data:
#
#   - the incoming file must carry coordinates the local copy does not, so a
#     card copy that is no better is discarded rather than written;
#   - the local copy is moved into a timestamped backup BEFORE anything
#     overwrites it, and put back if the install then fails;
#   - the only thing ever deleted is a rejected download, which is a temporary
#     copy of a file that is still on the card.
#
# Returns 0 whether or not it promoted. A card copy with nothing to add is an
# expected outcome, not a download failure, and must not count towards the
# retry/abort thresholds.
# What the most recent refresh_commit did, so a caller can act on the outcome
# without re-deriving it from counters that several code paths increment.
REFRESH_LAST_ACTION=""
REFRESH_LAST_COORDS=""
refresh_commit() {
    local name="$1"
    local inc="$QUARANTINE_DIR/$name"
    local rel="${LOCAL_PATH_FOR_NAME[$name]:-}"
    local coords backup in_bytes cur_bytes
    REFRESH_LAST_ACTION=""
    REFRESH_LAST_COORDS=""

    if [[ ! -f "$inc" ]]; then
        echo "WARNING: '$name' is not in quarantine — nothing to commit."
        REFRESH_LAST_ACTION=error
        return 0
    fi
    if [[ -z "$rel" ]]; then
        echo "WARNING: '$name' has no recorded local path — left in quarantine."
        REFRESH_LAST_ACTION=error
        return 0
    fi
    # Belt and braces for the mkdir-at-/ hazard described where BACKUP_DIR is
    # computed. Nothing may be overwritten without somewhere to put the original.
    if [[ -z "$BACKUP_DIR" ]]; then
        echo "ERROR: no backup directory for '$name' — refusing to replace anything."
        REFRESH_LAST_ACTION=error
        return 0
    fi

    if ! coords="$(has_gps "$inc")"; then
        echo "  $name: card copy has no coordinates either — discarded, local file untouched."
        rm -f "$inc"
        REFRESH_LAST_ACTION=no_gps
        REFRESH_SKIPPED_NO_GPS=$(( REFRESH_SKIPPED_NO_GPS + 1 ))
        # The automatic review keeps this tally in the ledger, where it survives
        # between events; the per-run counter here would reset on every one and
        # so could never reach a threshold.
        (( GEO_ACTIVE )) && return 0
        if (( REFRESH_GIVEUP > 0 && REFRESH_PROMOTED == 0 \
              && REFRESH_SKIPPED_NO_GPS >= REFRESH_GIVEUP )); then
            echo "ERROR: the first $REFRESH_SKIPPED_NO_GPS card copies all lack coordinates."
            echo "       The camera was not receiving location for this batch; stopping"
            echo "       rather than re-fetching the rest to prove the same thing."
            return 1
        fi
        return 0
    fi

    if [[ "$REFRESH_MODE" == probe ]]; then
        echo "  PROBE: the card copy of $name has $coords; the local copy has none."
        echo "  Kept at $inc — nothing was replaced."
        REFRESH_LAST_ACTION=probed
        REFRESH_PROMOTED=$(( REFRESH_PROMOTED + 1 ))
        return 0
    fi

    # Gaining a GPS IFD can only make a file bigger. A smaller card copy is not
    # the same image plus coordinates, so refuse rather than work out what it is.
    in_bytes=$(stat -c %s "$inc")
    cur_bytes=$(stat -c %s "$DEST_BASE/$rel")
    if (( in_bytes < cur_bytes )); then
        echo "WARNING: $name is $in_bytes bytes on the card against $cur_bytes here —"
        echo "         refusing to replace a larger local file with a smaller one."
        rm -f "$inc"
        REFRESH_LAST_ACTION=refused
        REFRESH_REFUSED=$(( REFRESH_REFUSED + 1 ))
        return 0
    fi

    # Back up first, as a hard link rather than a move. A move would leave a
    # window in which this basename exists ONLY under .refresh/backup/ — and
    # since backups deliberately count in LOCAL_SET, a crash inside that window
    # would leave a hole in the archive that a later sync considers already
    # filled and never re-fetches. A second directory entry for the same inode
    # costs nothing and means the live path never stops resolving.
    backup="$BACKUP_DIR/$rel"
    if ! mkdir -p "${backup%/*}"; then
        echo "ERROR: cannot create a backup directory for '$name' — local copy left alone."
        REFRESH_LAST_ACTION=error
        return 0
    fi
    if ! ln "$DEST_BASE/$rel" "$backup" 2>/dev/null \
       && ! cp -p "$DEST_BASE/$rel" "$backup"; then
        echo "ERROR: could not back up '$rel' — local copy left alone."
        REFRESH_LAST_ACTION=error
        return 0
    fi
    if ! mv -f "$inc" "$DEST_BASE/$rel"; then
        echo "ERROR: could not install '$name'; the original is untouched at $backup."
        REFRESH_LAST_ACTION=error
        return 0
    fi

    # gphoto2 preserves the camera's timestamp and mv is a rename, so over USB a
    # promoted file would arrive carrying the very mtime it replaced. Immich
    # decides whether to re-read EXIF with
    #   stat.mtime.valueOf() !== asset.fileModifiedAt.valueOf()
    # and external assets hash as sha1-path, so content changes are invisible to
    # it — an unchanged mtime means the new coordinates would never be indexed.
    # 188 of the 388 September files carry such whole-second camera mtimes.
    # Safe to bump: Immich orders on dateTimeOriginal, re-derived from EXIF.
    touch "$DEST_BASE/$rel"

    echo "  $name: $coords — replaced (original kept at $REFRESH_NAME/${backup#"$REFRESH_DIR"/})"
    REFRESH_LAST_ACTION=promoted
    REFRESH_LAST_COORDS="$coords"
    REFRESH_PROMOTED=$(( REFRESH_PROMOTED + 1 ))
    return 0
}

# ─── Geotag review ─────────────────────────────────────────────────────────────
# The automatic counterpart to refresh mode. It runs at the tail of an ordinary
# sync, so every event that already starts one — the udev rule when a cable goes
# in, canon-camera-watch.py when the camera announces itself over Wi-Fi, the
# safety-net timer — also asks whether the card has since gained coordinates for
# files the archive already holds.
#
# Three tiers, cheapest first, and nothing is ever ruled out on a weak signal:
#
#   0  the listing              free      which of our files are still on the card
#   1  the listing's whole-KB   free      USB only. A GPS merge adds ~100-200
#      sizes                              bytes, so an unchanged KB figure proves
#                                         nothing and must never exclude a file;
#                                         a changed one is definite evidence.
#   2  exact size and mtime     ~200 B    the real change detector. Unchanged
#      (?kind=info/--show-info)           card metadata cannot hide new
#                                         coordinates, so the file is skipped.
#   3  the GPS answer           256 KiB   only for files tier 2 could not settle.
#                               or a file
#
# Budgets are checked between files, never mid-transfer, and the ledger is the
# resume point: a file this run settles is not a candidate for the next one.

# Local size and mtime, gathered by the same find the sync already runs, as
# "bytes mtime". These are what validate the cached local-GPS verdict.
declare -A LOCAL_META=()

GEO_QUEUE=()        # tier 2+3: never examined, or known to have changed
GEO_ROTATION=()     # tier 2 only: already settled, re-probed to notice a change
GEO_STILLS=0
GEO_GEOTAGGED=0
GEO_CANDIDATES=0
GEO_SETTLED=0
GEO_OFFCARD=0
GEO_AMBIGUOUS=0
GEO_UNREADABLE=0
GEO_KB_CHANGED=0
GEO_OFFCARD_LIST=()

# Refresh the cached local verdict for every still whose file on disk is no
# longer the one that verdict was read from, in a single interpreter.
#
# Cold, that is every still in the archive. Warm it is only what this run just
# downloaded, plus anything the review itself promoted — a promotion bumps the
# mtime for Immich's benefit, which invalidates the very entry it made stale.
# That fall-out is deliberate: the file is re-read, found to have coordinates
# now, and drops out of the candidate set on its own.
# Read in chunks rather than one batch. Cold, this is every still in the
# archive — around 1.5 GB off a fuseblk mount on an SMR disk, which is minutes,
# and a single batch would mean a run killed at minute nine had learnt nothing.
# Saving between chunks makes the work resumable at the cost of one ledger write
# per chunk.
GEO_SCAN_CHUNK=400
geo_scan_local() {
    local code coords path name rel meta n=0 i
    local -a todo=() chunk=()

    for name in "${!LOCAL_PATH_FOR_NAME[@]}"; do
        [[ "${name,,}" == *.jpg || "${name,,}" == *.cr3 ]] || continue
        geo_row_read "$name" || true
        meta="${LOCAL_META[$name]:-0 0}"
        [[ "$GR_LGPS" != unknown && "$GR_LBYTES" == "${meta%% *}" \
           && "$GR_LMTIME" == "${meta##* }" ]] && continue
        # Files still on the card first, newest first within that. Those are the
        # only ones the review can act on, so a cold start reaches a state where
        # it can do useful work long before it has read the whole archive; the
        # rest only feed the coverage figures and can follow.
        if [[ -n "${LOC_FOR_NAME[$name]:-}" ]]; then
            todo+=("0\t${LOCAL_PATH_FOR_NAME[$name]}")
        else
            todo+=("1\t${LOCAL_PATH_FOR_NAME[$name]}")
        fi
    done

    (( ${#todo[@]} > 0 )) || return 0
    echo "  Reading coordinates from ${#todo[@]} local file(s)..."
    mapfile -t todo < <(printf '%b\n' "${todo[@]}" | sort -t$'\t' -k1,1 -k2,2r | cut -f2-)

    for (( i = 0; i < ${#todo[@]}; i += GEO_SCAN_CHUNK )); do
        chunk=("${todo[@]:i:GEO_SCAN_CHUNK}")
        while IFS=$'\t' read -r code path coords; do
            name="${path##*/}"
            rel="${LOCAL_PATH_FOR_NAME[$name]:-}"
            [[ -n "$rel" ]] || continue
            meta="${LOCAL_META[$name]:-0 0}"
            geo_row_read "$name" || true
            case "$code" in
                0) GR_LGPS=yes ;;
                1) GR_LGPS=no ;;
                # Unreadable or unrecognised. Left unknown rather than recorded
                # as "no", so a transient read error on the photo drive cannot
                # enrol a geotagged file as a candidate and get it overwritten.
                *) GR_LGPS=unknown ;;
            esac
            GR_LBYTES="${meta%% *}"
            GR_LMTIME="${meta##* }"
            GR_REL="$rel"
            geo_row_write "$name"
            n=$(( n + 1 ))
        done < <(printf '%s\0' "${chunk[@]/#/$DEST_BASE/}" | has_gps_batch)
        geo_ledger_tick
        metrics_tick
    done

    (( n < ${#todo[@]} )) && echo "  WARNING: $(( ${#todo[@]} - n )) local file(s) could not be read."
    return 0
}

# Work out where every local still stands and fill the two queues. Runs off
# LOCAL_PATH_FOR_NAME, LOCAL_META, LOC_FOR_NAME and KB_FOR_NAME, all of which
# the sync already produced, so it costs no extra traversal and no camera
# traffic. Single pass; geo_scan_local must have run first.
geo_classify() {
    local name rel kb_now changed
    GEO_QUEUE=(); GEO_ROTATION=(); GEO_OFFCARD_LIST=()
    GEO_STILLS=0; GEO_GEOTAGGED=0; GEO_CANDIDATES=0; GEO_SETTLED=0
    GEO_OFFCARD=0; GEO_AMBIGUOUS=0; GEO_UNREADABLE=0; GEO_KB_CHANGED=0

    for name in "${!LOCAL_PATH_FOR_NAME[@]}"; do
        # Only stills carry a GPS IFD. Without this an .MP4 could never satisfy
        # the test and would stay a candidate for ever, re-fetched and thrown
        # away on every single run.
        [[ "${name,,}" == *.jpg || "${name,,}" == *.cr3 ]] || continue
        GEO_STILLS=$(( GEO_STILLS + 1 ))
        rel="${LOCAL_PATH_FOR_NAME[$name]}"
        geo_row_read "$name" || true
        GR_REL="$rel"

        if [[ -n "${AMBIGUOUS_NAME[$name]+x}" ]]; then
            # One basename at two paths gives no safe answer to "which copy
            # should be replaced", so it is recorded and skipped rather than
            # guessed at.
            GR_CSTATE=ambiguous
            GEO_AMBIGUOUS=$(( GEO_AMBIGUOUS + 1 ))
            geo_row_write "$name"
            continue
        fi

        if [[ "$GR_LGPS" == yes ]]; then
            GEO_GEOTAGGED=$(( GEO_GEOTAGGED + 1 ))
            GR_CSTATE=geotagged
            geo_row_write "$name"
            continue
        fi
        if [[ "$GR_LGPS" != no ]]; then
            # Still unknown after the scan: the file could not be read or is not
            # a container this understands. Not a candidate — acting on a file
            # whose contents are unknown is how originals get lost.
            GEO_UNREADABLE=$(( GEO_UNREADABLE + 1 ))
            geo_row_write "$name"
            continue
        fi

        # From here on the local copy is known to lack coordinates.
        if [[ -z "${LOC_FOR_NAME[$name]:-}" ]]; then
            # The camera cannot help with a file it no longer holds. Recorded
            # rather than ignored: this is the part of the archive that will only
            # ever be fixed from a GPS track, and the list is the input for it.
            GR_CSTATE=offcard
            GEO_OFFCARD=$(( GEO_OFFCARD + 1 ))
            GEO_OFFCARD_LIST+=("$rel")
            geo_row_write "$name"
            continue
        fi

        # A row that said offcard or geotagged and no longer does means a card
        # was swapped back in, or the local file was replaced by one without
        # coordinates. Either way it has never actually been examined in its
        # current state, so it goes back to the start rather than staying
        # invisible for ever.
        [[ "$GR_CSTATE" == offcard || "$GR_CSTATE" == geotagged ]] && GR_CSTATE=new

        # Tier 1, free on USB: the listing's whole-KB size against the last one
        # recorded. Only ever used to promote a file into the queue — an equal
        # value is not evidence of anything, because the ~100-200 bytes a GPS
        # merge adds crosses a KB boundary only about one time in six.
        changed=0
        kb_now="${KB_FOR_NAME[$name]:-0}"
        if [[ "$ACTIVE_TRANSPORT" == usb ]] && (( kb_now > 0 )) && (( GR_CKB > 0 )) \
           && (( kb_now != GR_CKB )); then
            changed=1
            GEO_KB_CHANGED=$(( GEO_KB_CHANGED + 1 ))
        fi

        case "$GR_CSTATE" in
            settled|refused)
                if (( changed )); then
                    GEO_QUEUE+=("$name")
                    GEO_CANDIDATES=$(( GEO_CANDIDATES + 1 ))
                else
                    GEO_SETTLED=$(( GEO_SETTLED + 1 ))
                    GEO_ROTATION+=("$name")
                fi
                ;;
            error)
                if (( GR_ATTEMPTS < GEO_MAX_ATTEMPTS )); then
                    GEO_QUEUE+=("$name")
                    GEO_CANDIDATES=$(( GEO_CANDIDATES + 1 ))
                else
                    # Out of retries. Counted as settled so it stops consuming
                    # budget, but the card metadata check in the rotation can
                    # still bring it back if the file actually changes.
                    GEO_SETTLED=$(( GEO_SETTLED + 1 ))
                    GEO_ROTATION+=("$name")
                fi
                ;;
            *)
                GEO_QUEUE+=("$name")
                GEO_CANDIDATES=$(( GEO_CANDIDATES + 1 ))
                ;;
        esac
        geo_row_write "$name"
    done

    # Free re-arm: if the card's whole-KB sizes have moved for several files at
    # once then something rewrote them, which is exactly the evidence a written-
    # off premise was waiting for.
    if (( GEO_KB_CHANGED >= GEO_REARM_KB_THRESHOLD )) && [[ "$GEO_PREMISE" == disproven ]]; then
        echo "  $GEO_KB_CHANGED card file(s) changed size since the last look — reopening the premise."
        GEO_PREMISE=unknown
        GEO_MISSES=0
        GEO_LEDGER_DIRTY=1
    fi

    # Newest first. Deliberately by path and not by basename: Canon's counter
    # wraps at 9999 and the prefix flips between IMG_ and _MG_, so basename
    # order is not chronological, while the YYYY/MM path is.
    if (( ${#GEO_QUEUE[@]} > 1 )); then
        mapfile -t GEO_QUEUE < <(
            for name in "${GEO_QUEUE[@]}"; do
                printf '%s\t%s\n' "${LOCAL_PATH_FOR_NAME[$name]}" "$name"
            done | sort -r | cut -f2-
        )
    fi
    return 0
}

# Tier 2: exact card-side size and mtime for one file. Sets GEO_INFO_BYTES and
# GEO_INFO_MTIME, either 0 when the transport cannot supply it. Returns 1 when
# the question could not be asked at all, which is different from being answered
# with zeroes.
GEO_INFO_BYTES=0
GEO_INFO_MTIME=0
geo_card_info() {
    local name="$1" loc="${LOC_FOR_NAME[$1]:-}" out
    GEO_INFO_BYTES=0
    GEO_INFO_MTIME=0
    [[ -n "$loc" ]] || return 1
    case "$ACTIVE_TRANSPORT" in
        usb)
            # Filled in one batched --show-info at the start of the phase; a
            # miss just means this file was outside the range, or the batch
            # could not be parsed on this firmware.
            GEO_INFO_BYTES="${GEO_CARD_BYTES[$name]:-0}"
            (( GEO_INFO_BYTES > 0 )) || return 1
            ;;
        ccapi)
            out=$(ccapi_file_info "$loc") || return 1
            GEO_INFO_BYTES="${out%%$'\t'*}"
            GEO_INFO_MTIME="${out##*$'\t'}"
            [[ "$GEO_INFO_BYTES" =~ ^[0-9]+$ ]] || GEO_INFO_BYTES=0
            [[ "$GEO_INFO_MTIME" =~ ^[0-9]+$ ]] || GEO_INFO_MTIME=0
            (( GEO_INFO_BYTES > 0 || GEO_INFO_MTIME > 0 )) || return 1
            ;;
        *) return 1 ;;
    esac
    return 0
}

# Tier 3: does the card copy carry coordinates the local copy lacks?
#
# Over CCAPI with Range this reads GEO_SNIFF_BYTES, which is not an
# approximation: has_gps cannot see past that offset, so the prefix gives the
# same verdict as the whole file. Everywhere else it costs a full download into
# quarantine.
#
# The coordinates land in GEO_CARD_COORDS rather than on stdout. That is not a
# style choice: a caller writing `coords=$(geo_card_gps ...)` would run all of
# this in a subshell, and GEO_SNIFF_USED and the byte tally would be discarded
# with it — leaving the promote step convinced it already had the whole file.
#
# Returns 0 coordinates found, 1 none, 2 the check could not be completed.
GEO_SNIFF_USED=0
GEO_CARD_COORDS=""
geo_card_gps() {
    local name="$1" loc="${LOC_FOR_NAME[$1]:-}" bytes rc
    GEO_SNIFF_USED=0
    GEO_CARD_COORDS=""
    [[ -n "$loc" ]] || return 2

    if [[ "$ACTIVE_TRANSPORT" == ccapi && "$GEO_RANGE_CCAPI" == yes ]]; then
        bytes=$(ccapi_sniff "$loc") || return 2
        G_BYTES=$(( G_BYTES + bytes ))
        GEO_SNIFF_USED=1
        GEO_CARD_COORDS=$(has_gps "$GEO_SNIFF_FILE") && rc=0 || rc=$?
        rm -f "$GEO_SNIFF_FILE" "$GEO_SNIFF_FILE.headers"
        case "$rc" in
            0) return 0 ;;
            1) return 1 ;;
            *) return 2 ;;
        esac
    fi

    # No partial download available, so the whole file has to come over. It
    # lands in quarantine, where refresh_commit can weigh it against the copy it
    # might replace — a sniff never can, which is why the two paths are separate.
    fetch_file "$loc" "$name" "${KB_FOR_NAME[$name]:-0}" || return 2
    [[ -f "$QUARANTINE_DIR/$name" ]] || return 2
    bytes=$(stat -c %s "$QUARANTINE_DIR/$name" 2>/dev/null) || bytes=0
    G_BYTES=$(( G_BYTES + bytes ))
    GEO_CARD_COORDS=$(has_gps "$QUARANTINE_DIR/$name") && rc=0 || rc=$?
    case "$rc" in
        0) return 0 ;;
        1) rm -f "$QUARANTINE_DIR/$name"; return 1 ;;
        *) rm -f "$QUARANTINE_DIR/$name"; return 2 ;;
    esac
}

# Install a card copy that has coordinates over the local copy that has none.
#
# A sniff is never installed: it is a 256 KiB prefix, and the file that replaces
# a photo must be the whole photo. When the answer came from a sniff the file is
# fetched again in full, and refresh_commit — unchanged, with its hard-linked
# backup, its refusal to shrink a file and its own independent GPS re-check —
# does the installing.
geo_promote() {
    local name="$1" loc="${LOC_FOR_NAME[$1]:-}"
    [[ -n "$loc" ]] || return 1
    if (( GEO_SNIFF_USED )); then
        fetch_file "$loc" "$name" "${KB_FOR_NAME[$name]:-0}" || return 1
    fi
    refresh_commit "$name" || true
    [[ "$REFRESH_LAST_ACTION" == promoted ]] || return 1
    return 0
}

# One candidate, all tiers. Returns 0 when the file was resolved one way or
# another, 1 when it could not be checked.
geo_check_one() {
    local name="$1" rc unchanged=0

    geo_row_read "$name" || true

    # Tier 2 first. Its whole value is the files it lets us skip: card metadata
    # identical to what was recorded last time cannot be hiding new coordinates.
    if geo_card_info "$name"; then
        if [[ "$GR_CSTATE" == settled ]] \
           && (( GR_CBYTES > 0 && GEO_INFO_BYTES == GR_CBYTES )) \
           && (( GR_CMTIME == GEO_INFO_MTIME )); then
            unchanged=1
        fi
        (( GR_CBYTES > 0 && GEO_INFO_BYTES != GR_CBYTES )) && G_CHANGED=$(( G_CHANGED + 1 ))
        (( GR_CMTIME > 0 && GEO_INFO_MTIME != GR_CMTIME )) && G_CHANGED=$(( G_CHANGED + 1 ))
        GR_CBYTES="$GEO_INFO_BYTES"
        GR_CMTIME="$GEO_INFO_MTIME"
    fi
    GR_CKB="${KB_FOR_NAME[$name]:-0}"

    if (( unchanged )); then
        printf -v GR_CHECKED '%(%s)T' -1
        geo_row_write "$name"
        return 0
    fi

    geo_card_gps "$name" && rc=0 || rc=$?
    G_CHECKED=$(( G_CHECKED + 1 ))
    printf -v GR_CHECKED '%(%s)T' -1

    case "$rc" in
        0)
            # The premise is now established for good: this camera does put
            # coordinates onto a card file after the archive copy was taken.
            GEO_HITS=$(( GEO_HITS + 1 ))
            GEO_PREMISE=proven
            GEO_LEDGER_DIRTY=1
            if geo_promote "$name"; then
                G_PROMOTED=$(( G_PROMOTED + 1 ))
                # The promoted file now has coordinates and a fresh mtime, so
                # the cached verdict is stale by construction. Clearing it, and
                # re-stating the file it now is, makes the closing scan re-read
                # it and confirm the coordinates are really there — the archive
                # is the authority, not this run's bookkeeping.
                GR_LGPS=unknown
                LOCAL_META["$name"]="$(stat -c '%s %Y' "$DEST_BASE/$GR_REL" 2>/dev/null || echo '0 0')"
                GR_CSTATE=geotagged
                GR_ATTEMPTS=0
            elif [[ "$REFRESH_LAST_ACTION" == refused ]]; then
                # The card copy is smaller than the local one, so it is not the
                # same image plus coordinates. That is a property of the two
                # files, not a transient failure: retrying re-downloads the file
                # to reach the same conclusion. Terminal until the card copy
                # changes, which the rotation still watches for.
                GR_CSTATE=refused
                GR_ATTEMPTS=0
            else
                # Something went wrong installing it — a backup that could not
                # be made, a move that failed. refresh_commit logged why and
                # left the local file untouched. Worth retrying.
                GR_CSTATE=error
                GR_ATTEMPTS=$(( GR_ATTEMPTS + 1 ))
            fi
            ;;
        1)
            GEO_MISSES=$(( GEO_MISSES + 1 ))
            GEO_LEDGER_DIRTY=1
            GR_CSTATE=settled
            GR_ATTEMPTS=0
            ;;
        *)
            G_ERRORS=$(( G_ERRORS + 1 ))
            GR_CSTATE=error
            GR_ATTEMPTS=$(( GR_ATTEMPTS + 1 ))
            geo_row_write "$name"
            return 1
            ;;
    esac
    geo_row_write "$name"
    return 0
}

# The metadata-only rotation. Its job is to notice that a file the ledger wrote
# off has since been rewritten on the card — the one thing that can bring a
# disproven premise back. Walks the settled set a slice at a time from a cursor
# in the ledger, so successive events cover it all without any one event paying
# for the whole sweep.
geo_rotate() {
    local budget="$1" name start=0 i n checked=0
    n=${#GEO_ROTATION[@]}
    (( n > 0 && budget > 0 )) || return 0

    # Resume after the last name examined. A cursor that is no longer in the set
    # simply starts the sweep again rather than stalling it.
    if [[ -n "$GEO_CURSOR" ]]; then
        for (( i = 0; i < n; i++ )); do
            if [[ "${GEO_ROTATION[$i]}" == "$GEO_CURSOR" ]]; then
                start=$(( i + 1 ))
                break
            fi
        done
    fi

    for (( i = 0; i < n && checked < budget; i++ )); do
        name="${GEO_ROTATION[$(( (start + i) % n ))]}"
        geo_row_read "$name" || continue
        if geo_card_info "$name"; then
            if (( GR_CBYTES > 0 && GEO_INFO_BYTES > 0 && GEO_INFO_BYTES != GR_CBYTES )) \
               || (( GR_CMTIME > 0 && GEO_INFO_MTIME > 0 && GEO_INFO_MTIME != GR_CMTIME )); then
                echo "  $name changed on the card since it was last checked — requeued."
                G_CHANGED=$(( G_CHANGED + 1 ))
                GR_CSTATE=new
                GR_CBYTES="$GEO_INFO_BYTES"
                GR_CMTIME="$GEO_INFO_MTIME"
                GR_ATTEMPTS=0
                geo_row_write "$name"
                # Straight to the front of this event's queue, not the next
                # one's. Noticing that a card file changed and then waiting for
                # another event to look at it would make the whole mechanism a
                # power-cycle slower than it needs to be.
                GEO_QUEUE=("$name" "${GEO_QUEUE[@]}")
                # Evidence that something rewrites card files. Reopen the
                # premise so the expensive tier gets to look at this next event.
                if [[ "$GEO_PREMISE" == disproven ]]; then
                    GEO_PREMISE=unknown
                    GEO_MISSES=0
                    GEO_LEDGER_DIRTY=1
                fi
            fi
        fi
        checked=$(( checked + 1 ))
        GEO_CURSOR="$name"
        GEO_LEDGER_DIRTY=1
    done
    (( checked > 0 )) && echo "  Re-probed $checked settled file(s) for card-side changes."
    return 0
}

# How many expensive checks this event may spend, given what is and is not yet
# known about whether the card can help at all.
geo_tier3_budget() {
    local base
    case "$ACTIVE_TRANSPORT" in
        usb)   base="$GEO_BUDGET_FILES_USB" ;;
        ccapi) if [[ "$GEO_RANGE_CCAPI" == yes ]]; then
                   base="$GEO_BUDGET_FILES_CCAPI"
               else
                   # Every check is a whole file now, so the budget has to drop
                   # by two orders of magnitude to cost the same.
                   base="$GEO_BUDGET_FILES_CCAPI_FULL"
               fi ;;
        *)     base=0 ;;
    esac
    case "$GEO_PREMISE" in
        # Nothing has ever been seen to gain coordinates. Spend a handful of
        # checks to find out, not a full budget: on this archive 93% of stills
        # have an empty GPS block, so a miss is the base rate and proves nothing.
        unknown)   (( base > GEO_PROBE_FILES )) && base="$GEO_PROBE_FILES" ;;
        # Established that it does not happen. The rotation still runs, but
        # nothing expensive does until that rotation finds evidence.
        disproven) base=0 ;;
    esac
    printf '%s' "$base"
}

geo_report() {
    echo "Geotag review: $GEO_STILLS still(s) in the archive."
    echo "  $GEO_GEOTAGGED already have coordinates."
    echo "  $GEO_CANDIDATES candidate(s) without coordinates, still on the card."
    echo "  $GEO_SETTLED settled — checked, the card copy has none either."
    echo "  $GEO_OFFCARD without coordinates and no longer on the card; the camera cannot help with these."
    (( GEO_AMBIGUOUS > 0 ))  && echo "  $GEO_AMBIGUOUS skipped — same filename at more than one path."
    (( GEO_UNREADABLE > 0 )) && echo "  $GEO_UNREADABLE skipped — could not be read."
    echo "  premise: $GEO_PREMISE (${GEO_HITS} hit(s), ${GEO_MISSES} miss(es))"
    [[ "$ACTIVE_TRANSPORT" == ccapi ]] && echo "  partial downloads: $GEO_RANGE_CCAPI"
    return 0
}

# The files the camera can never fix. Written out as a work queue rather than
# left as a number: these can only be geotagged from a recorded track, and this
# is the input list for doing that.
geo_write_offcard() {
    local tmp="$GEO_DIR/.unreachable.$$.tmp"
    mkdir -p "$GEO_DIR" 2>/dev/null || return 0
    if (( ${#GEO_OFFCARD_LIST[@]} == 0 )); then
        rm -f "$GEO_UNREACHABLE" 2>/dev/null || true
        return 0
    fi
    printf '%s\n' "${GEO_OFFCARD_LIST[@]}" | sort > "$tmp" 2>/dev/null \
        || { rm -f "$tmp" 2>/dev/null || true; return 0; }
    mv -f "$tmp" "$GEO_UNREACHABLE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    return 0
}

# Publish the archive-wide figures through MSTATE, which is what metrics_emit
# reads. Going through MSTATE rather than straight to the emitter is what lets a
# later poll that never opens the ledger republish these instead of zeroing them.
geo_publish() {
    local now
    printf -v now '%(%s)T' -1
    MSTATE[geo_enabled]=1
    MSTATE[geo_premise]="$GEO_PREMISE"
    MSTATE[geo_range_ccapi]="$GEO_RANGE_CCAPI"
    MSTATE[geo_stills]="$GEO_STILLS"
    MSTATE[geo_geotagged]="$GEO_GEOTAGGED"
    MSTATE[geo_candidates]="$GEO_CANDIDATES"
    MSTATE[geo_settled]="$GEO_SETTLED"
    MSTATE[geo_unreachable]="$GEO_OFFCARD"
    MSTATE[geo_ambiguous]="$GEO_AMBIGUOUS"
    MSTATE[geo_ledger_rows]="${#GEO_ROW[@]}"
    MSTATE[geo_last_pass_timestamp_seconds]="$GEO_LAST_PASS_TS"
    (( G_PROMOTED > 0 )) && MSTATE[geo_last_promote_timestamp_seconds]="$now"
    return 0
}

# The review itself.
#
# Called as `geo_phase || true`, after the state file has been written and after
# M_SYNC_OK is set, so a sync that collected photos successfully stays a success
# whatever happens in here. Every failure path returns 0 for the same reason:
# this phase exists to improve files that are already safely in the archive, and
# nothing it can fail at is worth reporting a failed sync over.
#
# $1 is 1 when the sync found nothing new.
geo_phase() {
    local nothing_new="${1:-1}" budget deadline now name rc probe_loc lo hi
    [[ "$GEO_MODE" == off ]] && return 0
    [[ -n "$REFRESH_MODE" ]] && return 0
    [[ -n "$ACTIVE_TRANSPORT" ]] || return 0

    GEO_ACTIVE=1
    G_RAN=1
    mkdir -p "$GEO_DIR" || { echo "NOTE: cannot create $GEO_NAME/ — skipping the geotag review."; GEO_ACTIVE=0; return 0; }
    # A write target orphaned by a run that was killed mid-save. Only ever ours:
    # the name carries a pid and the flock guarantees no sibling run.
    rm -f "$GEO_DIR"/.ledger.*.tmp 2>/dev/null || true

    geo_ledger_load

    if (( GEO_REARM_REQUESTED )); then
        echo "Re-arming the geotag review: every settled file becomes a candidate again."
        GEO_PREMISE=unknown
        GEO_HITS=0
        GEO_MISSES=0
        GEO_RANGE_CCAPI=unknown
        for name in "${!GEO_ROW[@]}"; do
            geo_row_read "$name" || continue
            [[ "$GR_CSTATE" == settled || "$GR_CSTATE" == error \
               || "$GR_CSTATE" == refused ]] || continue
            GR_CSTATE=new
            GR_ATTEMPTS=0
            geo_row_write "$name"
        done
    fi

    geo_scan_local
    geo_classify
    geo_report
    geo_write_offcard

    if (( GEO_STATUS_ONLY )); then
        geo_ledger_save
        geo_publish
        GEO_ACTIVE=0
        return 0
    fi

    # Exact card-side sizes for the USB path, in one call. Per-file invocation
    # would re-enumerate the camera every time and take longer than downloading
    # the small files outright.
    if [[ "$ACTIVE_TRANSPORT" == usb ]] && (( ${#GEO_QUEUE[@]} + ${#GEO_ROTATION[@]} > 0 )); then
        lo=1
        hi="$CAMERA_COUNT"
        geo_show_info_usb "$lo" "$hi" || true
    fi

    # Cheap enough to run on every event, and placed before the expensive tier
    # deliberately: it is the detector on the Wi-Fi path, and anything it finds
    # should be acted on now rather than next time. It is also the only thing
    # that can bring a written-off premise back, which has to happen before the
    # budget below is worked out from that premise.
    geo_rotate "$GEO_REARM_PROBE_FILES"

    # Whether this camera serves partial downloads decides whether settling the
    # whole card costs a few hundred megabytes or tens of gigabytes, so it is
    # worth one request — and worth remembering the answer.
    if [[ "$ACTIVE_TRANSPORT" == ccapi ]] && (( ${#GEO_QUEUE[@]} > 0 )); then
        printf -v now '%(%s)T' -1
        if [[ "$GEO_RANGE_CCAPI" == unknown ]] \
           || { [[ "$GEO_RANGE_CCAPI" == no ]] \
                && (( now - GEO_RANGE_TS > GEO_RANGE_RECHECK_DAYS * 86400 )); }; then
            probe_loc="${LOC_FOR_NAME[${GEO_QUEUE[0]}]:-}"
            [[ -n "$probe_loc" ]] && ccapi_probe_range "$probe_loc"
        fi
    fi

    budget=$(geo_tier3_budget)
    if (( GEO_PLAN_ONLY )); then
        echo "PLAN: would examine up to $budget of ${#GEO_QUEUE[@]} candidate(s),"
        echo "      and re-probe up to $GEO_REARM_PROBE_FILES of ${#GEO_ROTATION[@]} settled file(s)."
        (( ${#GEO_QUEUE[@]} > 0 )) && printf '  %s\n' "${GEO_QUEUE[@]:0:$(( budget > 0 ? budget : 0 ))}"
        geo_ledger_save
        geo_publish
        GEO_ACTIVE=0
        return 0
    fi

    case "$ACTIVE_TRANSPORT" in
        usb)   deadline="$GEO_BUDGET_SECONDS_USB" ;;
        *)     deadline="$GEO_BUDGET_SECONDS_CCAPI" ;;
    esac
    printf -v now '%(%s)T' -1
    deadline=$(( now + deadline ))

    QUARANTINE_ACTIVE=1
    mkdir -p "$QUARANTINE_DIR" 2>/dev/null || true

    local consecutive=0 done_n=0
    if (( budget > 0 && ${#GEO_QUEUE[@]} > 0 )); then
        echo "Checking $(( budget < ${#GEO_QUEUE[@]} ? budget : ${#GEO_QUEUE[@]} )) of ${#GEO_QUEUE[@]} candidate(s) against the card..."
        for name in "${GEO_QUEUE[@]}"; do
            (( done_n >= budget )) && { G_BUDGET_EXHAUSTED=1; break; }
            printf -v now '%(%s)T' -1
            (( now >= deadline )) && { G_BUDGET_EXHAUSTED=1; break; }

            metrics_tick
            geo_ledger_tick

            if geo_check_one "$name"; then
                consecutive=0
            else
                consecutive=$(( consecutive + 1 ))
                # A camera that has gone away fails every remaining file. Without
                # this the budget would be spent proving that over and over, and
                # every row it touched would collect a retry it did not earn.
                if (( consecutive >= MAX_CONSECUTIVE_FAILS )); then
                    if ! camera_present; then
                        echo "  Camera no longer reachable — stopping the review here."
                        geo_row_read "$name" || true
                        GR_ATTEMPTS=0
                        GR_CSTATE=new
                        geo_row_write "$name"
                        # Not a completed pass. Marking it as one would stamp
                        # last_pass_ts and put the review to sleep for an hour
                        # over a transport problem that may already be over.
                        G_BUDGET_EXHAUSTED=1
                        break
                    fi
                    consecutive=0
                fi
            fi
            done_n=$(( done_n + 1 ))

            # The premise ladder's stopping condition. Enough misses in a row
            # with nothing ever found means this camera does not put coordinates
            # onto files after the fact, and the remaining candidates would only
            # prove it again — expensively.
            if (( GEO_GIVEUP > 0 && GEO_HITS == 0 && GEO_MISSES >= GEO_GIVEUP )) \
               && [[ "$GEO_PREMISE" != disproven ]]; then
                GEO_PREMISE=disproven
                GEO_LEDGER_DIRTY=1
                echo "  $GEO_MISSES card copies checked, none had coordinates the archive lacked."
                echo "  Writing the premise off: further events will only re-probe metadata,"
                echo "  which is nearly free, and will reopen this the moment a card file changes."
                break
            fi
        done
        (( done_n >= ${#GEO_QUEUE[@]} )) && G_BUDGET_EXHAUSTED=0
    elif (( budget == 0 )) && (( ${#GEO_QUEUE[@]} > 0 )); then
        echo "  ${#GEO_QUEUE[@]} candidate(s) left alone: the premise is $GEO_PREMISE."
    fi

    QUARANTINE_ACTIVE=0
    rm -rf "${QUARANTINE_DIR:?}" 2>/dev/null || true

    # A pass that got through everything it meant to is what starts the quiet
    # interval. A pass cut short by a budget deliberately does not, so the next
    # event picks up where this one stopped instead of waiting an hour.
    if (( ! G_BUDGET_EXHAUSTED )); then
        printf -v GEO_LAST_PASS_TS '%(%s)T' -1
        GEO_LEDGER_DIRTY=1
    fi

    # Re-read anything this run changed — which after a promotion is only the
    # promoted files — and recount. That does two jobs at once: the published
    # figures describe the archive as it now stands rather than as it did on
    # entry, and every promotion is independently confirmed by reading the file
    # that actually ended up on disk.
    geo_scan_local
    geo_classify
    geo_ledger_save
    geo_publish

    echo "Geotag review done: $G_CHECKED checked, $G_CHANGED changed on the card, $G_PROMOTED promoted, $G_ERRORS error(s)."
    (( G_BUDGET_EXHAUSTED )) && echo "  Stopped on this event's budget; the next one resumes from here."
    GEO_ACTIVE=0
    return 0
}

# ─── Offline test seam ─────────────────────────────────────────────────────────
# CAMERA_SYNC_GEO_FAKE_CARD=<dir> stands a directory of real image files in for
# the camera. Everything above this point stays exactly as it ships; only the
# handful of functions that actually talk to a camera are swapped, and only when
# the variable is set. That makes the whole review — classification, tier
# decisions, ordering, budgets, promotion through refresh_commit with its real
# backups and its real GPS re-check, ledger writes, metrics — testable on a
# machine with no camera attached, which is the normal state of affairs.
#
# The substitutes are deliberately thin. They do the same *kind* of thing the
# real ones do (stat for metadata, a truncated read for a sniff, a copy for a
# fetch) so a test exercises the calling logic rather than a mock of it.
if [[ -n "${CAMERA_SYNC_GEO_FAKE_CARD:-}" ]]; then
    FAKE_CARD="$CAMERA_SYNC_GEO_FAKE_CARD"
    echo "TEST SEAM: using $FAKE_CARD as the camera."

    resolve_transport() {
        ACTIVE_TRANSPORT="${CAMERA_SYNC_GEO_FAKE_TRANSPORT:-ccapi}"
        CAMERA_IP="127.0.0.1"
        M_CAMERA_REACHABLE=1
        return 0
    }
    camera_present() { return 0; }

    build_index() {
        local f name bytes
        LOC_FOR_NAME=(); KB_FOR_NAME=(); CAMERA_NAMES=()
        CAMERA_COUNT=0; LAST_CAMERA_FILE=""
        for f in "$FAKE_CARD"/*; do
            [[ -f "$f" ]] || continue
            name="${f##*/}"
            bytes=$(stat -c %s "$f")
            CAMERA_COUNT=$(( CAMERA_COUNT + 1 ))
            LAST_CAMERA_FILE="$name"
            LOC_FOR_NAME["$name"]="$f"
            # Whole KB, the same lossy figure gphoto2's listing reports.
            KB_FOR_NAME["$name"]=$(( bytes / 1024 ))
            CAMERA_NAMES+=("$name")
        done
        (( CAMERA_COUNT > 0 ))
    }

    ccapi_file_info() {
        local f="$1"
        [[ -f "$f" ]] || return 1
        printf '%s\t%s' "$(stat -c %s "$f")" "$(stat -c %Y "$f")"
    }

    ccapi_probe_range() {
        GEO_RANGE_CCAPI="${CAMERA_SYNC_GEO_FAKE_RANGE:-yes}"
        printf -v GEO_RANGE_TS '%(%s)T' -1
        GEO_LEDGER_DIRTY=1
        echo "  TEST SEAM: partial downloads = $GEO_RANGE_CCAPI"
        return 0
    }

    ccapi_sniff() {
        local f="$1"
        [[ -f "$f" ]] || return 1
        mkdir -p "${GEO_SNIFF_FILE%/*}" || return 1
        head -c "$GEO_SNIFF_BYTES" "$f" > "$GEO_SNIFF_FILE" || return 1
        stat -c %s "$GEO_SNIFF_FILE"
    }

    geo_show_info_usb() {
        local f name
        GEO_CARD_BYTES=()
        (( GEO_SHOW_INFO_BATCH )) || return 1
        for f in "$FAKE_CARD"/*; do
            [[ -f "$f" ]] || continue
            name="${f##*/}"
            GEO_CARD_BYTES["$name"]=$(stat -c %s "$f")
        done
        (( ${#GEO_CARD_BYTES[@]} > 0 ))
    }

    fetch_file() {
        local loc="$1" expect="$2"
        [[ -f "$loc" ]] || return 1
        if (( QUARANTINE_ACTIVE )); then
            mkdir -p "$QUARANTINE_DIR" || return 1
            cp -p "$loc" "$QUARANTINE_DIR/$expect" || return 1
            return 0
        fi
        local ym dst
        ym=$(exif_year_month "$loc") || return 1
        dst="$DEST_BASE/${ym%%-*}/${ym##*-}/$expect"
        ensure_dest_dir "${dst%/*}" || return 1
        cp -p "$loc" "$dst" || return 1
        return 0
    }
fi

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

# Quick exit: nothing changed on camera. Refresh mode must skip this — it exists
# precisely to re-fetch files that were already synced, so "nothing new on the
# card" is its normal starting condition, not a reason to stop.
#
# This is also where the geotag review has to be let through. "No new photos" is
# the normal outcome of a camera-online event — most events, in fact — so a
# review that only ran after a download would almost never run at all. The test
# it is gated on reads the ledger's first line and nothing else: no directory
# walk, no camera traffic. A poll with nothing to review still costs what it
# always did.
#
# The condition asks only whether the CARD changed, which is the wrong question
# after the archive loses files: delete a month locally and the card still has
# the same count and the same last filename, so the run exits believing there is
# nothing to do and those photos are never fetched again.
#
# Making that safe automatically would mean walking the archive on every poll —
# exactly the cost this exit exists to avoid, on a drive that may be spun down.
# So it stays an explicit request instead. CAMERA_SYNC_RESCAN=1 skips the exit
# and recomputes the missing set from what is actually on disk, which is the
# thing to run after deleting or restoring anything by hand.
RESCAN="${CAMERA_SYNC_RESCAN:-0}"
NOTHING_NEW=0
if [[ "$RESCAN" == 1 ]]; then
    echo "Rescan requested: comparing the card against the archive rather than against the last run."
fi
if [[ -z "$REFRESH_MODE" && "$RESCAN" != 1 ]] \
   && (( CAMERA_COUNT == LAST_COUNT )) && [[ "$LAST_CAMERA_FILE" == "$LAST_FILE" ]]; then
    echo "No new files ($CAMERA_COUNT on camera, all previously synced)."
    M_SYNC_OK=1
    NOTHING_NEW=1
    geo_wants_run 1 || exit 0
    echo "Continuing to the geotag review."
fi

# Only now touch the destination drive: a run triggered with no camera attached
# should fail on the detect check above, not on creating directories here.
mkdir -p "$STAGING_DIR"

# Cleared at the start of a run rather than by the EXIT trap, for the same
# reason STAGING_DIR has a fixed name: an orphaned directory is tidied by the
# next run instead of lingering. Doing it here and not in cleanup() also leaves
# a probe's downloaded file on disk afterwards, which is the whole point of a
# probe — the operator wants to look at it.
if [[ -n "$REFRESH_MODE" ]]; then
    rm -rf "${QUARANTINE_DIR:?}"
    mkdir -p "$QUARANTINE_DIR"
fi

# ─── Work out what is missing ──────────────────────────────────────────────────
# Build set of local filenames for fast lookup. Anything under the staging
# directory is in-flight, not synced, so it must not count as present — matched
# on the relative path as a plain string, since a dest_base containing glob
# metacharacters would defeat find's -path pattern.
#
# Refresh mode additionally needs to know WHERE each local file is, so it can
# read the copy it might replace and back it up. That map covers the visible
# archive only: any top-level dot-directory is skipped, which takes in the
# in-flight .staging and .refresh/incoming as well as the hand-maintained
# .deleted/ cull bin. Culled files must keep counting in LOCAL_SET so a normal
# sync still never re-downloads them — but a refresh must never rewrite,
# resurrect or back up anything in there. Skipping every dot-directory rather
# than naming .deleted/ keeps that true for whatever else gets parked in one,
# and matches the set Immich's external-library crawler indexes.
declare -A LOCAL_SET
declare -A LOCAL_PATH_FOR_NAME
declare -A AMBIGUOUS_NAME
while IFS=$'\t' read -r relpath fname lsize lmtime; do
    [[ "$relpath" == "$STAGING_NAME/"* ]] && continue
    [[ "$relpath" == "$REFRESH_NAME/incoming/"* ]] && continue
    # Everything under .geo/ is either bookkeeping or a partial download. The
    # sniff file's fixed name already keeps camera basenames out of there; this
    # is the second guard, so a future artefact cannot reintroduce the hazard.
    [[ "$relpath" == "$GEO_NAME/"* ]] && continue
    LOCAL_SET["$fname"]=1
    if [[ ( -n "$REFRESH_MODE" || "$GEO_MODE" != off ) && "$relpath" != .* ]]; then
        # One basename at two paths gives no safe answer to "which copy should
        # be replaced", so it is recorded and skipped rather than guessed at.
        if [[ -n "${LOCAL_PATH_FOR_NAME[$fname]+x}" ]]; then
            AMBIGUOUS_NAME["$fname"]=1
        else
            LOCAL_PATH_FOR_NAME["$fname"]="$relpath"
        fi
        # Size and mtime come off the same traversal, which is what makes the
        # review's cached "does this file have coordinates?" verdict free to
        # validate: if neither has changed, the file has not, and the recorded
        # answer still stands. %T@ carries a fractional part that ntfs-3g and
        # `touch` do not agree on, so only the whole seconds are kept.
        LOCAL_META["$fname"]="$lsize ${lmtime%%.*}"
    fi
done < <(find "$DEST_BASE" -type f -printf '%P\t%f\t%s\t%T@\n')

MISSING_NAMES=()
REFRESH_SKIPPED_AMBIGUOUS=0
REFRESH_SKIPPED_HAVE_GPS=0
REFRESH_PROMOTED=0
REFRESH_SKIPPED_NO_GPS=0
REFRESH_REFUSED=0
REFRESH_ABSENT=0

if [[ -n "$REFRESH_MODE" ]]; then
    # The normal test asks "which camera files are absent locally?". Refresh asks
    # the opposite: which files are already here, inside the requested scope, and
    # have no coordinates — those are the only ones a re-fetch could improve.
    echo "Refresh mode '$REFRESH_MODE', scope '${REFRESH_SCOPE:-<whole archive>}'."
    echo "Scanning local copies for missing coordinates..."
    for name in "${CAMERA_NAMES[@]}"; do
        rel="${LOCAL_PATH_FOR_NAME[$name]:-}"
        # Not here at all, or only present in a dot-directory: not a refresh
        # target. A genuinely new file is a job for a normal sync, not this.
        [[ -z "$rel" ]] && continue
        if [[ -n "${AMBIGUOUS_NAME[$name]+x}" ]]; then
            REFRESH_SKIPPED_AMBIGUOUS=$(( REFRESH_SKIPPED_AMBIGUOUS + 1 ))
            continue
        fi
        [[ -n "$REFRESH_SCOPE" && "$rel" != "$REFRESH_SCOPE"* ]] && continue
        # Only stills carry a GPS IFD. Without this an .MP4 in scope can never
        # satisfy has_gps and so stays a candidate for ever, re-fetched and
        # thrown away on every single run.
        [[ "${name,,}" == *.jpg || "${name,,}" == *.cr3 ]] || continue
        if has_gps "$DEST_BASE/$rel" >/dev/null; then
            REFRESH_SKIPPED_HAVE_GPS=$(( REFRESH_SKIPPED_HAVE_GPS + 1 ))
            continue
        fi
        MISSING_NAMES+=("$name")
    done

    echo "  ${#MISSING_NAMES[@]} candidate(s) with no coordinates locally."
    (( REFRESH_SKIPPED_HAVE_GPS > 0 )) \
        && echo "  $REFRESH_SKIPPED_HAVE_GPS skipped — already geotagged."
    (( REFRESH_SKIPPED_AMBIGUOUS > 0 )) \
        && echo "  $REFRESH_SKIPPED_AMBIGUOUS skipped — same filename at more than one path."

    # A refresh only ever revisits files that are already here. Anything genuinely
    # new on the card is a normal sync's job, and silently ignoring it would look
    # like the run had collected everything.
    REFRESH_ABSENT=0
    for name in "${CAMERA_NAMES[@]}"; do
        [[ -z "${LOCAL_SET[$name]+x}" ]] && REFRESH_ABSENT=$(( REFRESH_ABSENT + 1 ))
    done
    if (( REFRESH_ABSENT > 0 )); then
        echo "  NOTE: $REFRESH_ABSENT camera file(s) are not in the archive at all."
        echo "        Refresh does not fetch those — run a normal sync afterwards."
    fi

    # A probe exists to answer one question cheaply: does the card copy actually
    # carry coordinates the local one lacks? One file settles it, and there is no
    # sense pulling gigabytes to find out.
    if [[ "$REFRESH_MODE" == probe && ${#MISSING_NAMES[@]} -gt 1 ]]; then
        MISSING_NAMES=("${MISSING_NAMES[0]}")
        echo "  probe: fetching only ${MISSING_NAMES[0]}."
    fi
else
    for name in "${CAMERA_NAMES[@]}"; do
        if [[ -z "${LOCAL_SET[$name]+x}" ]]; then
            MISSING_NAMES+=("$name")
        fi
    done
fi

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
    if [[ -n "$REFRESH_MODE" ]]; then
        echo "DRY RUN: ${#MISSING_NAMES[@]} local file(s) would be re-fetched for a coordinate check."
    else
        echo "DRY RUN: ${#MISSING_NAMES[@]} of $CAMERA_COUNT camera file(s) missing locally."
    fi
    if (( ${#MISSING_NAMES[@]} > 0 )); then
        printf '  %s\n' "${MISSING_NAMES[@]}"
    fi
    exit 0
fi

# ─── Download ──────────────────────────────────────────────────────────────────
ABORTED=0
FAILED=()

if [[ ${#MISSING_NAMES[@]} -eq 0 ]]; then
    if [[ -n "$REFRESH_MODE" ]]; then
        echo "Nothing to refresh: no local file in scope is missing coordinates."
    else
        echo "All $CAMERA_COUNT files already exist locally."
    fi
else
    if [[ -n "$REFRESH_MODE" ]]; then
        echo "Re-fetching ${#MISSING_NAMES[@]} file(s) to check for coordinates..."
    else
        echo "Downloading ${#MISSING_NAMES[@]} new file(s)..."
    fi
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
            if [[ -n "$REFRESH_MODE" ]]; then
                refresh_commit "$name" || { ABORTED=1; break; }
            else
                M_RUN_DOWNLOADED=$(( M_RUN_DOWNLOADED + 1 ))
            fi
            continue
        fi

        echo "WARNING: Failed '$name', retrying in 3s..."
        sleep 3
        rc=0
        fetch_file "$loc" "$name" "${KB_FOR_NAME[$name]:-0}" || rc=$?
        if (( rc == 0 )); then
            CONSECUTIVE_FAILS=0
            if [[ -n "$REFRESH_MODE" ]]; then
                refresh_commit "$name" || { ABORTED=1; break; }
            else
                M_RUN_DOWNLOADED=$(( M_RUN_DOWNLOADED + 1 ))
            fi
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
        # Only worth walking the archive if something was actually written to it.
        if (( M_RUN_DOWNLOADED > 0 )); then
            chown -R "$OWNER_USER:$OWNER_GROUP" "$DEST_BASE"
        fi
        exit 1
    fi
fi

# Update sync state only on full success (count:last_filename). Deliberately the
# snapshot taken before the download loop, not the live values — see above.
#
# A refresh must not write it. It fetches nothing new, so the count and last
# filename it would record are whatever the card already held — and if a normal
# sync had been interrupted, stamping that here would tell the next run its
# unfinished listing was fully synced and the quick-exit would skip those files
# for good.
if [[ -n "$REFRESH_MODE" ]]; then
    echo "State file left untouched (refresh mode fetched nothing new)."
elif (( NOTHING_NEW )); then
    # Identical bytes to what is already there. Skipped rather than rewritten
    # because this path is now reached by every poll that goes on to a review,
    # and DEST_BASE is a fuseblk mount where even that costs a round trip.
    :
else
    echo "${SYNCED_COUNT}:${SYNCED_LAST_FILE}" > "$STATE_FILE"
fi
M_SYNC_OK=1

# ─── Geotag review ─────────────────────────────────────────────────────────────
# Deliberately here and nowhere earlier. The state file is already written and
# M_SYNC_OK is already set, so the photo sync's success is durable and
# metrics_final has committed to its verdict before this runs — a review that
# fails cannot turn a run that collected photos into a failed one. `|| true`
# says the same thing again at the call site.
#
# A run that aborted never gets here: it exits further up. That is right. A run
# that could not fetch new photos should not then spend a budget on old ones.
if geo_wants_run "$NOTHING_NEW"; then
    M_PHASE=geo
    metrics_emit
    geo_phase "$NOTHING_NEW" || true
fi

# Set ownership so the non-root user can access the downloaded files.
#
# Guarded, because the quick exit above now falls through to here. Unguarded
# this would walk and chown every file in the archive on every poll, several
# times an hour, on a fuseblk mount over an SMR disk — for runs that changed
# nothing at all.
if (( M_RUN_DOWNLOADED > 0 || G_PROMOTED > 0 )); then
    chown -R "$OWNER_USER:$OWNER_GROUP" "$DEST_BASE"
fi

if [[ -n "$REFRESH_MODE" ]]; then
    echo "Refresh complete."
    if [[ "$REFRESH_MODE" == probe ]]; then
        if (( REFRESH_PROMOTED > 0 )); then
            echo "  The card DOES carry coordinates the archive is missing."
            echo "  Re-run with CAMERA_SYNC_REFRESH=run to apply it."
        else
            echo "  The card copy is no better than the local one."
            echo "  A full refresh would replace nothing — geotag from a GPS track instead."
        fi
    else
        echo "  $REFRESH_PROMOTED file(s) replaced; originals under $REFRESH_NAME/${BACKUP_DIR#"$REFRESH_DIR"/}"
        echo "  $REFRESH_SKIPPED_NO_GPS left alone (card copy had no coordinates either)."
        (( REFRESH_REFUSED > 0 )) && echo "  $REFRESH_REFUSED refused (card copy smaller than the local file)."
        echo "  Re-run the same command to resume: a replaced file now has"
        echo "  coordinates and is no longer a candidate."
    fi
else
    echo "Sync complete. Files saved to $DEST_BASE"
fi
