#!/bin/bash
# x1600-snapshot-vm.sh — fast-iteration snapshot workflow for the HiBy R1
# QEMU machine (docs/M1-bringup-log.md v0.89).
#
# The X1600 machine's custom devices carry VMStateDescription state, so a
# migration snapshot preserves the full guest-visible device state (MSC
# staged responses + windows, SFC cache/feature, RTC/CGU, GPIO pending,
# touch/codec I2C, AIC FIFOs, LCD regs + refresh timer, OST, PDMA, INTC,
# stub regfiles). Boot ONCE to the picker (~60-90 s wall), snapshot, and
# every later iteration RESUMES from the snapshot in ~5 s instead of
# re-booting ~2.5 min per cycle. The SPI-NAND array is the shared image
# file (unpacked/1.6/nand-r1.bin next to the kernel) — both the save and
# the restore side mmap it, so flash writes stay consistent across a
# snapshot round-trip.
#
# Usage:
#   tools/x1600-snapshot-vm.sh save   [--wait-mark] [--state FILE] [--tag ID]
#       Boot a fresh VM, wait until the first-boot language picker is live
#       (the "lg_listview_create" console line), screendump it, then
#       stop + migrate to --state (default /tmp/kilo/x1600-snapshot/state.bin)
#       and quit. Sockets/PIDs/serial logs land next to the state file.
#       Save only from a QUIET moment (the picker) — see the v0.89 log note
#       on mid-journal saves.
#
#   tools/x1600-snapshot-vm.sh resume [--state FILE] [--vnc DISPLAY]
#       Start a VM from the snapshot (-incoming file:). The restored guest
#       comes up paused (save was stopped); the script issues `cont` and
#       leaves the VM running with HMP/QMP sockets + serial capture beside
#       the state file (suffixed .resume). Prints the QMP/HMP paths.
#
#   tools/x1600-snapshot-vm.sh tap X Y [HOLD_MS]
#       Tap the RUNNING resumed VM at screen coords (0..479 x 0..799) via
#       QMP input-send-event (the picker's English row is 240,398).
#
#   tools/x1600-snapshot-vm.sh dump [FILE.png]
#       Screendump the RUNNING resumed VM (default state-dir/after.png).
#
#   tools/x1600-snapshot-vm.sh stop
#       Quit the resumed VM (only this script's own child is signalled).
#
# Sockets: HMP unix <statedir>/<tag>-mon.sock, QMP <statedir>/<tag>-qmp.sock,
# VNC 127.0.0.1:<vnc> (default :11 = 5901 — the persistent demo VM sits on
# :0/5900; never touch it). Console capture <statedir>/<tag>.console.log
# (TRUNCATED by each start — the restore side's capture holds only the
# post-restore tail; pre-save console content lives in the save-side log).
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
QEMU=$ROOT/tools/vendors/qemu/build/qemu-system-mipsel
KERNEL=$ROOT/unpacked/1.6/vmlinux.bin
STATEDIR=/tmp/kilo/x1600-snapshot
TAG=state
VNC=11
ACTION=
STATE=
EXTRA=

usage() { sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//; s/^#$//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        save|resume|tap|dump|stop) ACTION=$1; shift ;;
        --state)   STATE=$2; shift 2 ;;
        --tag)     TAG=$2; shift 2 ;;
        --vnc)     VNC=$2; shift 2 ;;
        --kernel)  KERNEL=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *)         EXTRA="$EXTRA $1"; shift ;;
    esac
done
[ -n "$ACTION" ] || { usage >&2; exit 3; }
[ -n "$STATE" ]  || STATE=$STATEDIR/$TAG.bin
STATEDIR=$(dirname -- "$STATE")
BASE=$STATEDIR/$(basename -- "$STATE" .bin)
mkdir -p -- "$STATEDIR"

[ -x "$QEMU" ]   || { printf 'x1600-snapshot-vm: missing %s\n' "$QEMU" >&2; exit 3; }
[ -f "$KERNEL" ] || { printf 'x1600-snapshot-vm: missing %s\n' "$KERNEL" >&2; exit 3; }

MON=$BASE-mon.sock
QMP=$BASE-qmp.sock
CONSOLE=$BASE.console.log
BTLOG=$BASE.bt.log

hmp() { python3 - "$MON" "$1" <<'EOF'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
time.sleep(0.4)
try: s.recv(65536)
except Exception: pass
s.sendall((sys.argv[2] + '\n').encode())
time.sleep(1.2)
try: print(s.recv(65536).decode(errors='replace'))
except Exception: pass
EOF
}

qmp() { python3 - "$QMP" "$@" <<'EOF'
import json, socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
f = s.makefile("rw")
def rd():
    while True:
        m = json.loads(f.readline())
        if "event" not in m:
            return m
rd()
f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); rd()
a = sys.argv[2]
if a == "tap":
    sx, sy = int(sys.argv[3]), int(sys.argv[4])
    hold = int(sys.argv[5]) if len(sys.argv) > 5 else 160
    ax = (sx * 0x7fff) // 480; ay = (sy * 0x7fff) // 800
    f.write(json.dumps({"execute": "input-send-event", "arguments": {"events": [
        {"type": "abs", "data": {"axis": "x", "value": ax}},
        {"type": "abs", "data": {"axis": "y", "value": ay}},
        {"type": "btn", "data": {"down": True, "button": "left"}}]}}) + "\n")
    f.flush(); rd()
    time.sleep(hold / 1000.0)
    f.write(json.dumps({"execute": "input-send-event", "arguments": {"events": [
        {"type": "btn", "data": {"down": False, "button": "left"}}]}}) + "\n")
    f.flush(); rd()
    print("tap done at", sx, sy)
elif a == "dump":
    print(rd() if False else json.dumps({"execute": "screendump", "arguments": {"filename": sys.argv[3]}}))
    f.write(json.dumps({"execute": "screendump", "arguments": {"filename": sys.argv[3]}}) + "\n")
    f.flush(); print(json.dumps(rd()))
else:
    f.write(json.dumps({"execute": a}) + "\n"); f.flush(); print(json.dumps(rd()))
EOF
}

boot_common() {
    "$QEMU" -name "x1600-snapshot-$$" -M x1600 \
        -kernel "$KERNEL" \
        -serial "file:$CONSOLE" -serial "file:$BTLOG" \
        -vnc "127.0.0.1:$VNC" \
        -monitor "unix:$MON,server,nowait" \
        -qmp "unix:$QMP,server,nowait" \
        -no-reboot \
        "$@"
}

case "$ACTION" in
save)
    rm -f "$MON" "$QMP" "$STATE" "$CONSOLE" "$BTLOG"
    printf 'x1600-snapshot-vm: booting; the picker marker is "lg_listview_create" in %s\n' "$CONSOLE"
    boot_common &
    QPID=$!
    for i in $(seq 1 60); do
        grep -q "lg_listview_create" "$CONSOLE" 2>/dev/null && break
        kill -0 "$QPID" 2>/dev/null || { printf 'x1600-snapshot-vm: qemu died during boot\n' >&2; exit 2; }
        sleep 3
    done
    grep -q "lg_listview_create" "$CONSOLE" 2>/dev/null \
        || { printf 'x1600-snapshot-vm: picker marker not seen in 180s\n' >&2; kill "$QPID"; exit 2; }
    sleep 2
    qmp dump "$BASE-save.png" >/dev/null
    hmp "stop" >/dev/null
    hmp "migrate file:$STATE" >/dev/null
    [ -s "$STATE" ] || { printf 'x1600-snapshot-vm: migrate failed (no state file)\n' >&2; kill "$QPID"; exit 2; }
    hmp "quit" >/dev/null
    sleep 1
    kill -0 "$QPID" 2>/dev/null && kill "$QPID"
    wait "$QPID" 2>/dev/null
    printf 'SNAPSHOT SAVED: %s (%s MB) — picker dump %s\n' \
        "$STATE" "$(( $(stat -c %s "$STATE") / 1048576 ))" "$BASE-save.png"
    printf 'resume with: tools/x1600-snapshot-vm.sh resume --state %s\n' "$STATE"
    ;;
resume)
    [ -f "$STATE" ] || { printf 'x1600-snapshot-vm: no snapshot: %s\n' "$STATE" >&2; exit 3; }
    rm -f "$MON" "$QMP"
    boot_common -incoming "file:$STATE" &
    QPID=$!
    sleep 6
    qmp cont >/dev/null
    printf 'RESUMED (pid %s): HMP %s  QMP %s  VNC 127.0.0.1:%s  console %s\n' \
        "$QPID" "$MON" "$QMP" "$VNC" "$CONSOLE"
    printf 'tap: tools/x1600-snapshot-vm.sh tap --state %s X Y\n' "$STATE"
    printf 'stop: tools/x1600-snapshot-vm.sh stop --state %s\n' "$STATE"
    wait "$QPID"
    ;;
tap)
    # shellcheck disable=SC2086
    qmp tap ${EXTRA:-240 398 160}
    ;;
dump)
    # shellcheck disable=SC2086
    OUT=${EXTRA:-$BASE-after.png}
    qmp dump "$OUT"
    printf 'screendump: %s\n' "$OUT"
    ;;
stop)
    hmp "quit" >/dev/null
    printf 'quit sent to %s\n' "$MON"
    ;;
*)
    usage >&2; exit 3 ;;
esac
