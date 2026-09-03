#!/bin/bash
set -euo pipefail

# ─── Load configuration from config.yml ────────────────────────────────────────
# Resolve the directory where this script lives, so config.yml is found
# regardless of the working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yml"

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

# Ensure destination base exists
mkdir -p "$DEST_BASE"

# ─── Kill gvfs-gphoto2-volume-monitor ──────────────────────────────────────────
# GNOME's gvfs grabs exclusive USB access to the camera and blocks gphoto2
# from connecting. Killing it here allows gphoto2 to take over.
# It will respawn automatically later when needed by GNOME.
pkill -f gvfs-gphoto2-volume-monitor 2>/dev/null || true
sleep 2

# ─── Tunables ──────────────────────────────────────────────────────────────────
# Consecutive download failures tolerated before the script checks whether the
# camera is still attached (see the download loop below).
MAX_CONSECUTIVE_FAILS=3
# Total failures tolerated in one run. A camera that stays enumerated but never
# delivers a file would otherwise burn two attempts plus a 3s sleep on every
# remaining file — hours of no progress on a full card.
MAX_TOTAL_FAILS=25

# ─── Camera helpers ────────────────────────────────────────────────────────────
camera_present() {
    gphoto2 --auto-detect 2>/dev/null | grep -qi "$CAMERA_DETECT_NAME"
}

# Map camera filenames to their gphoto2 index numbers and reported sizes.
#
# Indices are only meaningful within a single camera session: after a USB
# reconnect, or any add/delete on the card, they shift. Fetching by a stale
# index silently downloads the wrong image, so the listing is re-read whenever
# the session may have changed.
declare -A NUM_FOR_NAME
declare -A KB_FOR_NAME
CAMERA_NAMES=()
CAMERA_COUNT=0
LAST_CAMERA_FILE=""

# gphoto2 --list-files emits e.g.
#   #1     IMG_0001.JPG               rd  5162 KB image/jpeg
# Parsed with a single bash regex rather than per-line greps: it forks nothing,
# and unlike `awk '{print $2}'` it keeps filenames that contain spaces intact.
LIST_RE='^#([0-9]+)[[:space:]]+(.+)[[:space:]]+[a-zA-Z-]{2}[[:space:]]+([0-9]+)[[:space:]]+KB'

build_index() {
    local list line num name kb dupes=0
    list=$(gphoto2 --list-files 2>/dev/null | grep "^#" || true)
    [[ -z "$list" ]] && return 1

    NUM_FOR_NAME=()
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
        if [[ -n "${NUM_FOR_NAME[$name]+x}" ]]; then
            dupes=$(( dupes + 1 ))
            continue
        fi
        NUM_FOR_NAME["$name"]="$num"
        KB_FOR_NAME["$name"]="$kb"
        CAMERA_NAMES+=("$name")
    done <<< "$list"

    if (( dupes > 0 )); then
        echo "WARNING: $dupes camera file(s) share a basename with another file and cannot both be stored; only the first of each is synced."
    fi

    (( CAMERA_COUNT > 0 ))
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
cleanup() {
    [[ -n "${STAGING_DIR:-}" && -d "$STAGING_DIR" ]] && rm -rf "$STAGING_DIR"
    return 0
}
trap cleanup EXIT

# Download one file by index, verify it is the file that was asked for and that
# it arrived whole, then move it into DEST_BASE preserving gphoto2's YYYY/MM
# layout. Returns 0 on success, 2 if the index was stale, 1 otherwise.
fetch_file() {
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
    mkdir -p "$(dirname "$dst")"
    mv -f "$src" "$dst" || return 1
    return 0
}

# ─── Detect camera ─────────────────────────────────────────────────────────────
# Uses gphoto2 auto-detect and checks for the camera brand name.
# Change CAMERA_DETECT_NAME in config.yml if you use a non-Canon camera.
if ! camera_present; then
    echo "ERROR: No $CAMERA_DETECT_NAME camera detected. Connect the camera and try again."
    exit 1
fi

# Wait for the filesystem to stabilize
sleep 2

if ! build_index; then
    echo "No files found on camera."
    exit 0
fi

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
        num="${NUM_FOR_NAME[$name]:-}"
        if [[ -z "$num" ]]; then
            echo "WARNING: '$name' is no longer on the camera — skipping."
            FAILED+=("$name")
            GONE=$(( GONE + 1 ))
            continue
        fi

        ATTEMPTED=$(( ATTEMPTED + 1 ))
        rc=0
        fetch_file "$num" "$name" "${KB_FOR_NAME[$name]:-0}" || rc=$?

        # A stale index means the listing, not the file, is wrong: re-read it
        # and retry immediately with the correct number rather than burning
        # this file (and the next two) on the generic retry path.
        if (( rc == 2 )); then
            if build_index; then
                num="${NUM_FOR_NAME[$name]:-}"
                if [[ -n "$num" ]]; then
                    rc=0
                    fetch_file "$num" "$name" "${KB_FOR_NAME[$name]:-0}" || rc=$?
                else
                    rc=1
                fi
            else
                rc=1
            fi
        fi

        if (( rc == 0 )); then
            CONSECUTIVE_FAILS=0
            continue
        fi

        echo "WARNING: Failed '$name' (#$num), retrying in 3s..."
        sleep 3
        rc=0
        fetch_file "$num" "$name" "${KB_FOR_NAME[$name]:-0}" || rc=$?
        if (( rc == 0 )); then
            CONSECUTIVE_FAILS=0
            continue
        fi

        echo "ERROR: Skipping '$name' (#$num) after retry failure."
        FAILED+=("$name")
        CONSECUTIVE_FAILS=$(( CONSECUTIVE_FAILS + 1 ))

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
            # Still attached, so this was likely a reconnect: the indices from
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

# Update sync state only on full success (count:last_filename)
echo "${CAMERA_COUNT}:${LAST_CAMERA_FILE}" > "$STATE_FILE"

# Set ownership so the non-root user can access the downloaded files
chown -R "$OWNER_USER:$OWNER_GROUP" "$DEST_BASE"

echo "Sync complete. Files saved to $DEST_BASE"
