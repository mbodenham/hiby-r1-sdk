#!/bin/bash
# keep-alive v2: inject a TOUCH TAP at an out-of-row screen position every
# INTERVAL s. QMP key events do NOT reach the guest's input stack (proven
# 2026-10-16: guest still idle-blanked at ~60 s with keys flowing, power
# key fails to wake a blanked panel) — only TP events reset the vendor
# idle-blank/poweroff timer, same as real touch on the device.
#
# Usage: x1600-keepalive.sh <qmp-socket> [interval] [x] [y] [hold_ms]
# Defaults: interval 15, tap 240x60 (picker title bar, above row 1),
# hold 120 ms. Out-of-row taps are no-ops for listview selection but do
# count as touch activity.
set -u
QMP=${1:?usage: x1600-keepalive.sh <qmp-socket> [interval] [x] [y] [hold_ms]}
INTERVAL=${2:-15}
X=${3:-240}
Y=${4:-60}
HOLD=${5:-120}
while true; do
    if [ -S "$QMP" ]; then
        python3 - "$QMP" "$X" "$Y" "$HOLD" <<'EOF'
import socket, json, sys, time
path, sx, sy, hold = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
ax = (sx * 0x7fff) // 480
ay = (sy * 0x7fff) // 800
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(path)
    s.recv(65536)
    json.dumps({"execute": "qmp_capabilities"})
    s.sendall((json.dumps({"execute": "qmp_capabilities"}) + "\n").encode())
    s.recv(65536)
    for down in (True, False):
        evs = [
            {"type": "abs", "data": {"axis": "x", "value": ax}},
            {"type": "abs", "data": {"axis": "y", "value": ay}},
            {"type": "btn", "data": {"down": down, "button": "left"}},
        ]
        s.sendall((json.dumps({"execute": "input-send-event", "arguments": {"events": evs}}) + "\n").encode())
        s.recv(65536)
        if down:
            time.sleep(hold / 1000.0)
    s.close()
except Exception:
    pass
EOF
    fi
    sleep "$INTERVAL"
done
