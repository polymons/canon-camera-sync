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

### Force a re-scan of the card

A run normally starts by asking whether the *card* has changed since last time,
and stops there if it has not. That is the wrong question after the archive
loses files: delete a month locally and the card still reports the same count
and the same last filename, so the run exits believing there is nothing to do
and those photos are never fetched again.

Making that safe automatically would mean walking the whole archive on every
poll — the exact cost that check exists to avoid, on a drive that may be spun
down. So it is an explicit request instead:

```bash
sudo env CAMERA_SYNC_RESCAN=1 /opt/canon-camera-sync/camera-sync.sh
```

Run it after deleting or restoring anything by hand. It compares the card
against what is actually on disk and fetches back whatever is missing.

It does **not** re-download files that are still there: the second check matches
on filename, so a rescan with nothing missing prints `All N files already exist
locally` and transfers nothing. To re-fetch files that *are* present, see
Refresh mode below.

Deleting the state file has the same effect and is still worth knowing about, as
it also resets what the next run considers "already synced":

```bash
# Use the dest_base path from your config.yml
rm /your/photo/destination/.last_sync_count
```

### Refresh mode — re-fetch files to pick up coordinates

This body has no GPS receiver. It records coordinates only while the phone is
feeding them over Bluetooth, so shots taken with that link down get a GPS block
containing no latitude or longitude, and no amount of normal syncing will ever
improve them — they are already in the archive, so the filename check skips them.

Refresh mode re-fetches such files and replaces a local copy **only** when the
card copy genuinely has coordinates it lacks:

```bash
# 1. Go/no-go. Fetches ONE file, reports what each copy has, changes nothing.
sudo env CAMERA_SYNC_REFRESH=probe CAMERA_SYNC_REFRESH_SCOPE=2026/09 \
     /opt/canon-camera-sync/camera-sync.sh

# 2. Only if the probe shows the card is better:
sudo env CAMERA_SYNC_REFRESH=run CAMERA_SYNC_REFRESH_SCOPE=2026/09 \
     /opt/canon-camera-sync/camera-sync.sh
```

`CAMERA_SYNC_REFRESH_SCOPE` is a path prefix relative to `dest_base`, so
`2026/09` is a month and `2026/09/IMG_7037` is one shot and its raw. It is
required for `run` — unscoped, every file in the archive without coordinates
would be a candidate.

| Variable | Default | Meaning |
|---|---|---|
| `CAMERA_SYNC_REFRESH` | unset | `probe` (one file, report only) or `run` |
| `CAMERA_SYNC_REFRESH_SCOPE` | — | path prefix; required for `run` |
| `CAMERA_SYNC_REFRESH_GIVEUP` | `10` | stop after this many card copies in a row turn out to have no coordinates either and nothing has been promoted. `0` disables |

What it will and will not do:

- **Replaces only on a gain.** The card copy must have latitude and longitude
  and the local copy must have none. A copy that is no better is deleted from
  quarantine and the local file is not touched.
- **Never deletes your files.** Every replaced original is hard-linked into
  `.refresh/backup/<timestamp>/` before the new file is moved into place, so the
  live path never stops existing even if the run is killed mid-file.
- **Refuses a shrinking file.** Gaining a GPS block can only make a file bigger.
- **Ignores dot-directories**, so a shot culled into `.deleted/` is never
  resurrected, and previous backups are never re-processed.
- **Skips videos** and anything that is not a JPG or CR3.
- **Fetches nothing new.** Files on the card that are not in the archive are
  reported and left for a normal sync.
- **Writes neither the state file nor the metrics**, for the same reason
  `DRY_RUN` does not: it collects no new photos, and stamping "up to date" for a
  listing it never worked through would make the next run skip real files.
- **Resumes for free.** A replaced file now has coordinates, so it is no longer
  a candidate; re-run the same command to continue.

Downloads land in `.refresh/incoming/` and are cleared at the start of each run.
Both directories sit inside `dest_base` on purpose: dot-prefixed so Immich's
crawler ignores them, and inside the tree because the systemd unit's
`ReadWritePaths=` grants write access to nothing else.

Promoted files get their mtime bumped. Immich decides whether to re-read EXIF by
comparing mtime, and external assets are hashed by path rather than content, so
a file arriving with the camera's original timestamp would keep its stale
metadata for ever. After a refresh, an ordinary library scan is enough.

### Geotag review — automatic, event-driven backfill

Refresh mode above is the manual, scoped version of this. The **geotag review**
is the automatic one, and it is what makes late-arriving coordinates a solved
problem rather than something to remember to go and fix.

The camera gets location from the phone over Bluetooth. That link is often down
when the shutter fires, and the coordinates can be merged onto the card
afterwards — sometimes long after the archive already holds a copy of the file.
Nothing in a normal sync notices, because the "is this file missing?" test is
basename-only: a file that is already here is never looked at again, whatever
happened to the card copy since.

The review runs at the end of an ordinary sync, so **every event that already
starts one also asks this question** — the udev rule when a cable goes in,
`canon-camera-watch.service` when the camera announces itself over Wi-Fi, and
the 30-minute timer as a backstop. Nothing new needs to be scheduled.

#### What makes it affordable

A ledger at `dest_base/.geo/ledger.tsv` records what each file looked like, both
locally and on the card, the last time it was examined. A file whose local copy
is unchanged and whose card-side size and timestamp are unchanged cannot have
gained anything, and is skipped for nothing. In the steady state an event costs
a listing comparison and no traffic at all.

Four tiers, cheapest first, and nothing is ever ruled out on a weak signal:

| Tier | Cost | What it does |
|---|---|---|
| the listing | free | which archived files are still on the card |
| whole-KB sizes | free, **USB only** | a *changed* KB figure is definite evidence; an unchanged one proves nothing (see below) |
| exact size and mtime | ~200 B per file | `?kind=info` over Wi-Fi, one batched `--show-info` over USB. The real change detector |
| the GPS answer | 256 KiB, or a whole file | only for files the tier above could not settle |

The 256 KiB figure is exact, not a heuristic: `has_gps` reads exactly that many
bytes and cannot see past them, so an `HTTP Range` request the same length gives
the same verdict as the complete file. Where the camera serves Range, settling
this archive's whole backlog costs a few hundred megabytes instead of tens of
gigabytes. Where it does not, the review says so in the log and drops to a much
smaller per-event budget.

> **The USB whole-KB signal is statistical, not per-file.** A GPS merge adds
> only ~100–200 bytes, which crosses a whole-KB boundary about one time in six.
> So it is only ever used to move a file *into* the queue, never to rule one
> out — and across a card it is a reliable hint that something rewrote the files.

#### It does not assume the camera can help

Whether this body writes coordinates onto a card file after capture is an
empirical question, and on this archive 93% of stills have a GPS block with no
latitude or longitude in it. A single miss therefore proves nothing — it is the
base rate. So the ledger tracks a **premise**:

- `unknown` — spend at most `geo_probe_files` (5) checks per event, no more;
- `proven` — something has actually been found; the full budget unlocks;
- `disproven` — `geo_giveup` (25) checks have found nothing at all. Stop. Events
  after this cost only a metadata probe, which is nearly free.

A written-off premise is not a dead end. It reopens the moment there is evidence:
a card file whose size or timestamp has changed, several whole-KB sizes moving at
once over USB, or `CAMERA_SYNC_GEO=rearm` by hand. So the worst case for a camera
that never re-tags anything is a handful of wasted checks, once — and if that
ever changes, the next event notices.

#### What it will and will not do

- **Promotion goes through the same `refresh_commit`** as manual refresh mode,
  with the same guarantees: replaces only on a genuine coordinate gain, refuses
  a card copy smaller than the local file, and hard-links the original into
  `.refresh/backup/<timestamp>/` before anything overwrites it.
- **A 256 KiB sniff is never installed.** It answers the question; the file that
  replaces a photo is always fetched in full.
- **It cannot fail a sync.** It runs after the state file is written and after
  the run is already recorded as a success, and every error path inside it is
  non-fatal. A run that aborted collecting new photos never reaches it at all.
- **Files the camera no longer holds are reported, not attempted.** They are
  counted, and listed one path per line in `dest_base/.geo/unreachable.txt` at
  the end of each completed pass. Only a recorded GPS track can fix those, and
  that file is the input list for doing it.
- **Budgets bound every event** and the ledger is the resume point, so a large
  backlog drains over several camera-online events instead of one long run.

#### Configuration

Every key is optional; the defaults below apply if it is absent. Each also has a
`CAMERA_SYNC_GEO_*` environment override.

```yaml
geo_review: auto              # auto | off | force
geo_budget_files_usb: 150     # a cable connect is deliberate, so it gets more
geo_budget_files_ccapi: 400   # with Range: 400 x 256 KiB = 100 MB per event
geo_budget_files_ccapi_full: 20   # without Range, every check is a whole file
geo_budget_seconds_usb: 900
geo_budget_seconds_ccapi: 300
geo_probe_files: 5            # checks per event while the premise is unknown
geo_giveup: 25                # checks with no result before writing it off
geo_rearm_probe_files: 25     # metadata probes per event while written off
geo_rearm_kb_threshold: 3     # changed whole-KB sizes that reopen it (USB)
geo_min_interval_seconds: 3600
geo_range_recheck_days: 30
geo_ledger_max_rows: 20000
geo_show_info_batch: 1        # 0 if --show-info misbehaves on your firmware
```

`CAMERA_SYNC_GEO` overrides `geo_review` and adds three operator verbs:

```bash
# What would this event look at, and why? Fetches nothing, writes nothing.
sudo env CAMERA_SYNC_GEO=plan /opt/canon-camera-sync/camera-sync.sh

# Where does the archive stand? Touches neither the camera nor the archive.
sudo env CAMERA_SYNC_GEO=status /opt/canon-camera-sync/camera-sync.sh

# Reopen a written-off premise and make every settled file a candidate again.
sudo env CAMERA_SYNC_GEO=rearm /opt/canon-camera-sync/camera-sync.sh
```

To start completely over, delete `dest_base/.geo/ledger.tsv`. Rebuilding it costs
budget, never data.

#### Monitoring

The review exports `canon_sync_geo_*` metrics alongside the sync's own, and the
Grafana dashboard carries a **Geotag review** row: the premise, whether partial
downloads are available, a coverage donut over the whole archive, what each
event's review did, and the bytes it pulled per hour — which is the panel to
watch if you suspect it is being expensive.

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

`DRY_RUN=1` and `CAMERA_SYNC_REFRESH` never write metrics, so neither a dry
run nor a refresh can disturb the numbers.

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
