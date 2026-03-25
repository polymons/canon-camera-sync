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

# ─── Detect camera ─────────────────────────────────────────────────────────────
# Uses gphoto2 auto-detect and checks for the camera brand name.
# Change CAMERA_DETECT_NAME in config.yml if you use a non-Canon camera.
if ! gphoto2 --auto-detect 2>/dev/null | grep -qi "$CAMERA_DETECT_NAME"; then
    echo "ERROR: No $CAMERA_DETECT_NAME camera detected. Connect the camera and try again."
    exit 1
fi

# Wait for the filesystem to stabilize
sleep 2

# Get full file listing from camera (used for count + integrity check)
FILE_LIST=$(gphoto2 --list-files 2>/dev/null | grep "^#" || true)
CAMERA_COUNT=$(echo "$FILE_LIST" | grep -c "^#" || true)

if [[ $CAMERA_COUNT -eq 0 ]]; then
    echo "No files found on camera."
    exit 0
fi

# Name of the last file on camera — used to detect any change
LAST_CAMERA_FILE=$(echo "$FILE_LIST" | tail -1 | awk '{print $2}')

# Read previous sync state (format: count:last_filename)
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

# Build set of local filenames for fast lookup
declare -A LOCAL_SET
while IFS= read -r fname; do
    LOCAL_SET["$fname"]=1
done < <(find "$DEST_BASE" -type f -printf '%f\n')

# Find camera files not present locally
MISSING_NUMS=()
mapfile -t FILE_LINES <<< "$FILE_LIST"
for line in "${FILE_LINES[@]}"; do
    FILE_NAME=$(echo "$line" | awk '{print $2}')
    if [[ -z "${LOCAL_SET[$FILE_NAME]+x}" ]]; then
        FILE_NUM=$(echo "$line" | grep -oP '^#\K[0-9]+')
        MISSING_NUMS+=("$FILE_NUM")
    fi
done

if [[ ${#MISSING_NUMS[@]} -eq 0 ]]; then
    echo "All $CAMERA_COUNT files already exist locally."
else
    echo "Downloading ${#MISSING_NUMS[@]} new file(s)..."
    FAILED=()
    for NUM in "${MISSING_NUMS[@]}"; do
        if ! gphoto2 --get-file "$NUM" --filename "$DEST_BASE/%Y/%m/%f.%C"; then
            echo "WARNING: Failed file #$NUM, retrying in 3s..."
            sleep 3
            if ! gphoto2 --get-file "$NUM" --filename "$DEST_BASE/%Y/%m/%f.%C"; then
                echo "ERROR: Skipping file #$NUM after retry failure."
                FAILED+=("$NUM")
            fi
        fi
    done
    if [[ ${#FAILED[@]} -gt 0 ]]; then
        echo "WARNING: ${#FAILED[@]} file(s) failed: ${FAILED[*]}"
        echo "State file NOT updated — next run will retry failed files."
        chown -R "$OWNER_USER:$OWNER_GROUP" "$DEST_BASE"
        exit 1
    fi
fi

# Update sync state only on full success (count:last_filename)
echo "${CAMERA_COUNT}:${LAST_CAMERA_FILE}" > "$STATE_FILE"

# Set ownership so the non-root user can access the downloaded files
chown -R "$OWNER_USER:$OWNER_GROUP" "$DEST_BASE"

echo "Sync complete. Files saved to $DEST_BASE"