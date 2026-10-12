#!/bin/bash
# Rootfs sandbox: run R1 MIPS binaries inside the extracted squashfs with
# proot providing path isolation and a fake /dev tree, and qemu-user doing
# the MIPS-32 CPU emulation. Rootless; host env is quarantined because the
# image's 2016-era glibc asserts on host locale data otherwise.
#
# Architecture:
#   - proot -r <rootfs> — NO auto-binds (they conflicted with fakes; see notes)
#   - static qemu-mipsel copied ONCE into the sandbox tree and bound at /xt —
#     no host /usr /lib64 file-glue binds (they hijacked guest /usr)
#   - manual binds: /dev (fakes + real host input), /usr/data, /tmp, /var,
#     optional /sbin stubs and litegui overlay
#
# Usage:
#   tools/proot-run.sh [-s] [-T secs] [-bb | <cmd> [args...]]
#     -s   qemu -strace      -T N time cap (default 20)
#     -bb  busybox applet    e.g. -bb uname -a
# Guest-absolute program paths (e.g. /usr/bin/aplay) work; host-relative
# paths also work when they land inside the sandbox tree.
set -euo pipefail

ROOT="${ROOT:-unpacked/1.6/squashfs-root}"
SB=/tmp/kilo/r1sb
XT="$SB/xt"          # guest tree holding the static qemu (no host glue needed)
EMU=/xt/bin/qemu-mipsel

STRACE=""
TIMEOUT=20
BB=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s) STRACE="-strace"; shift ;;
        -T) TIMEOUT="$2"; shift 2 ;;
        -bb) BB=1; shift ;;
        --) shift; break ;;
        *) break ;;
    esac
done
if (( BB )); then
    CMD=(/bin/busybox "$@")
else
    CMD=("$@")
fi
# qemu resolves the PROGRAM argument on the host fs tree, not via proot, so
# convert guest-absolute program paths to rootfs-relative form
case "${CMD[0]}" in
    /*) CMD[0]="$ROOT${CMD[0]}" ;;
    *) [[ -f "${CMD[0]}" ]] || { echo "no such program: ${CMD[0]}"; exit 1; } ;;
esac

mkdir -p "$XT/bin" "$SB/dev/input" "$SB/dev/snd" \
         "$SB/data" "$SB/tmp" "$SB/var" "$SB/log"
command -v /usr/bin/qemu-mipsel >/dev/null || { echo "qemu-mipsel missing"; exit 1; }
[[ -x "$XT/bin/qemu-mipsel" ]] || cp /usr/bin/qemu-mipsel "$XT/bin/qemu-mipsel"

[[ -e "$SB/dev/fb0" ]] || truncate -s 768000 "$SB/dev/fb0"   # 480x800 RGB565
: > "$SB/dev/sa-config"
if [[ ! -e "$SB/dev/mtd5" ]]; then
    python3 -c "
d = bytearray(0x20100)
d[0:10] = b'ota:kernel'
d[0x20000:0x20001] = b'1'
open('$SB/dev/mtd5','wb').write(bytes(d))
"
fi
: > "$SB/dev/nand5"

# optional overlays prepared outside this script:
#   $SB/sbin    stub scripts for reboot/halt/poweroff (host safety)
#   $SB/litegui edited litegui resources (e.g. 1x1 boot animation)
BINDS=(-b "$SB/dev:/dev")
BINDS+=(-b "$SB/data:/usr/data")
BINDS+=(-b "$SB/tmp:/tmp")
BINDS+=(-b "$SB/var:/var")
BINDS+=(-b "$XT:/xt")
BINDS+=(-b /dev/input:/dev/input)
[[ -x "$SB/sbin/reboot" ]] && BINDS+=(-b "$SB/sbin:/sbin")
[[ -d "$SB/litegui" ]] && BINDS+=(-b "$SB/litegui:/usr/resource/litegui")

exec timeout "$TIMEOUT" env -i LC_ALL=C \
    proot -r "$ROOT" "${BINDS[@]}" \
    "$EMU" -L "$ROOT/" $STRACE "${CMD[@]}"
