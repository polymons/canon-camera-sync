#!/bin/bash
set -euo pipefail

# ─── Canon Camera Auto-Sync — Quick Setup ──────────────────────────────────────
# Downloads the project, opens the config for editing, and installs everything.
#
# Usage:
#   wget -qO- https://raw.githubusercontent.com/polymons/canon-camera-sync/main/setup.sh | bash
#   or:
#   curl -fsSL https://raw.githubusercontent.com/polymons/canon-camera-sync/main/setup.sh | bash

REPO="polymons/canon-camera-sync"
BRANCH="main"
INSTALL_TMP="/tmp/canon-camera-sync-setup"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║    Canon Camera Auto-Sync — Quick Setup      ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ─── Preflight checks ──────────────────────────────────────────────────────────

if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Do not run this script as root."
    echo "It will ask for sudo when needed."
    exit 1
fi

# Check for required tools
for cmd in wget gphoto2; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' is not installed."
        echo ""
        echo "Install it first:"
        echo "  Debian/Ubuntu: sudo apt install $cmd"
        echo "  Fedora:        sudo dnf install $cmd"
        echo "  Arch:          sudo pacman -S $cmd"
        exit 1
    fi
done

# ─── Download project ──────────────────────────────────────────────────────────

echo "[1/4] Downloading project files..."
rm -rf "$INSTALL_TMP"
mkdir -p "$INSTALL_TMP"

wget -qO "$INSTALL_TMP/archive.tar.gz" "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz"
tar -xzf "$INSTALL_TMP/archive.tar.gz" -C "$INSTALL_TMP" --strip-components=1
rm "$INSTALL_TMP/archive.tar.gz"
echo "  [OK] Downloaded to $INSTALL_TMP"

# ─── Help user find their camera USB IDs ────────────────────────────────────────

echo ""
echo "[2/4] Detecting camera..."
echo ""
echo "  If your camera is plugged in, here are the USB devices found:"
echo "  ─────────────────────────────────────────────────────────────"
lsusb | grep -iE "canon|nikon|sony|fuji|olympus|panasonic|camera" || echo "  (no camera-like devices detected — plug in your camera to find the IDs)"
echo "  ─────────────────────────────────────────────────────────────"
echo ""
echo "  You need the vendor ID and product ID from the output above."
echo "  Example: ID 04a9:32f9 → vendor=04a9, product=32f9"
echo ""

# ─── Create config and open editor ─────────────────────────────────────────────

echo "[3/4] Opening configuration for editing..."
cp "$INSTALL_TMP/config.example.yml" "$INSTALL_TMP/config.yml"

# Pick an editor
EDITOR_CMD="${EDITOR:-${VISUAL:-}}"
if [[ -z "$EDITOR_CMD" ]]; then
    for e in nano vim vi; do
        if command -v "$e" &>/dev/null; then
            EDITOR_CMD="$e"
            break
        fi
    done
fi

if [[ -z "$EDITOR_CMD" ]]; then
    echo "ERROR: No text editor found. Set the EDITOR environment variable."
    echo "You can manually edit: $INSTALL_TMP/config.yml"
    echo "Then run: cd $INSTALL_TMP && sudo ./install.sh"
    exit 1
fi

echo ""
echo "  Your editor ($EDITOR_CMD) will now open config.yml."
echo "  Update the values for your setup, then save and exit."
echo ""
read -rp "  Press Enter to open the editor..."

"$EDITOR_CMD" "$INSTALL_TMP/config.yml"

# Validate that the user actually edited the config
DEST_CHECK=$(grep -E "^dest_base:" "$INSTALL_TMP/config.yml" | head -1 | sed 's/^dest_base:[[:space:]]*//' | sed 's/[[:space:]]*#.*//')
if [[ "$DEST_CHECK" == "/path/to/your/photo/destination" ]]; then
    echo ""
    echo "ERROR: config.yml still has the placeholder destination path."
    echo "Edit it manually: $INSTALL_TMP/config.yml"
    echo "Then run: cd $INSTALL_TMP && sudo ./install.sh"
    exit 1
fi

# ─── Run installer ─────────────────────────────────────────────────────────────

echo ""
echo "[4/4] Installing (requires sudo)..."
echo ""
chmod +x "$INSTALL_TMP/install.sh"
sudo "$INSTALL_TMP/install.sh"

# ─── Cleanup ───────────────────────────────────────────────────────────────────

echo ""
echo "Setup complete! You can remove the temporary files:"
echo "  rm -rf $INSTALL_TMP"
echo ""
echo "Test by plugging in your camera, then check logs:"
echo "  journalctl -u canon-camera-sync.service -f"
