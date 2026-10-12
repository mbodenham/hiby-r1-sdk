#!/bin/bash
# Run a MIPS binary (or busybox applet) from the unpacked R1 rootfs under
# qemu-user, with the host env quarantined: its 2016-era glibc asserts on
# host locale data unless LC_ALL=C in a clean env.
#
# Usage:
#   tools/qrun.sh [-s] [-T secs] <path-in-rootfs> [args...]
#   tools/qrun.sh [-s] -bb <applet> [args...]   # busybox shorthand
#
#   -s   pass -strace to qemu (syscall trace)
#   -T N hard time limit in seconds (default 20)
#
# This is user-mode, NOT a chroot: absolute paths resolve on the host, so
# restrict to read-only binaries; device writes fail harmlessly (paths like
# /usr/data can't be created without root here).
set -euo pipefail

ROOT="${ROOT:-unpacked/1.6/squashfs-root}"
EMU=qemu-mipsel

STRACE=""
TIMEOUT=20
BB=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s) STRACE="-strace"; shift ;;
        -T) TIMEOUT="$2"; shift 2 ;;
        -bb) BB=1; shift; break ;;
        -T*) TIMEOUT="${1#-T}"; shift ;;
        *) break ;;
    esac
done

if (( BB )); then
    BIN="$ROOT/bin/busybox"
else
    BIN="$1"; shift
fi

exec timeout "$TIMEOUT" env -i LC_ALL=C \
    "$EMU" -L "$ROOT/" $STRACE "$BIN" "$@"
