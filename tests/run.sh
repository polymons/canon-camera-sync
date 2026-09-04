#!/bin/bash
# Test suite for camera-sync.sh.
#
# Plain bash asserts and no framework, matching a project whose only
# dependencies are bash, python3, curl and gphoto2. Run from anywhere:
#
#   ./tests/run.sh                 everything that needs no camera
#   ./tests/run.sh --with-archive  also check the parser against the real
#                                  photo archive named in config.yml
#
# The camera-facing tests use the script's own offline seam
# (CAMERA_SYNC_GEO_FAKE_CARD), so the review runs end to end — classification,
# budgets, promotion through refresh_commit with its real backups and its real
# GPS re-check, ledger writes, metrics — against a directory of real images
# standing in for the card.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$ROOT/camera-sync.sh"
WITH_ARCHIVE=0
[[ "${1:-}" == "--with-archive" ]] && WITH_ARCHIVE=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
GROUP=""

group() { GROUP="$1"; printf '\n\033[1m%s\033[0m\n' "$1"; }
ck() {
    local what="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        PASS=$(( PASS + 1 )); printf '  \033[32mok\033[0m   %s\n' "$what"
    else
        FAIL=$(( FAIL + 1 )); printf '  \033[31mFAIL\033[0m %s\n       got:  %s\n       want: %s\n' "$what" "$got" "$want"
    fi
}
ck_contains() {
    local what="$1" hay="$2" needle="$3"
    if [[ "$hay" == *"$needle"* ]]; then
        PASS=$(( PASS + 1 )); printf '  \033[32mok\033[0m   %s\n' "$what"
    else
        FAIL=$(( FAIL + 1 )); printf '  \033[31mFAIL\033[0m %s\n       expected to contain: %s\n       in:\n%s\n' "$what" "$needle" "$hay"
    fi
}

# Pull a self-contained region of the script into a file that can be sourced.
# Keeps the unit tests honest: they exercise the shipped code rather than a copy.
extract() { sed -n "/$1/,/$2/p" "$SCRIPT"; }

# ───────────────────────────────────────────────────────────────────────────────
group "static checks"
bash -n "$SCRIPT" 2>&1 && ck "camera-sync.sh parses" "$?" "0" || ck "camera-sync.sh parses" "fail" "0"
for f in "$ROOT"/*.sh; do bash -n "$f" 2>/dev/null || ck "$(basename "$f") parses" fail ok; done
python3 -c "import ast,sys; ast.parse(open('$ROOT/canon-camera-watch.py').read())" \
    && ck "canon-camera-watch.py parses" ok ok || ck "canon-camera-watch.py parses" fail ok
if command -v shellcheck >/dev/null; then
    out=$(shellcheck -S error -x "$SCRIPT" 2>&1); ck "shellcheck (errors)" "$out" ""
else
    printf '  \033[33mskip\033[0m shellcheck not installed\n'
fi

# ───────────────────────────────────────────────────────────────────────────────
group "has_gps / has_gps_batch"
GPSLIB="$WORK/gps.sh"
{ sed -n '/^# ─── GPS coordinates ───/,/^has_gps_batch() {/p' "$SCRIPT"
  printf '    python3 -c "$GPS_PY" 2>/dev/null\n}\n'; } > "$GPSLIB"
bash -n "$GPSLIB" && ck "GPS block extracts cleanly" ok ok || ck "GPS block extracts cleanly" fail ok
# shellcheck disable=SC1090
source "$GPSLIB"

# A minimal JPEG carrying a GPS IFD with real coordinates, and one whose GPS
# IFD is present but empty — the state the body writes with the phone link down,
# and the single distinction this whole feature turns on.
python3 - "$WORK" <<'PY'
import struct, sys, os
out = sys.argv[1]

def tiff(entries, extra_at, extra):
    # little-endian TIFF: header, one IFD, then the rational payloads
    ifd = struct.pack("<H", len(entries))
    for tag, typ, cnt, val in entries:
        ifd += struct.pack("<HHI", tag, typ, cnt) + val
    ifd += struct.pack("<I", 0)
    return b"II" + struct.pack("<HI", 42, 8) + ifd + b"\x00" * (extra_at - (8 + len(ifd))) + extra

def rational(*vals):
    return b"".join(struct.pack("<II", n, d) for n, d in vals)

# GPS IFD holding latitude and longitude at a known offset
payload_at = 200
lat = rational((47, 1), (29, 1), (42, 1))
lon = rational((19, 1), (3, 1), (30, 1))
full = [
    (0x00, 1, 4, b"\x02\x03\x00\x00"),
    (0x01, 2, 2, b"N\x00\x00\x00"),
    (0x02, 5, 3, struct.pack("<I", payload_at)),
    (0x03, 2, 2, b"E\x00\x00\x00"),
    (0x04, 5, 3, struct.pack("<I", payload_at + len(lat))),
]
# the same block minus the coordinates: version, ref and status only
empty = [
    (0x00, 1, 4, b"\x02\x03\x00\x00"),
    (0x01, 2, 2, b"N\x00\x00\x00"),
    (0x09, 2, 2, b"V\x00\x00\x00"),
]

def jpeg(gps_entries, payload):
    gps = tiff(gps_entries, payload_at, payload)
    # IFD0 with a single GPSInfo pointer at 0x8825
    ifd0_at = 8
    ifd0 = struct.pack("<H", 1) + struct.pack("<HHI", 0x8825, 4, 1, ) + b""
    # build by hand: pointer value is the GPS IFD offset within the TIFF block
    gps_off = 100
    ifd0 = struct.pack("<H", 1) + struct.pack("<HHI", 0x8825, 4, 1) + struct.pack("<I", gps_off) + struct.pack("<I", 0)
    head = b"II" + struct.pack("<HI", 42, ifd0_at)
    blob = head + ifd0
    blob += b"\x00" * (gps_off - len(blob))
    inner = struct.pack("<H", len(gps_entries))
    for tag, typ, cnt, val in gps_entries:
        inner += struct.pack("<HHI", tag, typ, cnt) + val
    inner += struct.pack("<I", 0)
    blob += inner
    blob += b"\x00" * (payload_at - len(blob))
    blob += payload
    # A capture date in the plain ASCII form exif_year_month looks for. Without
    # it a fetch has no month to file the file under and is discarded, which is
    # correct behaviour but makes these fixtures untestable through that path.
    return (b"\xff\xd8\xff\xe1" + struct.pack(">H", len(blob) + 8) + b"Exif\x00\x00"
            + blob + b"2026:09:04 12:00:00\x00" + b"\xff\xd9")

open(os.path.join(out, "gps.jpg"), "wb").write(jpeg(full, lat + lon))
open(os.path.join(out, "nogps.jpg"), "wb").write(jpeg(empty, b""))
open(os.path.join(out, "junk.bin"), "wb").write(b"not an image at all" * 10)
PY

coords=$(has_gps "$WORK/gps.jpg") && rc=0 || rc=$?
ck "coordinates present -> rc 0" "$rc" "0"
ck "coordinates decoded"        "$coords" "47.495000,19.058333"
has_gps "$WORK/nogps.jpg" >/dev/null && rc=0 || rc=$?
ck "GPS block present but empty -> rc 1" "$rc" "1"
has_gps "$WORK/junk.bin" >/dev/null && rc=0 || rc=$?
ck "unparseable container -> rc 2" "$rc" "2"
has_gps "$WORK/does-not-exist" >/dev/null && rc=0 || rc=$?
ck "missing file -> rc 2" "$rc" "2"

res=$(printf '%s\0' "$WORK/gps.jpg" "$WORK/nogps.jpg" "$WORK/junk.bin" | has_gps_batch)
ck "batch returns one line per input" "$(wc -l <<<"$res")" "3"
ck "batch codes in order"  "$(cut -f1 <<<"$res" | tr '\n' ' ')" "0 1 2 "
# The empty-coords field is last on purpose: tab is an IFS whitespace character,
# so bash `read` collapses a run of tabs and an empty middle field would shift
# the path out of position for every file without coordinates.
ck "batch echoes the path back in field 2" \
   "$(cut -f2 <<<"$res" | tr '\n' ' ')" "$WORK/gps.jpg $WORK/nogps.jpg $WORK/junk.bin "

# The cost model for the whole feature rests on this: has_gps reads 262144 bytes
# and cannot see further, so a 256 KiB Range request is not an approximation of
# the test, it is the test.
head -c 262144 "$WORK/gps.jpg" > "$WORK/sniff.bin"
a=$(has_gps "$WORK/gps.jpg") && ra=0 || ra=$?
b=$(has_gps "$WORK/sniff.bin") && rb=0 || rb=$?
ck "first 256 KiB gives the same verdict as the whole file" "$ra/$a" "$rb/$b"

# ───────────────────────────────────────────────────────────────────────────────
group "json_file_info"
JLIB="$WORK/jfi.sh"
sed -n '/^json_file_info() {/,/^}/p' "$SCRIPT" > "$JLIB"
# shellcheck disable=SC1090
source "$JLIB"
ck "HTTP-date and a 'filesize' key" \
  "$(echo '{"name":"IMG_7037.JPG","filesize":7717483,"lastmodifieddate":"Thu, 03 Sep 2026 17:31:58 GMT"}' | json_file_info)" \
  "$(printf '7717483\t%s' "$(date -u -d 'Thu, 03 Sep 2026 17:31:58 GMT' +%s)")"
ck "EXIF-style date and a size given as a string" \
  "$(echo '{"filename":"a","size":"21000000","datetime":"2026:09:04 21:22:11"}' | json_file_info)" \
  "$(printf '21000000\t%s' "$(date -d '2026-09-04 21:22:11' +%s)")"
ck "nested, ISO date, boolean under a size-ish key ignored" \
  "$(echo '{"contents":[{"meta":{"bytes":123456,"cacheable":true,"modified":"2026-01-02T03:04:05"}}]}' | json_file_info)" \
  "$(printf '123456\t%s' "$(date -d '2026-01-02 03:04:05' +%s)")"
ck "nothing usable -> zeroes, not an error" "$(echo '{"a":"b"}' | json_file_info)" "$(printf '0\t0')"
echo 'not json' | json_file_info >/dev/null 2>&1 && rc=0 || rc=1
ck "malformed JSON fails" "$rc" "1"

# ───────────────────────────────────────────────────────────────────────────────
group "geo_show_info_usb (gphoto2 --show-info parsing)"
SILIB="$WORK/si.sh"
sed -n '/^# Held in variables rather than written inline/,/^}/p' "$SCRIPT" > "$SILIB"
declare -A GEO_CARD_BYTES=()
GEO_SHOW_INFO_BATCH=1
# shellcheck disable=SC1090
source "$SILIB"
cat > "$WORK/showinfo.txt" <<'OUT'
Information on file 'IMG_7037.JPG' (folder '/store_00010001/DCIM/100CANON'):
File:
  Mime type:     'image/jpeg'
  Size:          7717483 byte(s)
  Width:         6000 pixel(s)
Information on file '_MG_7038.CR3' (folder '/store_00010001/DCIM/100CANON'):
File:
  Size:          21004512 byte(s)
OUT
gphoto2() { cat "$FAKE_SHOW_INFO"; }
FAKE_SHOW_INFO="$WORK/showinfo.txt" geo_show_info_usb 1 2 >/dev/null
ck "exact size for a JPG"          "${GEO_CARD_BYTES[IMG_7037.JPG]:-}" "7717483"
ck "exact size for a CR3"          "${GEO_CARD_BYTES[_MG_7038.CR3]:-}" "21004512"
ck "only the two files are parsed" "${#GEO_CARD_BYTES[@]}" "2"
: > "$WORK/empty.txt"
FAKE_SHOW_INFO="$WORK/empty.txt" geo_show_info_usb 1 2 >/dev/null && rc=0 || rc=1
ck "unparseable output reports failure" "$rc" "1"
GEO_SHOW_INFO_BATCH=0
FAKE_SHOW_INFO="$WORK/showinfo.txt" geo_show_info_usb 1 2 >/dev/null && rc=0 || rc=1
ck "disabled by config reports failure" "$rc" "1"
GEO_SHOW_INFO_BATCH=1

# ───────────────────────────────────────────────────────────────────────────────
group "geotag ledger"
LLIB="$WORK/ledger.sh"
{ sed -n '/^# ─── Geotag ledger ───/,/^LAST_DEST_DIR=""/p' "$SCRIPT" | head -n -2; } > "$LLIB"
GEO_NAME=".geo"; GEO_DIR="$WORK/led"; GEO_LEDGER="$GEO_DIR/ledger.tsv"
GEO_LEDGER_MAX_ROWS=20000; GEO_MODE=auto; GEO_MIN_INTERVAL=3600; GEO_REARM_PROBE_FILES=25
mkdir -p "$GEO_DIR"
# shellcheck disable=SC1090
source "$LLIB"

geo_row_read X.JPG || true
GR_LGPS=no; GR_LBYTES=7717483; GR_LMTIME=1772000000; GR_REL="2026/09/X.JPG"
GR_CSTATE=settled; GR_CBYTES=7717483; GR_CKB=7536; GR_CMTIME=1772000001
GR_CHECKED=1780000000; GR_ATTEMPTS=0; geo_row_write X.JPG
geo_row_read "a b.JPG" || true
GR_LGPS=yes; GR_REL="2022/01/a b.JPG"; GR_CSTATE=offcard; GR_CHECKED=1; geo_row_write "a b.JPG"
GEO_PREMISE=proven; GEO_HITS=4; GEO_MISSES=9; GEO_RANGE_CCAPI=yes; GEO_RANGE_TS=1779999999
GEO_CURSOR="Z.JPG"; GEO_LAST_PASS_TS=1780000001
geo_ledger_save
first="$(cat "$GEO_LEDGER")"

GEO_ROW=(); GEO_PREMISE=unknown; GEO_HITS=0; GEO_MISSES=0; GEO_RANGE_CCAPI=unknown
GEO_RANGE_TS=0; GEO_CURSOR=""; GEO_LAST_PASS_TS=0
geo_ledger_load
ck "header round-trips: premise"      "$GEO_PREMISE" "proven"
ck "header round-trips: hits"         "$GEO_HITS" "4"
ck "header round-trips: range"        "$GEO_RANGE_CCAPI" "yes"
ck "header round-trips: cursor"       "$GEO_CURSOR" "Z.JPG"
ck "header round-trips: last_pass_ts" "$GEO_LAST_PASS_TS" "1780000001"
ck "row count"                        "${#GEO_ROW[@]}" "2"
geo_row_read X.JPG
ck "row round-trips: local_gps"   "$GR_LGPS"     "no"
ck "row round-trips: local_bytes" "$GR_LBYTES"   "7717483"
ck "row round-trips: card_state"  "$GR_CSTATE"   "settled"
ck "row round-trips: card_kb"     "$GR_CKB"      "7536"
ck "row round-trips: card_mtime"  "$GR_CMTIME"   "1772000001"
geo_row_read "a b.JPG"
ck "a space in the path survives" "$GR_REL" "2022/01/a b.JPG"
geo_row_read NOPE.JPG && rc=0 || rc=1
ck "unknown name reports absent"        "$rc" "1"
ck "unknown name yields new-row values" "$GR_CSTATE/$GR_LGPS" "new/unknown"

GEO_LEDGER_DIRTY=1; geo_ledger_save
strip() { sed 's/\tupdated=[0-9]*//'; }
ck "save is deterministic" "$(strip <<<"$(cat "$GEO_LEDGER")")" "$(strip <<<"$first")"

printf 'garbage\nX.JPG\tno\t1\t1\tr\tsettled\t1\t1\t1\t1\t0\n' > "$GEO_LEDGER"
GEO_ROW=(); geo_ledger_load >/dev/null
ck "unrecognised header rebuilds from scratch" "${#GEO_ROW[@]}" "0"

{ printf '#geo1\tpremise=unknown\thits=0\tmisses=0\trange_ccapi=no\trange_ts=0\tcursor=\tlast_pass_ts=0\tupdated=1\n'
  printf 'GOOD1.JPG\tno\t1\t1\tr1\tnew\t0\t0\t0\t0\t0\n'
  printf 'SHORT.JPG\tno\t1\t1\n'
  printf 'GOOD2.JPG\tno\t1\t1\tr2\tnew\t0\t0\t0\t0\t0\n'; } > "$GEO_LEDGER"
GEO_ROW=(); geo_ledger_load
ck "a malformed row is dropped, its neighbours survive" "${#GEO_ROW[@]}" "2"
ck "header still parsed alongside it" "$GEO_RANGE_CCAPI" "no"

GEO_ROW=(); GEO_LEDGER_MAX_ROWS=2
while read -r nm st ts; do
    geo_row_read "$nm" || true; GR_CSTATE="$st"; GR_CHECKED="$ts"; geo_row_write "$nm"
done <<'ROWS'
K1.JPG settled 100
K2.JPG offcard 50
K3.JPG geotagged 10
ROWS
geo_ledger_save >/dev/null
GEO_ROW=(); GEO_LEDGER_MAX_ROWS=20000; geo_ledger_load
ck "over-cap ledger is trimmed to the cap"    "${#GEO_ROW[@]}" "2"
ck "the re-derivable row is what got dropped" "${GEO_ROW[K2.JPG]+present}" ""
ck "a row carrying a decision is kept"        "${GEO_ROW[K3.JPG]+present}" "present"

now=$(date +%s)
GEO_MODE=off;   geo_wants_run 1 && rc=0 || rc=1; ck "geo_review off -> no run" "$rc" "1"
GEO_MODE=force; geo_wants_run 1 && rc=0 || rc=1; ck "force -> run"             "$rc" "0"
GEO_MODE=auto
printf '#geo1\tpremise=proven\thits=1\tmisses=0\trange_ccapi=yes\trange_ts=0\tcursor=\tlast_pass_ts=%s\tupdated=1\n' "$now" > "$GEO_LEDGER"
geo_wants_run 1 && rc=0 || rc=1; ck "recent full pass, nothing new -> no run" "$rc" "1"
geo_wants_run 0 && rc=0 || rc=1; ck "recent full pass, but photos arrived -> run" "$rc" "0"
printf '#geo1\tpremise=disproven\thits=0\tmisses=25\trange_ccapi=no\trange_ts=0\tcursor=\tlast_pass_ts=0\tupdated=1\n' > "$GEO_LEDGER"
GEO_REARM_PROBE_FILES=0;  geo_wants_run 1 && rc=0 || rc=1; ck "disproven with no re-arm budget -> no run" "$rc" "1"
GEO_REARM_PROBE_FILES=25; geo_wants_run 1 && rc=0 || rc=1; ck "disproven but re-armable -> run"           "$rc" "0"

# ───────────────────────────────────────────────────────────────────────────────
# End-to-end: a real archive and a real "card", both directories of real image
# files, driven through the shipped script via its offline seam.
group "geotag review, end to end"

E2E="$WORK/e2e"
mkdir -p "$E2E/bin" "$E2E/metrics"
cp "$SCRIPT" "$E2E/bin/"
cat > "$E2E/bin/config.yml" <<CFG
dest_base: $E2E/archive
owner_user: $(id -un)
owner_group: $(id -gn)
camera_vendor_id: "04a9"
camera_product_id: "32f9"
camera_detect_name: canon
script_dir: $E2E/bin
pre_delay_seconds: 0
transport: ccapi
camera_mac: "74:38:b7:e2:73:5f"
ccapi_port: 8080
CFG

# Three image bodies: with coordinates, without, and without-but-larger. Sizes
# matter as much as content — refresh_commit refuses to replace a local file
# with a smaller card copy, and that refusal is one of the things under test.
mkfix() {
    python3 - "$WORK" "$1" "$2" "$3" <<'PY'
import struct, sys
out, path, kind, pad = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
src = "gps.jpg" if kind == "gps" else "nogps.jpg"
data = open(f"{out}/{src}", "rb").read()
# Pad after EOI: the parser only ever reads the header, so this changes the
# file's size without changing its verdict — which is exactly how a real image
# of a different size behaves here.
open(path, "wb").write(data + b"\x00" * pad)
PY
}

reset_e2e() {
    rm -rf "$E2E/archive" "$E2E/card" "$E2E/metrics"
    mkdir -p "$E2E/archive/2026/09" "$E2E/card" "$E2E/metrics"
}
run_e2e() {
    ( cd "$E2E" && env CAMERA_SYNC_GEO_FAKE_CARD="$E2E/card" \
        CANON_SYNC_METRICS_DIR="$E2E/metrics" \
        CAMERA_SYNC_GEO_MIN_INTERVAL_SECONDS=0 \
        "$@" bash "$E2E/bin/camera-sync.sh" 2>&1 | grep -v '^TEST SEAM' )
}

# ── promotion, refusal, off-card, already-tagged ──────────────────────────────
reset_e2e
mkfix "$E2E/archive/2026/09/A.JPG"   nogps 1000    # no coordinates, small
mkfix "$E2E/archive/2026/09/B.JPG"   gps   0       # already geotagged
mkfix "$E2E/archive/2026/09/C.JPG"   nogps 2000    # no coordinates
mkfix "$E2E/archive/2026/09/D.JPG"   nogps 500     # no coordinates, not on the card
mkfix "$E2E/archive/2026/09/E.JPG"   nogps 9000    # no coordinates, large
mkfix "$E2E/card/A.JPG"              gps   5000    # coordinates, larger  -> promote
mkfix "$E2E/card/B.JPG"              gps   0
mkfix "$E2E/card/C.JPG"              nogps 2000    # identical             -> settled
mkfix "$E2E/card/E.JPG"              gps   1000    # coordinates but smaller -> refuse

out=$(run_e2e CAMERA_SYNC_GEO_GIVEUP=0)
ck_contains "classifies the already-geotagged file"  "$out" "1 already have coordinates."
ck_contains "counts the candidates"                  "$out" "3 candidate(s) without coordinates"
ck_contains "counts what the camera cannot help with" "$out" "1 without coordinates and no longer on the card"
ck_contains "promotes the file that gained coordinates" "$out" "A.JPG: 47.495000,19.058333 — replaced"
ck_contains "refuses a card copy smaller than the local file" "$out" "refusing to replace a larger local file"
ck_contains "reports the run"                        "$out" "1 promoted"

ck "the promoted file now carries coordinates" \
   "$(has_gps "$E2E/archive/2026/09/A.JPG")" "47.495000,19.058333"
ck "the refused file is untouched" \
   "$(has_gps "$E2E/archive/2026/09/E.JPG" >/dev/null; echo $?)" "1"
ck "the original was kept" \
   "$(find "$E2E/archive/.refresh/backup" -name 'A.JPG' | wc -l)" "1"
ck "files the camera cannot fix are listed for a track-based pass" \
   "$(cat "$E2E/archive/.geo/unreachable.txt")" "2026/09/D.JPG"
ck "a partial download never lands in the archive" \
   "$(find "$E2E/archive" -name '*.JPG' -not -path '*/.geo/*' -not -path '*/.refresh/*' | wc -l)" "5"

# ── the ledger makes repeat events free ──────────────────────────────────────
# The promoted file is re-read before the run ends, which both confirms the
# coordinates really landed on disk and leaves nothing stale for next time.
ck "a promotion is confirmed by re-reading the file it wrote" \
   "$(grep -c 'Reading coordinates from 1 local file' <<<"$out")" "1"
out=$(run_e2e CAMERA_SYNC_GEO_GIVEUP=0)
ck "second event reads nothing locally" \
   "$(grep -c 'Reading coordinates from' <<<"$out")" "0"
ck_contains "and checks nothing against the card"     "$out" "0 checked"
ck "steady state costs no downloads" \
   "$(grep '^canon_sync_geo_run_bytes ' "$E2E/metrics/canon_camera_sync.prom" | awk '{print $2}')" "0"

# ── the point of the whole feature: a card file rewritten after the fact ─────
reset_e2e
mkfix "$E2E/archive/2026/09/P.JPG" nogps 100
mkfix "$E2E/card/P.JPG"            nogps 100
run_e2e CAMERA_SYNC_GEO_GIVEUP=0 >/dev/null
ck "a file the card cannot improve is settled" \
   "$(awk -F'\t' '$1=="P.JPG"{print $6}' "$E2E/archive/.geo/ledger.tsv")" "settled"
# the camera merges location onto the card copy, long after we synced it
mkfix "$E2E/card/P.JPG" gps 4000
out=$(run_e2e CAMERA_SYNC_GEO_GIVEUP=0)
ck_contains "notices the card copy changed"        "$out" "P.JPG changed on the card since it was last checked"
ck_contains "acts on it in the same event"         "$out" "P.JPG: 47.495000,19.058333 — replaced"
ck "the archive copy now has coordinates" \
   "$(has_gps "$E2E/archive/2026/09/P.JPG")" "47.495000,19.058333"

# ── the premise ladder ───────────────────────────────────────────────────────
reset_e2e
for i in $(seq 1 12); do
    mkfix "$E2E/archive/2026/09/L$i.JPG" nogps "$i"
    mkfix "$E2E/card/L$i.JPG"            nogps "$i"
done
ladder() { run_e2e CAMERA_SYNC_GEO_GIVEUP=5 CAMERA_SYNC_GEO_PROBE_FILES=3; }
o1=$(ladder); o2=$(ladder); o3=$(ladder)
ck_contains "an unproven premise spends only a probe's worth" "$o1" "Checking 3 of 12"
ck_contains "and writes itself off once it has seen enough"   "$o2" "Writing the premise off"
ck_contains "after which events cost nothing"                 "$o3" "left alone: the premise is disproven"
ck "premise recorded in the ledger" \
   "$(head -1 "$E2E/archive/.geo/ledger.tsv" | tr '\t' '\n' | grep '^premise=')" "premise=disproven"
# evidence arrives: one card file is rewritten
mkfix "$E2E/card/L7.JPG" gps 4000
o4=$(ladder)
ck_contains "a changed card file reopens the premise" "$o4" "L7.JPG changed on the card"
ck_contains "and the file is backfilled"              "$o4" "L7.JPG: 47.495000,19.058333 — replaced"
ck "premise is proven once something is actually found" \
   "$(head -1 "$E2E/archive/.geo/ledger.tsv" | tr '\t' '\n' | grep '^premise=')" "premise=proven"

# ── budgets bound an event and the next one resumes ──────────────────────────
reset_e2e
for i in $(seq 1 8); do
    mkfix "$E2E/archive/2026/09/Q$i.JPG" nogps "$i"
    mkfix "$E2E/card/Q$i.JPG"            nogps "$i"
done
b1=$(run_e2e CAMERA_SYNC_GEO_GIVEUP=0 CAMERA_SYNC_GEO_BUDGET_FILES_CCAPI=3)
ck_contains "an event stops on its budget" "$b1" "Stopped on this event's budget"
n1=$(grep -c 'checked' <<<"$b1")
b2=$(run_e2e CAMERA_SYNC_GEO_GIVEUP=0 CAMERA_SYNC_GEO_BUDGET_FILES_CCAPI=3)
b3=$(run_e2e CAMERA_SYNC_GEO_GIVEUP=0 CAMERA_SYNC_GEO_BUDGET_FILES_CCAPI=3)
b4=$(run_e2e CAMERA_SYNC_GEO_GIVEUP=0 CAMERA_SYNC_GEO_BUDGET_FILES_CCAPI=3)
ck_contains "and the next resumes where it stopped" "$b3" "2 checked"
ck_contains "until there is nothing left to do"     "$b4" "0 checked"

# ── no partial downloads: falls back to a much smaller budget ────────────────
reset_e2e
for i in $(seq 1 8); do
    mkfix "$E2E/archive/2026/09/R$i.JPG" nogps "$i"
    mkfix "$E2E/card/R$i.JPG"            nogps "$i"
done
r=$(run_e2e CAMERA_SYNC_GEO_GIVEUP=0 CAMERA_SYNC_GEO_FAKE_RANGE=no CAMERA_SYNC_GEO_BUDGET_FILES_CCAPI_FULL=2)
ck_contains "records that the camera serves no partial downloads" "$r" "partial downloads = no"
ck_contains "and drops to the whole-file budget"                  "$r" "Checking 2 of 8"

# ── USB ──────────────────────────────────────────────────────────────────────
reset_e2e
for i in $(seq 1 4); do
    mkfix "$E2E/archive/2026/09/U$i.JPG" nogps "$i"
    mkfix "$E2E/card/U$i.JPG"            nogps "$i"
done
u1=$(run_e2e CAMERA_SYNC_GEO_GIVEUP=0 CAMERA_SYNC_GEO_FAKE_TRANSPORT=usb)
ck_contains "USB settles its candidates" "$u1" "4 checked"
mkfix "$E2E/card/U2.JPG" gps 400000    # a whole-KB change, visible for free
u2=$(run_e2e CAMERA_SYNC_GEO_GIVEUP=0 CAMERA_SYNC_GEO_FAKE_TRANSPORT=usb)
ck_contains "USB notices a card file changed size" "$u2" "U2.JPG: 47.495000,19.058333 — replaced"

# ── files deleted from the archive are fetched again ─────────────────────────
# The quick exit asks only whether the card changed, so a month deleted locally
# leaves it believing there is nothing to do. CAMERA_SYNC_RESCAN=1 is the way to
# say "compare against what is actually on disk".
reset_e2e
for i in 1 2 3; do
    mkfix "$E2E/archive/2026/09/S$i.JPG" gps "$i"
    mkfix "$E2E/card/S$i.JPG"            gps "$i"
done
run_e2e CAMERA_SYNC_GEO=off >/dev/null            # establishes the state file
ck "state file records the card" "$(cat "$E2E/archive/.last_sync_count")" "3:S3.JPG"
rm -f "$E2E/archive/2026/09/S2.JPG"
out=$(run_e2e CAMERA_SYNC_GEO=off)
ck_contains "without a rescan the deletion goes unnoticed" "$out" "No new files"
ck "and the file stays missing" "$(ls "$E2E/archive/2026/09/S2.JPG" 2>/dev/null | wc -l)" "0"
out=$(run_e2e CAMERA_SYNC_GEO=off CAMERA_SYNC_RESCAN=1)
ck_contains "a rescan says what it is doing"   "$out" "Rescan requested"
ck_contains "and fetches the missing file"     "$out" "Downloading 1 new file"
ck "the deleted file is back" "$(ls "$E2E/archive/2026/09/S2.JPG" 2>/dev/null | wc -l)" "1"
ck "and it is the file that was deleted" \
   "$(has_gps "$E2E/archive/2026/09/S2.JPG")" "47.495000,19.058333"
out=$(run_e2e CAMERA_SYNC_GEO=off CAMERA_SYNC_RESCAN=1)
ck_contains "a second rescan has nothing to do" "$out" "All 3 files already exist locally"

# ── operator verbs ───────────────────────────────────────────────────────────
p=$(run_e2e CAMERA_SYNC_GEO=plan)
ck_contains "plan says what it would do" "$p" "PLAN: would examine"
before=$(md5sum < "$E2E/archive/.geo/ledger.tsv")
s=$(run_e2e CAMERA_SYNC_GEO=status)
ck_contains "status reports the archive" "$s" "Geotag review:"
off=$(run_e2e CAMERA_SYNC_GEO=off)
ck "geo_review off does not run the review" "$(grep -c 'Geotag review:' <<<"$off")" "0"

# ── metrics stay parseable ───────────────────────────────────────────────────
group "metrics"
prom="$E2E/metrics/canon_camera_sync.prom"
ck "geo series are emitted" "$(grep -c '^canon_sync_geo_' "$prom")" "$(grep -c '^canon_sync_geo_' "$prom")"
ck "premise is one-hot" \
   "$(awk '/^canon_sync_geo_premise\{/ {s+=$2} END {print s}' "$prom")" "1"
ck "range support is one-hot" \
   "$(awk '/^canon_sync_geo_range_supported\{/ {s+=$2} END {print s}' "$prom")" "1"
ck "every series has a HELP line" \
   "$(grep -oP '^canon_sync_\w+' "$prom" | sort -u | while read -r m; do grep -q "^# HELP $m " "$prom" || echo "$m"; done)" ""
ck "every value is numeric" \
   "$(grep -v '^#' "$prom" | awk '{print $2}' | grep -cv '^-\?[0-9]\+\(\.[0-9]\+\)\?$')" "0"
if command -v promtool >/dev/null; then
    o=$(promtool check metrics < "$prom" 2>&1); ck "promtool accepts the file" "$o" ""
elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^prometheus$'; then
    o=$(docker exec -i prometheus promtool check metrics < "$prom" 2>&1); ck "promtool accepts the file" "$o" ""
else
    printf '  \033[33mskip\033[0m promtool not available\n'
fi

# ───────────────────────────────────────────────────────────────────────────────
if (( WITH_ARCHIVE )); then
    group "the real archive"
    DEST=$(grep -E '^dest_base:' "$ROOT/config.yml" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*#.*//; s/^["'"'"']//; s/["'"'"']$//')
    if [[ -d "$DEST" ]]; then
        census="$WORK/census.tsv"
        find "$DEST" -type f \( -iname '*.jpg' -o -iname '*.cr3' \) -not -path '*/.*' -print0 \
            | has_gps_batch > "$census"
        ck "every still in the archive is parseable" \
           "$(awk -F'\t' '$1==2' "$census" | wc -l)" "0"
        printf '       %s stills, %s geotagged, %s without coordinates\n' \
            "$(wc -l < "$census")" \
            "$(awk -F'\t' '$1==0' "$census" | wc -l)" \
            "$(awk -F'\t' '$1==1' "$census" | wc -l)"
    else
        printf '  \033[33mskip\033[0m dest_base not readable\n'
    fi
fi

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
