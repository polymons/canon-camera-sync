# Canon Camera Auto-Sync

Automatically downloads photos, RAW files, and videos from a Canon camera — over
**USB** when it is plugged in, or over **Wi-Fi** when it is not. Files are
organized into `YYYY/MM/` folders by capture date. Only new files are downloaded
on each sync — no duplicates, no re-downloads.

Originally built for the Canon EOS M50 Mark II. The USB path works with **any
camera supported by [gphoto2](http://gphoto2.org/proj/libgphoto2/support.php)** —
just update the USB IDs in `config.yml`. The Wi-Fi path uses Canon's CCAPI and so
works with [any Canon body that supports it](#wi-fi-transfer-ccapi).

## How It Works

1. **Camera plugged in via USB** → udev detects the configured USB device
2. **udev rule** sets USB permissions and tells systemd to start the sync service
3. **systemd service** waits a few seconds for the camera to initialize, then runs the sync script as root (required for USB driver detachment)
4. **Sync script** kills `gvfs-gphoto2-volume-monitor` (GNOME grabs exclusive USB access otherwise), then uses `gphoto2` to download only new files
5. File ownership is set to your configured user after download
6. A state file (`.last_sync_count`) tracks what was synced — only new files are fetched
7. If the SD card was formatted or swapped (file count decreased), a full sync runs automatically

**Over Wi-Fi** the same script instead talks to Canon's CCAPI over HTTP, finding
the camera on the network by its MAC address. Transport selection is automatic:
USB wins whenever the camera is plugged in, Wi-Fi is used when it is not. See
[Wi-Fi transfer (CCAPI)](#wi-fi-transfer-ccapi).

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

For the optional Wi-Fi transport, additionally:

- **curl** and **python3** — both are present on most systems already
- A Canon body that supports **CCAPI**, activated once over USB
  (see [Wi-Fi transfer (CCAPI)](#wi-fi-transfer-ccapi))

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

## Wi-Fi transfer (CCAPI)

When no cable is to hand, the camera can be synced over Wi-Fi using **CCAPI**
(Canon Camera Control API) — Canon's official HTTP interface for listing and
downloading what is on the card. The same sync logic, retries and integrity
checks are used; only the transport differs.

> **You need a Windows or Mac computer and a USB cable once, to activate CCAPI.**
> Canon ships the activation tool for those two platforms only, and it talks to
> the camera over USB. After that one-time step everything is wireless, and the
> sync itself runs fine on Linux.

### Step 1 — Activate CCAPI on the camera (one time)

1. Update the camera to the latest firmware.
2. Register (free) with Canon's Developer Community for your region and download
   the **CCAPI Activation Tool**:
   - Americas — <https://developercommunity.usa.canon.com/>
   - EMEA / Asia — <https://developers.canon-europe.com/>
3. Make sure the computer is **connected to the internet** — activation fails
   offline.
4. Turn the camera **off**, connect it by USB, then turn it **on**.
5. Run the Activation Tool and click **Execute Activation**, accept the notice,
   then quit the tool.
6. Turn the camera off and unplug it.
7. Confirm it worked: **MENU → Wi-Fi settings** now lists **[Camera Control API]**.

If that menu entry is missing, CCAPI is not active and nothing below will work.

### Step 2 — Put the camera on your Wi-Fi

Do this with a **fully charged battery** — a large transfer runs for a while —
and with **no USB cable attached**, since the camera disables Wi-Fi while USB is
connected.

1. **MENU → Set-up tab → Auto power off: Disable**, and **Eco mode: Off**.
   Without this the camera sleeps and drops the transfer part-way through.
2. **MENU → Wi-Fi settings → Camera Control API → Add connection**.
3. **Add with wizard →** select your network's SSID → enter its password.
4. **IP address set → Auto setting** (DHCP is fine — the sync finds the camera by
   MAC address, so it does not care what address it gets).
5. Note the **Port No.** shown on the Camera Control API screen. The default is
   `08080`, i.e. port `8080`.
6. Set **Auto connect → Enable**. The camera then rejoins Wi-Fi by itself every
   time it is switched on, which is what makes unattended syncing work.
7. *(Optional)* **Account settings** registers a username and password for HTTP
   authentication. With no account registered CCAPI is open to anything on your
   LAN, which is usually fine on a home network.

To reconnect later: **MENU → Wi-Fi settings → Camera Control API → Connect**.

### Step 3 — Point the sync at the camera

Find the camera's Wi-Fi MAC under **MENU → Wi-Fi settings → MAC address**, and
put it in `config.yml`:

```yaml
camera_mac: "74:38:B7:E2:73:5F"    # dashes or colons, either is fine
ccapi_port: 8080                   # only if you changed it on the camera
ccapi_user: ""                     # only if you registered an account
ccapi_password: ""
```

That is the whole configuration. The address is resolved from the ARP table on
every run, so the camera can stay on DHCP with no router reservation. If the MAC
is not cached yet, the script sweeps your local subnet once to find it.

**Transport selection is automatic.** USB is preferred whenever the camera is
plugged in — it is faster and needs no camera-side setup — and Wi-Fi is used
when it is not. Nothing needs changing when you switch between the two. Set
`transport` explicitly only to pin one:

| Value | Behaviour |
|---|---|
| `auto` | USB if connected, otherwise Wi-Fi (default; also what an absent key means) |
| `usb` | USB only, never fall back to the network |
| `ccapi` | Network only, even if the camera is also plugged in |

With no `camera_mac` set, the Wi-Fi path is skipped entirely and `auto` behaves
exactly like `usb`.

### Step 4 — Check it before a long transfer

With the camera connected (its screen shows **[Wi-Fi on]**):

```bash
# Does CCAPI answer at all? Lists the API versions the camera supports.
curl -sS http://<camera-ip>:8080/ccapi

# What would be synced, without downloading anything.
DRY_RUN=1 sudo /opt/canon-camera-sync/camera-sync.sh
```

The script prints which transport it chose — `Camera found on USB.` or
`Camera found on the network at <ip> (CCAPI port 8080).`

### Triggering

There is no udev event for a camera on the network, so the Wi-Fi path is either
run by hand or driven by a timer:

There is no udev event for a camera on Wi-Fi, but the camera announces itself:
with CCAPI enabled it broadcasts a UPnP/SSDP `ssdp:alive` message when it joins
the network. `canon-camera-watch.service` listens for that and starts a sync
within seconds, so nothing has to poll.

```bash
sudo install -m755 canon-camera-watch.py     /opt/canon-camera-sync/
sudo install -m644 canon-camera-watch.service /etc/systemd/system/
sudo install -m644 camera-sync-wifi.service   /etc/systemd/system/canon-camera-sync-wifi.service
sudo install -m644 camera-sync-wifi.timer     /etc/systemd/system/canon-camera-sync-wifi.timer
sudo systemctl daemon-reload
sudo systemctl enable --now canon-camera-watch.service
sudo systemctl enable --now canon-camera-sync-wifi.timer
```

The watcher identifies the camera by the MAC embedded in its UPnP UUID, read
from the same `camera_mac` in `config.yml`, and debounces the burst of
announcements a camera sends on power-on so one switch-on produces one sync.

The timer is a **safety net**, not the main trigger: it re-checks every 30
minutes in case an announcement was lost (multicast is not reliable), cannot
stack runs on top of one in progress, and treats "no camera right now" as
success rather than a failed unit. Combined with the camera's **Auto connect**,
switching the camera on is all that is needed for a sync to happen.

Discovery itself is announcement-driven too: the script asks over SSDP first —
one multicast packet, answered by the camera with its own address — and only
falls back to the ARP table and a subnet sweep if that goes unanswered.

### How files are filed

Photos are stored under `YYYY/MM/` by **capture date**, read from the image's
own EXIF `DateTimeOriginal`. If that cannot be read, the script falls back to the
HTTP `Last-Modified` header and then to the camera's file metadata. A file whose
date cannot be established from any of those is **discarded and retried on the
next run**, rather than being filed under the wrong month.

### Limits

- Expect roughly 1–3 MB/s on the camera's 2.4GHz radio, so a large backlog takes
  a while. It is bounded and resumable: nothing is lost if it is interrupted.
- Very large video files may be better fetched over USB or a card reader.

## Monitoring (optional)

Every run writes Prometheus metrics to a file, so progress, outcomes and error
counts can be graphed rather than dug out of the journal:

```
/var/lib/node_exporter/textfile_collector/canon_camera_sync.prom
```

If that directory does not exist, or is not writable, **metrics are silently
skipped and the sync behaves exactly as it would without them**. Nothing here is
required — the script has no dependency on a monitoring stack.

`install.sh` creates the directory. To put it elsewhere, or to disable metrics
for one run, set `CANON_SYNC_METRICS_DIR`:

```bash
sudo CANON_SYNC_METRICS_DIR=/tmp/metrics ./camera-sync.sh   # write there instead
sudo CANON_SYNC_METRICS_DIR=/nonexistent ./camera-sync.sh   # no metrics at all
```

`DRY_RUN=1` never writes metrics, so a dry run cannot disturb the numbers.

What is exported: whether a run is in progress and which phase it is in, whether
the camera was reachable and over which transport, files queued/downloaded/
failed for the current run, the pending backlog, cumulative download and failure
counters, run duration, last exit code, and timestamps for the last successful
sync and the last time the camera was seen. Counters survive across runs because
the script reads its own previous `.prom` back at startup — which matters when
most runs are short "no camera" checks that must not reset anything.

To pick these up with node_exporter:

```yaml
command:
  - '--collector.textfile.directory=/textfile'
volumes:
  - /var/lib/node_exporter/textfile_collector:/textfile:ro
```

Logs reach Grafana separately, by pointing promtail's `journal` scrape at the
units (`canon-camera-sync.service`, `canon-camera-sync-wifi.service`,
`canon-camera-watch.service`). A ready-made Grafana dashboard covering both
halves lives in the `Containers/monitoring` stack as `canon-camera-sync.json`.

**If the units are hardened**, the metrics path must be declared writable or the
emitter silently no-ops. `install.sh` already adds both lines; a hand-written
unit with `ProtectSystem=strict` needs them too:

```ini
ReadWritePaths=-/var/lib/node_exporter/textfile_collector
RuntimeDirectory=canon-camera-sync
```

The leading `-` makes the path optional, so a missing directory is skipped
rather than preventing the unit from starting. `RuntimeDirectory=` is unrelated
to metrics but equally necessary: `ProtectSystem=strict` makes all of `/run`
read-only, which would otherwise disable the script's concurrency lock without
any visible symptom.

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
| `camera-sync-wifi.service` | Systemd service for the Wi-Fi (CCAPI) transport — no udev trigger |
| `camera-sync-wifi.timer` | Safety-net timer that re-checks the network every 30 min; ship disabled |
| `canon-camera-watch.py` | SSDP listener — starts a sync when the camera announces itself on the network |
| `canon-camera-watch.service` | Systemd unit for the listener above |

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

### Wi-Fi: `[Camera Control API]` is missing from the camera menu

CCAPI has not been activated. It is a one-time USB step with Canon's Activation
Tool — see [Step 1](#step-1--activate-ccapi-on-the-camera-one-time).

### Wi-Fi: the camera is on the network but nothing answers

Check the camera shows **[Wi-Fi on]** for Camera Control API rather than sitting
in the menu, and that `ccapi_port` matches the **Port No.** on its Camera Control
API screen. Then try the API directly:

```bash
curl -sS http://<camera-ip>:8080/ccapi
```

If the camera cannot be found at all, confirm it is on the same subnet and that
your router does not have **AP/client isolation** enabled, which blocks
wired-to-wireless traffic.

### Why not gphoto2 over Wi-Fi (PTP/IP)?

gphoto2 supports PTP/IP, and it works on older Canon bodies, but Canon's
"Remote control (EOS Utility)" mode on newer ones expects Canon's own EOS Utility
to announce itself first. Verified on an **EOS M50 Mark II**: TCP port 15740
opens and the PTP/IP Init Command Request is accepted, then the camera resets the
connection and reports **Err 11, "connection target not found"** — with every
available driver. Canon's manual states plainly that the EOS software must be
running on the computer. CCAPI is the supported route, which is why this project
uses it.

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
