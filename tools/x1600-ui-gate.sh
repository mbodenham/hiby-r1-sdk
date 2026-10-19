#!/bin/sh
# x1600-ui-gate.sh — X1600 first-boot UI gate: boot-window regression +
# first lit player-GUI frame, captured and pixel-verified end to end.
#
# Per run, in order:
#   1. regenerate the PRISTINE nand image via tools/x1600/make_nand_image.py
#      and md5-verify it (ae41e974e78aab2730774d05c9cbf37c) — never boot or
#      hand-patch a dirty image; fail hard on md5 mismatch;
#   2. run tools/x1600-boot-test.sh (boot-window diff vs the recorded
#      baseline) and require its exit 0 + PASS line;
#   3. regenerate + md5-verify the pristine image AGAIN (the boot-window
#      boot dirties it);
#   4. boot the vendored qemu x1600 machine on the pristine image with a
#      -qmp unix socket and a serial chardev logfile capturing the ttyS2
#      console into <out>/console.log (serial1 = ttyS0 BT uart is
#      discardable but the machine refuses to start with one serial); only
#      this script's own qemu child is ever signalled (clean QMP quit
#      first, then its PID);
#   5. poll console.log for the player-GUI-start markers — '(GUI:D)
#      lg_guimain:' first, then 'running activity' (the wizard activity
#      actually starting) — then sleep a short grace so the capture lands
#      inside the lit pre-blank window (picker renders within seconds of
#      the markers; the idle blank fires ~25-30 s later). The whole marker
#      wait is capped; failure to see the markers or a dead qemu fails the
#      stage cleanly;
#   6. take a QMP screendump to <out>/first-frame.png. It is requested
#      with format png; on builds whose screendump was compiled without
#      libpng (this vendored qemu answers {"error":{"desc":"Enable PNG
#      support with libpng for screendump"}}) the script falls back to the
#      default ppm dump and encodes a genuine PNG (IHDR/IDAT/IEND, zlib)
#      with pure-stdlib code — <out>/first-frame.png is always a real PNG;
#   7. pixel-check first-frame.png with pure-stdlib python (struct+zlib,
#      no PIL): PNG parses, is 480x800 8-bit RGB, full PNG unfiltering
#      (types 0-4 incl. Paeth), mean luma above the blanked floor (a
#      blanked capture is mean 0.0; the lit picker is ~243.8), nonzero
#      variance, and the known picker band structure: title band y~34-49
#      with rendered strokes, six rows at y~=131/256/390/513/635/768 each
#      with non-background strokes, and flat light gaps between the bands
#      (calibrated on live captures: /tmp/kilo/ui-gate-probe, lit mean
#      243.81 / std 19.13, title 528 dark px, rows 218-361, gap min luma
#      243 spread <=7; blanked mean 0.0);
#   8. print PASS and exit 0 ONLY if the boot-window diff, the serial
#      capture and the pixel check all passed; otherwise print which stage
#      failed (plus the last console.log lines) and exit nonzero.
#
# Usage:
#   tools/x1600-ui-gate.sh [--out DIR]
#
#   --out DIR   output directory (default /tmp/kilo/ui-gate); console.log,
#               first-frame.png, boot-test log and qemu logs land here.
#
# Exit codes: 0 PASS; 1 a gate stage failed (message says which); 2
# usage/environment error.
#
# Concurrency: boots serialize on a mkdir lock (/tmp/kilo/x1600-ui-gate.lock)
# because every stage uses the repo's real unpacked/1.6/nand-r1.bin, which
# is also held mmap-shared by unrelated long-running VMs. Stale locks
# (dead holder PID) are stolen. Run this script from the repo that owns
# unpacked/1.6 and tools/vendors (make_nand_image.py derives every path
# from its own location).
#
# Needs: coreutils, python3 (stdlib only), the vendored qemu binary.

set -u
LC_ALL=C
export LC_ALL

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

PRISTINE_MD5=ae41e974e78aab2730774d05c9cbf37c
MARKER_MAIN='lg_guimain:'
MARKER_ACTIVITY='running activity'
MARKER_WAIT=180
GRACE=15
POLL_STEP=2
OUT=/tmp/kilo/ui-gate

usage() {
    cat <<'USAGE'
usage: tools/x1600-ui-gate.sh [--out DIR]

  --out DIR   output directory (default /tmp/kilo/ui-gate)

Runs the full X1600 first-boot UI gate: pristine nand regen + md5,
boot-window diff (tools/x1600-boot-test.sh), pristine regen again, UI
boot with QMP + serial chardev capture, player-GUI marker wait + grace,
QMP screendump to first-frame.png (png, with ppm->png stdlib fallback for
libpng-less builds), pure-stdlib 480x800 lit-picker pixel check. Prints
PASS and exits 0 only if all stages pass.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --out)      [ $# -ge 2 ] || { usage >&2; exit 2; }
                    OUT=$2; shift 2 ;;
        --help|-h)  usage; exit 0 ;;
        *)          printf 'x1600-ui-gate: unknown option: %s\n' "$1" >&2
                    usage >&2; exit 2 ;;
    esac
done

Q=$ROOT/tools/vendors/qemu/build/qemu-system-mipsel
FIRMWARE=$ROOT/unpacked/1.6
KERNEL=$FIRMWARE/vmlinux.bin
NAND=$FIRMWARE/nand-r1.bin
MAKE_NAND=$ROOT/tools/x1600/make_nand_image.py
BOOT_TEST=$ROOT/tools/x1600-boot-test.sh
LOCK=/tmp/kilo/x1600-ui-gate.lock

CONSOLE_LOG=$OUT/console.log
BT_LOG=$OUT/bt-scratch.log
QMP_SOCK=$OUT/qmp.sock
PNG=$OUT/first-frame.png
PPM=$OUT/first-frame.ppm

QPID=
LOCK_HELD=0

die() { printf 'x1600-ui-gate: %s\n' "$1" >&2; exit 2; }

fail() {
    printf 'FAIL: %s: %s\n' "$1" "$2" >&2
    if [ -f "$CONSOLE_LOG" ]; then
        printf '%s\n' '--- last 20 lines of console.log (CR stripped) ---' >&2
        tr -d '\r' < "$CONSOLE_LOG" | tail -n 20 >&2
    fi
    exit 1
}

cleanup() {
    if [ -n "$QPID" ]; then
        kill "$QPID" 2>/dev/null
        wait "$QPID" 2>/dev/null
        QPID=
    fi
    if [ "$LOCK_HELD" -eq 1 ]; then
        rm -rf -- "$LOCK"
        LOCK_HELD=0
    fi
}
trap cleanup EXIT

command -v python3 >/dev/null 2>&1 || die "python3 not found"
command -v md5sum >/dev/null 2>&1 || die "md5sum not found"
[ -x "$Q" ] || die "qemu binary not found/executable: $Q"
[ -f "$KERNEL" ] || die "kernel not found: $KERNEL (run tools/unpack.sh)"
[ -f "$MAKE_NAND" ] || die "make_nand_image.py not found: $MAKE_NAND"
[ -x "$BOOT_TEST" ] || die "boot test not found/executable: $BOOT_TEST"

mkdir -p -- "$OUT" || die "cannot create output dir: $OUT"
OUT=$(CDPATH='' cd -- "$OUT" && pwd) || die "cannot enter output dir"

# Serialize whole-gate runs: every stage touches the repo's shared nand
# image. mkdir lock; steal when the recorded holder PID is gone.
acquire_lock() {
    waited=0
    while :; do
        if mkdir "$LOCK" 2>/dev/null; then
            printf '%s\n' "$$" >"$LOCK/pid" 2>/dev/null
            LOCK_HELD=1
            return 0
        fi
        holder=$(cat "$LOCK/pid" 2>/dev/null)
        if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
            printf 'x1600-ui-gate: stealing stale lock (holder %s is gone)\n' "$holder" >&2
            rm -rf -- "$LOCK"
            continue
        fi
        if [ -z "$holder" ] && [ "$waited" -ge 60 ]; then
            printf 'x1600-ui-gate: stealing unreadable lock after %ss\n' "$waited" >&2
            rm -rf -- "$LOCK"
            continue
        fi
        if [ "$waited" -ge 1200 ]; then
            die "another gate run holds $LOCK (holder: ${holder:-unknown})"
        fi
        sleep "$POLL_STEP"
        waited=$((waited + POLL_STEP))
    done
}

regen_pristine() {
    _stage=$1
    printf 'x1600-ui-gate: [%s] regenerating pristine nand image\n' "$_stage"
    if ! python3 "$MAKE_NAND" >"$OUT/make-nand.log" 2>&1; then
        printf 'FAIL: %s: make_nand_image.py failed (log: %s)\n' "$_stage" "$OUT/make-nand.log" >&2
        tail -n 15 "$OUT/make-nand.log" 2>/dev/null >&2
        exit 1
    fi
    if ! printf '%s  %s\n' "$PRISTINE_MD5" "$NAND" | md5sum -c - >/dev/null 2>&1; then
        printf 'FAIL: %s: pristine nand md5 mismatch after regen: %s (wanted %s)\n' \
            "$_stage" "$NAND" "$PRISTINE_MD5" >&2
        exit 1
    fi
    printf 'x1600-ui-gate: [%s] pristine nand md5 OK (%s)\n' "$_stage" "$PRISTINE_MD5"
}

acquire_lock

# ---- stage 1: pristine image ------------------------------------------------
regen_pristine boot-regen

# ---- stage 2: boot-window diff ----------------------------------------------
printf 'x1600-ui-gate: [boot-window] running tools/x1600-boot-test.sh\n'
"$BOOT_TEST" --out "$OUT/boot-test-scratch" >"$OUT/boot-test.log" 2>&1
btrc=$?
if [ "$btrc" -ne 0 ]; then
    printf 'FAIL: boot-window: tools/x1600-boot-test.sh exited %s (log: %s)\n' \
        "$btrc" "$OUT/boot-test.log" >&2
    tail -n 15 "$OUT/boot-test.log" 2>/dev/null >&2
    exit 1
fi
if ! grep -q '^PASS:' "$OUT/boot-test.log"; then
    printf 'FAIL: boot-window: boot test exited 0 but printed no PASS line (log: %s)\n' \
        "$OUT/boot-test.log" >&2
    tail -n 15 "$OUT/boot-test.log" 2>/dev/null >&2
    exit 1
fi
printf 'x1600-ui-gate: [boot-window] %s\n' "$(grep '^PASS:' "$OUT/boot-test.log" | head -n 1)"

# ---- stage 3: pristine image again (the boot-window boot dirtied it) --------
regen_pristine ui-regen

# ---- stage 4: UI boot with QMP + serial chardev capture ---------------------
printf 'x1600-ui-gate: [ui-boot] starting qemu (serial0 -> %s)\n' "$CONSOLE_LOG"
rm -f -- "$CONSOLE_LOG" "$BT_LOG" "$QMP_SOCK" "$PNG" "$PPM"
"$Q" -M x1600 \
    -kernel "$KERNEL" \
    -chardev file,id=ser0,path="$CONSOLE_LOG" \
    -serial chardev:ser0 \
    -serial "file:$BT_LOG" \
    -qmp "unix:$QMP_SOCK,server=on,wait=off" \
    -display none -monitor none -no-reboot \
    >"$OUT/qemu.log" 2>&1 &
QPID=$!

# ---- stage 5: player-GUI markers + grace ------------------------------------
seen_main=0
seen_act=0
elapsed=0
while :; do
    if [ "$seen_main" -eq 0 ] && grep -qF "$MARKER_MAIN" "$CONSOLE_LOG" 2>/dev/null; then
        seen_main=1
        printf 'x1600-ui-gate: [ui-boot] marker "%s" seen (~%ss)\n' "$MARKER_MAIN" "$elapsed"
    fi
    if [ "$seen_main" -eq 1 ] && [ "$seen_act" -eq 0 ] && \
       grep -qF "$MARKER_ACTIVITY" "$CONSOLE_LOG" 2>/dev/null; then
        seen_act=1
        printf 'x1600-ui-gate: [ui-boot] marker "%s" seen (~%ss)\n' "$MARKER_ACTIVITY" "$elapsed"
        break
    fi
    if ! kill -0 "$QPID" 2>/dev/null; then
        tail -n 5 "$OUT/qemu.log" 2>/dev/null >&2
        fail ui-boot "qemu exited before the GUI markers (waited ${elapsed}s; lg_guimain=$seen_main)"
    fi
    if [ "$elapsed" -ge "$MARKER_WAIT" ]; then
        fail ui-boot "GUI markers not seen within ${MARKER_WAIT}s (lg_guimain=$seen_main running-activity=$seen_act)"
    fi
    sleep "$POLL_STEP"
    elapsed=$((elapsed + POLL_STEP))
done
sleep "$GRACE"
if ! kill -0 "$QPID" 2>/dev/null; then
    tail -n 5 "$OUT/qemu.log" 2>/dev/null >&2
    fail ui-boot "qemu died during the post-marker grace (capture window missed)"
fi
printf 'x1600-ui-gate: [ui-boot] markers OK; capturing after %ss grace\n' "$GRACE"

# ---- stage 6: QMP screendump -> first-frame.png ------------------------------
# Tries format png first; falls back to the default ppm dump + pure-stdlib
# PNG encoding on builds without libpng (see header). Sends a clean QMP
# quit afterwards; the shell then only ever signals its own $QPID.
if ! python3 - "$QMP_SOCK" "$PNG" "$PPM" <<'QMP_PY'
import json
import socket
import struct
import sys
import zlib


class QMPError(Exception):
    pass


class QMP:
    def __init__(self, path, timeout=30):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(timeout)
        self.s.connect(path)
        self.f = self.s.makefile("rwb")
        if "QMP" not in self._msg():
            raise QMPError("unexpected QMP greeting")

    def _msg(self):
        while True:
            line = self.f.readline()
            if not line:
                raise QMPError("QMP EOF")
            m = json.loads(line)
            if "event" in m:
                continue
            return m

    def cmd(self, name, **args):
        c = {"execute": name}
        if args:
            c["arguments"] = args
        self.f.write((json.dumps(c) + "\n").encode())
        self.f.flush()
        m = self._msg()
        if "error" in m:
            raise QMPError(json.dumps(m["error"]))
        return m["return"]


def ppm_to_png(ppm_path, png_path):
    with open(ppm_path, "rb") as f:
        data = f.read()
    parts = data.split(b"\n", 3)
    if parts[0] != b"P6":
        raise QMPError(f"not a P6 ppm: {parts[0]!r}")
    w, h = map(int, parts[1].split())
    if int(parts[2]) != 255:
        raise QMPError(f"unsupported ppm maxval {parts[2]!r}")
    rgb = parts[3]
    if len(rgb) < w * h * 3:
        raise QMPError(f"short ppm raster {len(rgb)} < {w * h * 3}")
    rgb = rgb[:w * h * 3]
    raw = bytearray()
    stride = w * 3
    for y in range(h):
        raw.append(0)
        raw += rgb[y * stride:(y + 1) * stride]
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)

    def chunk(typ, payload):
        return (struct.pack(">I", len(payload)) + typ + payload
                + struct.pack(">I", zlib.crc32(typ + payload) & 0xFFFFFFFF))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + chunk(b"IEND", b""))
    with open(png_path, "wb") as f:
        f.write(png)
    return w, h


def main():
    sock, png, ppm = sys.argv[1], sys.argv[2], sys.argv[3]
    q = QMP(sock)
    q.cmd("qmp_capabilities")
    try:
        q.cmd("screendump", filename=png, format="png")
        print(f"screendump: {png} (native png)")
    except QMPError as e:
        sys.stderr.write(
            f"x1600-ui-gate: QMP screendump png refused ({e}); "
            "capturing ppm and encoding png with stdlib\n")
        q.cmd("screendump", filename=ppm)
        w, h = ppm_to_png(ppm, png)
        print(f"screendump: {png} (ppm {w}x{h} -> png, stdlib encode)")
    q.cmd("quit")


try:
    main()
except Exception as e:
    print(f"QMP-FAIL: {e}")
    sys.exit(1)
QMP_PY
then
    fail screendump "QMP screendump failed (see QMP-FAIL above)"
fi
# clean QMP quit was sent; give qemu a moment, then signal only our child
qwait=0
while kill -0 "$QPID" 2>/dev/null && [ "$qwait" -lt 10 ]; do
    sleep 1
    qwait=$((qwait + 1))
done
if kill -0 "$QPID" 2>/dev/null; then
    kill "$QPID" 2>/dev/null
    sleep 2
fi
if kill -0 "$QPID" 2>/dev/null; then
    kill -9 "$QPID" 2>/dev/null
fi
wait "$QPID" 2>/dev/null
QPID=
[ -s "$PNG" ] || fail screendump "screendump produced no $PNG"
printf 'x1600-ui-gate: [screendump] %s written\n' "$PNG"

# ---- stage 7: pure-stdlib pixel check ----------------------------------------
# Calibrated on live captures (/tmp/kilo/ui-gate-probe): lit picker mean
# 243.81 std 19.13, title band 528 dark px, rows 218-361 dark px, gaps min
# luma 243 spread <=7; a blanked capture is mean 0.0 std 0.0 everywhere.
if ! python3 - "$PNG" <<'PIX_PY'
import struct
import sys
import zlib

LIT_FLOOR = 40.0      # blanked captures are mean 0.0; lit picker ~243.8
STD_MIN = 3.0         # lit picker std 19.1; blanked 0.0
DARK = 128            # "rendered stroke" luma threshold
TITLE_BAND = (34, 49)
ROW_BANDS = (131, 256, 390, 513, 635, 768)
GAP_LINES = (90, 200, 325, 450, 575, 700, 795)
BAND_DARK_MIN = 100   # lit bands have >= 218 dark px (title 528)
BAND_LIGHT_MIN = 200  # band background must stay light (blanked: 0)
GAP_LUMA_MIN = 200    # lit gaps are >= 243 everywhere
GAP_SPREAD_MAX = 40   # lit gaps spread <= 7


def fail(msg):
    print(f"PIX-FAIL: {msg}")
    sys.exit(1)


path = sys.argv[1]
try:
    data = open(path, "rb").read()
except OSError as e:
    fail(f"cannot read {path}: {e}")
if data[:8] != b"\x89PNG\r\n\x1a\n":
    fail("not a PNG (bad signature)")
pos = 8
ihdr = None
idat = b""
while pos + 8 <= len(data):
    ln = struct.unpack(">I", data[pos:pos + 4])[0]
    typ = data[pos + 4:pos + 8]
    chunk = data[pos + 8:pos + 8 + ln]
    if typ == b"IHDR":
        ihdr = struct.unpack(">IIBBBBB", chunk)
    elif typ == b"IDAT":
        idat += chunk
    elif typ == b"IEND":
        break
    pos += 12 + ln
if ihdr is None:
    fail("no IHDR chunk")
w, h, depth, ctype, _comp, _filt, inter = ihdr
if w != 480 or h != 800:
    fail(f"expected 480x800, got {w}x{h}")
if depth != 8:
    fail(f"expected 8-bit depth, got {depth}")
if ctype not in (2, 6):
    fail(f"expected RGB(A) color type, got {ctype}")
if inter != 0:
    fail("interlaced PNG not supported")
bpp = 3 if ctype == 2 else 4
try:
    raw = zlib.decompress(idat)
except zlib.error as e:
    fail(f"IDAT zlib decompress failed: {e}")
if len(raw) != h * (1 + w * bpp):
    fail(f"decompressed size {len(raw)} != {h * (1 + w * bpp)}")

stride = w * bpp
px = bytearray(h * stride)
prev = bytearray(stride)
off = 0
for y in range(h):
    ft = raw[off]
    off += 1
    line = bytearray(raw[off:off + stride])
    off += stride
    if ft == 1:
        for i in range(bpp, stride):
            line[i] = (line[i] + line[i - bpp]) & 0xFF
    elif ft == 2:
        for i in range(stride):
            line[i] = (line[i] + prev[i]) & 0xFF
    elif ft == 3:
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
    elif ft == 4:
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            c = prev[i - bpp] if i >= bpp else 0
            b = prev[i]
            p = a + b - c
            pa = p - a if p >= a else a - p
            pb = p - b if p >= b else b - p
            pc = p - c if p >= c else c - p
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[i] = (line[i] + pr) & 0xFF
    elif ft != 0:
        fail(f"unsupported filter type {ft} at row {y}")
    px[y * stride:(y + 1) * stride] = line
    prev = line

n = w * h
hist = [0] * 256
end = n * bpp
i = 0
while i < end:
    l = (px[i] * 299 + px[i + 1] * 587 + px[i + 2] * 114) // 1000
    hist[l] += 1
    i += bpp
mean = sum(k * v for k, v in enumerate(hist)) / n
e2 = sum(k * k * v for k, v in enumerate(hist)) / n
std = (e2 - mean * mean) ** 0.5
if mean < LIT_FLOOR:
    fail(f"screen not lit: mean luma {mean:.2f} < {LIT_FLOOR} (blanked floor is 0.0)")
if std < STD_MIN:
    fail(f"no rendered content: luma std {std:.2f} < {STD_MIN} (blanked captures are 0.0)")


def band(y0, y1):
    dark = 0
    mn, mx = 255, 0
    for y in range(y0, y1 + 1):
        base = y * stride
        for x in range(w):
            j = base + x * bpp
            l = (px[j] * 299 + px[j + 1] * 587 + px[j + 2] * 114) // 1000
            if l < DARK:
                dark += 1
            if l < mn:
                mn = l
            if l > mx:
                mx = l
    return dark, mn, mx


dark, mn, mx = band(*TITLE_BAND)
if dark < BAND_DARK_MIN or mx < BAND_LIGHT_MIN:
    fail(f"title band y{TITLE_BAND[0]}-{TITLE_BAND[1]} missing: dark={dark} max={mx}")
bad_rows = []
for cy in ROW_BANDS:
    dark, mn, mx = band(cy - 8, cy + 8)
    if dark < BAND_DARK_MIN or mx < BAND_LIGHT_MIN:
        bad_rows.append(f"y{cy}(dark={dark},max={mx})")
if bad_rows:
    fail("picker rows missing rendered strokes: " + ", ".join(bad_rows))
bad_gaps = []
for gy in GAP_LINES:
    dark, mn, mx = band(gy, gy)
    if mn < GAP_LUMA_MIN or mx - mn > GAP_SPREAD_MAX:
        bad_gaps.append(f"y{gy}(min={mn},spread={mx - mn})")
if bad_gaps:
    fail("picker gaps not flat/light: " + ", ".join(bad_gaps))
dark_total = sum(hist[:DARK])
print(f"PIX: 480x800 8-bit RGB mean={mean:.2f} std={std:.2f} dark={dark_total} "
      f"title+{len(ROW_BANDS)} rows stroked, {len(GAP_LINES)} gaps flat")
PIX_PY
then
    fail pixel-check "pixel check failed (see PIX-FAIL above)"
fi
printf 'x1600-ui-gate: [pixel-check] OK\n'

# ---- stage 8: PASS ------------------------------------------------------------
printf 'PASS: x1600-ui-gate — boot-window diff PASS (tools/x1600-boot-test.sh), serial capture OK (lg_guimain + running activity, %ss grace), first-frame.png pixel check OK (480x800 lit picker)\n' "$GRACE"
exit 0
