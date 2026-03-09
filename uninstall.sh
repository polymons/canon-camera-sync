#!/bin/bash
set -euo pipefail

# ─── Canon Camera Sync — Uninstaller ───────────────────────────────────────────
# Removes the installed udev rule, systemd service, and script directory.
# Must be run as root (sudo ./uninstall.sh).

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root. Use: sudo ./uninstall.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yml"

# Parse a value from flat YAML (key: value). Strips comments and quotes.
yml_get() {
    local val
    val=$(grep -E "^${1}:" "$CONFIG_FILE" | head -1 | sed "s/^${1}:[[:space:]]*//" | sed 's/[[:space:]]*#.*//' | sed 's/^["'\'']\(.*\)["'\'']$/\1/')
    echo "$val"
}

# Try to read the install directory from config, fall back to default
SCRIPT_INSTALL_DIR="/opt/canon-camera-sync"
if [[ -f "$CONFIG_FILE" ]]; then
    SCRIPT_INSTALL_DIR="$(yml_get script_dir)"
fi

echo "Uninstalling canon-camera-sync..."

# Remove udev rule
UDEV_RULE="/etc/udev/rules.d/99-canon-camera-sync.rules"
if [[ -f "$UDEV_RULE" ]]; then
    rm "$UDEV_RULE"
    echo "  [OK] Removed $UDEV_RULE"
else
    echo "  [--] $UDEV_RULE not found, skipping"
fi

# Remove systemd service
SERVICE_FILE="/etc/systemd/system/canon-camera-sync.service"
if [[ -f "$SERVICE_FILE" ]]; then
    rm "$SERVICE_FILE"
    echo "  [OK] Removed $SERVICE_FILE"
else
    echo "  [--] $SERVICE_FILE not found, skipping"
fi

# Remove installed script directory
if [[ -d "$SCRIPT_INSTALL_DIR" ]]; then
    rm -rf "$SCRIPT_INSTALL_DIR"
    echo "  [OK] Removed $SCRIPT_INSTALL_DIR"
else
    echo "  [--] $SCRIPT_INSTALL_DIR not found, skipping"
fi

# Reload system daemons
udevadm control --reload-rules
systemctl daemon-reload
echo "  [OK] udev rules and systemd reloaded"

echo ""
echo "Uninstall complete."
echo "NOTE: Your photo destination directory was NOT removed."
