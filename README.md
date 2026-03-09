# Canon Camera Auto-Sync

Automatically downloads photos, RAW files, and videos from a Canon camera (or any gphoto2-compatible camera) when connected via USB. Files are organized into `YYYY/MM/` folders by capture date. Only new files are downloaded on each sync — no duplicates, no re-downloads.

Originally built for the Canon EOS M50 Mark II, but works with **any camera supported by [gphoto2](http://gphoto2.org/proj/libgphoto2/support.php)** — just update the USB IDs in `config.yml`.

## How It Works

1. **Camera plugged in via USB** → udev detects the configured USB device
2. **udev rule** sets USB permissions and tells systemd to start the sync service
3. **systemd service** waits a few seconds for the camera to initialize, then runs the sync script as root (required for USB driver detachment)
4. **Sync script** kills `gvfs-gphoto2-volume-monitor` (GNOME grabs exclusive USB access otherwise), then uses `gphoto2` to download only new files
5. File ownership is set to your configured user after download
6. A state file (`.last_sync_count`) tracks what was synced — only new files are fetched
7. If the SD card was formatted or swapped (file count decreased), a full sync runs automatically

### Output Folder Structure

```
/your/photo/destination/
├── 2024/
│   ├── 02/
│   │   ├── IMG_4778.CR3
│   │   ├── IMG_4778.JPG
│   │   └── ...
│   └── 08/
├── 2025/
│   └── 10/
└── 2026/
    └── 03/
```

---

## Prerequisites

- **Linux** with systemd (Debian/Ubuntu, Fedora, Arch, etc.)
- **gphoto2** — communicates with the camera over USB
- USB connection to camera (the camera must be in **PTP mode**, not mass storage)

---

## Installation

### Quick Install (recommended)

One command to download, configure, and install everything:

```bash
wget -qO- https://raw.githubusercontent.com/polymons/canon-camera-sync/main/setup.sh | bash
```


This will:
1. Download the project
2. Detect any connected cameras and show their USB IDs
3. Open `config.yml` in your editor — fill in your values and save
4. Install the udev rule, systemd service, and sync script (asks for sudo)

> **Prerequisites:** `wget` and `gphoto2` must be installed first (see below).

---

### Manual Install

If you prefer to install step by step:

#### 1. Install dependencies

```bash
# Debian/Ubuntu
sudo apt install gphoto2

# Fedora
sudo dnf install gphoto2

# Arch
sudo pacman -S gphoto2
```

#### 2. Find your camera's USB IDs

Plug in your camera and run:

```bash
lsusb | grep -i canon
```

Example output:

```
Bus 001 Device 015: ID 04a9:32f9 Canon, Inc. Canon Digital Camera
```

- **`04a9`** = Vendor ID (Canon — same for all Canon cameras)
- **`32f9`** = Product ID (specific to Canon EOS M50 Mark II — **yours will differ** if you have another model)

**Common Canon product IDs:**

| Product ID | Camera Model |
|------------|--------------|
| `32f9` | Canon EOS M50 Mark II |
| `32d2` | Canon EOS R |
| `32da` | Canon EOS RP |
| `32e2` | Canon EOS R5 |
| `32e4` | Canon EOS R6 |

For non-Canon cameras, also change the vendor ID (e.g., Nikon = `04b0`, Sony = `054c`).

#### 3. Configure

```bash
cp config.example.yml config.yml
```

Edit `config.yml` with your values:

```yaml
# Absolute path where downloaded photos will be saved
dest_base: /home/youruser/Pictures/Canon

# Linux user/group that will own the downloaded files
owner_user: youruser
owner_group: youruser

# USB IDs from lsusb (see step 2)
camera_vendor_id: "04a9"
camera_product_id: "32f9"
camera_detect_name: canon

# Where the script gets installed
script_dir: /opt/canon-camera-sync

# Seconds to wait after USB connect before syncing
pre_delay_seconds: 5
```

| Field | Description |
|-------|-------------|
| `dest_base` | Where to save downloaded photos |
| `owner_user` / `owner_group` | Your Linux username (for file ownership) |
| `camera_vendor_id` | USB vendor ID from `lsusb` |
| `camera_product_id` | USB product ID from `lsusb` (camera-model-specific) |
| `camera_detect_name` | Brand name used for detection (e.g., `canon`, `nikon`) |
| `script_dir` | Where the script gets installed on your system |
| `pre_delay_seconds` | Seconds to wait after USB connect before syncing |

#### 4. Install

```bash
chmod +x install.sh
sudo ./install.sh
```

This will:
- Copy the sync script to your configured `script_dir`
- Generate and install the udev rule to `/etc/udev/rules.d/`
- Generate and install the systemd service to `/etc/systemd/system/`
- Create the destination directory
- Reload udev rules and systemd

#### 5. Test

```bash
# Manual test (camera must be connected via USB)
# Replace /opt/canon-camera-sync with the script_dir value from your config.yml
sudo /opt/canon-camera-sync/camera-sync.sh

# Or watch logs in real-time, then plug in the camera
journalctl -u canon-camera-sync.service -f
```

---

## Usage

### Automatic sync (plug-and-play)

Once installed, simply **plug in your camera via USB**. The sync starts automatically within a few seconds. No manual steps needed.

### Manual sync

```bash
# Use the script_dir path from your config.yml
sudo /opt/canon-camera-sync/camera-sync.sh
```

### Force full re-sync

Delete the state file to re-download everything:

```bash
# Use the dest_base path from your config.yml
rm /your/photo/destination/.last_sync_count
sudo /opt/canon-camera-sync/camera-sync.sh
```

### Check logs

```bash
# View the most recent service run
journalctl -u canon-camera-sync.service -e

# Show only errors
journalctl -u canon-camera-sync.service -p err --no-pager

# Follow logs live (run before connecting camera)
journalctl -u canon-camera-sync.service -f
```

---

## Uninstalling

```bash
chmod +x uninstall.sh
sudo ./uninstall.sh
```

---

## Project Files

| File | Purpose |
|------|---------|
| `camera-sync.sh` | Main sync script — detects camera, downloads new files, sets ownership |
| `config.example.yml` | Example configuration (with comments) — copy to `config.yml` and edit |
| `setup.sh` | One-command bootstrap — downloads, configures, and installs everything |
| `install.sh` | Installer — reads config, generates udev rule + systemd service, installs everything |
| `uninstall.sh` | Uninstaller — removes installed files and reloads system daemons |
| `99-camera-sync.rules` | Template udev rule (reference; `install.sh` generates the actual installed rule) |
| `camera-sync.service` | Template systemd service (reference; `install.sh` generates the actual installed service) |

---

## Integration with Immich

The synced photos can be imported into [Immich](https://immich.app) as an external library.

### Docker Compose volume

Add the sync folder as a read-only volume to `immich-server`:

```yaml
services:
  immich-server:
    volumes:
      - ${UPLOAD_LOCATION}:/data
      - /etc/localtime:/etc/localtime:ro
      - /your/photo/destination:/mnt/camera_sync:ro
```

### Immich setup

1. Restart Immich: `docker compose down && docker compose up -d`
2. Go to **Immich Admin → External Libraries**
3. Add `/mnt/camera_sync` as an external library import path
4. Immich will scan the `YYYY/MM/` folders and index all photos and videos

---

## Troubleshooting

### USB Permission Denied

gphoto2 needs root to send `USBDEVFS_DISCONNECT` and detach the kernel USB driver. The service runs as root for this reason.

1. Verify the service has no `User=` line: `systemctl cat canon-camera-sync.service`
2. Verify the udev rule grants device access: `cat /etc/udev/rules.d/99-canon-camera-sync.rules`

### gphoto2 can't access camera

If another process (like a desktop file manager) grabs the camera first:

```bash
pkill -f gvfs-gphoto2-volume-monitor
```

To prevent this permanently:

```bash
sudo chmod -x /usr/lib/gvfs/gvfs-gphoto2-volume-monitor
```

### Service doesn't trigger on USB connect

```bash
# Verify rule is installed
cat /etc/udev/rules.d/99-canon-camera-sync.rules

# Monitor udev events (plug in camera while watching)
sudo udevadm monitor --property

# Test the rule manually
sudo udevadm test $(udevadm info -q path -n /dev/bus/usb/001/015)
```

### Camera not detected by gphoto2

```bash
gphoto2 --auto-detect
```

If nothing shows, ensure the camera is in **PTP mode** (not mass storage):
- **Canon**: Menu → Wrench tab → Communication settings → USB connection type → **Auto** or **Photo Transfer Protocol**

### Debug logging

```bash
gphoto2 --debug --debug-logfile=gphoto2-debug.log --list-files
```

---

## Notes

- Downloads **all file types**: CR3/CR2 (RAW), JPG, MOV (video), etc.
- Files are **not deleted** from the camera after download
- The `%Y/%m` filename pattern uses the file's **capture date**, not the current date
- The pre-delay in the systemd service gives the camera time to initialize over USB
- If the SD card is formatted or swapped (file count drops), a full sync runs automatically
- `MODE="0666"` in the udev rule is required for cameras not in gphoto2's default USB permission list

## License

MIT
