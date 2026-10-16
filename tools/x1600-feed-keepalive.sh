#!/bin/bash
# keep-alive: inject an innocuous key every 20 s so the guest GUI's
# 30 s idle-blank window never closes while the user is away from the
# keyboard (the bisect v0.91 recipe). Alternating up/down = no net
# volume change... the picker ignores volume keys anyway; any input
# resets the idle timer.
QMP=/tmp/kilo/livedisp/qmp.sock
i=0
while true; do
    if [ -S "$QMP" ]; then
        python3 - "$QMP" "$i" <<'EOF'
import socket, json, sys
path, i = sys.argv[1], int(sys.argv[2])
key = "up" if i % 2 == 0 else "down"
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(path)
    s.recv(65536)
    for down in (True, False):
        s.sendall(json.dumps({"execute": "input-send-event", "arguments": {
            "events": [{"type": "key", "data": {
                "down": down, "key": {"type": "qcode", "data": key}}}]}}).encode() + b"\n")
    s.close()
except Exception:
    pass
EOF
    fi
    i=$((i + 1))
    sleep 20
done
