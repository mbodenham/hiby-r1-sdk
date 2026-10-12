#!/bin/bash
# R1 OS sandbox — unprivileged user-namespace + bind mounts + chroot.
# Unlike a proot harness this uses REAL mount semantics: no path translation
# layer, no glue, deterministic. MIPS emulation via static qemu-mipsel, with
# a static fb/evdev shim injected through LD_PRELOAD (qemu -E).
#
# Layout inside the namespace:
#   /            = unpacked rootfs (squashfs extraction, local fs dir)
#   /dev         = fake device tree: fb0 file, sa-config, mtd5 image, ...
#   /dev/input   = the host's real evdev devices (keyboard drives the guest)
#   /dev/{null,zero,urandom,random} = real host nodes
#   /usr/data    = writable host dir (device settings storage)
#   /tmp /var    = writable host dirs
#   /sbin        = stub overlay: reboot/halt/poweroff are safe no-ops PC-side
#   /hbtools     = static qemu-mipsel + shim.so bind-mounted in
#
# Usage: tools/r1-sandbox.sh [-s] [-T secs] [-bb | <program> [args...]]
# Program may be guest-absolute (/usr/bin/aplay). NOTE: the filesystem is
# writable for us here — overlay dirs in /tmp/kilo/r1sb shadow the real
# mounts; nothing writes outside sandbox/tmp except unpacked/{hbtools,dev}
# placeholder files (repack excludes those).
set -euo pipefail

ROOT="${ROOT:-unpacked/1.6/squashfs-root}"
ROOT_ABS="$(readlink -f "$ROOT")"
SB=/tmp/kilo/r1sb

STRACE=""
TIMEOUT=45
BB=0
SHIM_ON=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s) STRACE="-strace"; shift ;;
        -T) TIMEOUT="$2"; shift 2 ;;
        -k) SHIM_ON=1 ;;

        -bb) BB=1; shift ;;
        --) shift; break ;;
        *) break ;;
    esac
done
if (( BB )); then
    CMDLINE="/bin/busybox $(printf '%q ' "$@")"
else
    [[ $# -gt 0 ]] || { echo "no command given"; exit 1; }
    CMDLINE="$(printf '%q ' "$@")"
fi

mkdir -p "$SB/dev/input" "$SB/dev/snd" "$SB/data" "$SB/tmp" \
         "$SB/var" "$SB/sbin" "$SB/litegui" "$SB/shim"
command -v qemu-mipsel >/dev/null || { echo "qemu-mipsel missing"; exit 1; }

# fake device tree (idempotent)
[[ -e "$SB/dev/fb0" ]] || truncate -s 768000 "$SB/dev/fb0"   # 480x800 RGB565
: > "$SB/dev/sa-config"
[[ -e "$SB/dev/mtd5" ]] || python3 -c "
d = bytearray(0x20100)
d[0:10] = b'ota:kernel'
d[0x20000:0x20001] = b'1'
open('$SB/dev/mtd5','wb').write(bytes(d))
"
: > "$SB/dev/shim.so"

# safe reboot/halt/poweroff (host safety: the player runs reboot on exit)
if [[ ! -x "$SB/sbin/reboot" ]]; then
    cp -r "$ROOT_ABS/sbin" "$SB/sbin"
    chmod -R u+w "$SB/sbin"
    for n in reboot halt poweroff; do
        rm -f "$SB/sbin/$n"
        printf '#!/bin/sh\necho %s-stubbed-by-r1-sandbox\n' "$n" > "$SB/sbin/$n"
        chmod +x "$SB/sbin/$n"
    done
fi

# shim: built by tools/shim/Makefile (mipsel musl cross compiler)
SHIM_SRC="tools/shim/shim.so"
SHIM_ENV=()
if (( SHIM_ON )) && [[ -f "$SHIM_SRC" ]]; then
    cp "$SHIM_SRC" "$SB/shim/shim.so"
    SHIM_ENV=("-E" "LD_PRELOAD=/hbtools/shim.so")
fi

INNER="$SB/inner.sh"
cat > "$INNER" <<EOF
#!/bin/bash
set -ex
mkdir -p "$SB/newroot"
mount --bind        "$ROOT_ABS"      "$SB/newroot"
mount --bind        "$SB/dev"        "$SB/newroot/dev"
mount --bind        "$SB/data"       "$SB/newroot/usr/data"
mount --bind        "$SB/tmp"        "$SB/newroot/tmp"
mount --bind        "$SB/var"        "$SB/newroot/var"
mount --bind        "$SB/sbin"       "$SB/newroot/sbin"
mount --bind        /dev/input       "$SB/newroot/dev/input"
mount --bind        /dev/null        "$SB/newroot/dev/null"
mount --bind        /dev/zero        "$SB/newroot/dev/zero"
mount --bind        /dev/urandom     "$SB/newroot/dev/urandom"
mount --bind        /dev/random      "$SB/newroot/dev/random"
if [ -d "$SB/litegui/theme1" ]; then
    mount --bind    "$SB/litegui"    "$SB/newroot/usr/resource/litegui"
fi
mkdir -p "$SB/newroot/hbtools"
touch               "$SB/newroot/hbtools/qemu-mipsel"
mt_evq() { mount --bind /usr/bin/qemu-mipsel "$SB/newroot/hbtools/qemu-mipsel"; }
mt_evq 2>/dev/null || true
if [ -f "$SB/shim/shim.so" ]; then
    touch "$SB/newroot/hbtools/shim.so"
    mount --bind "$SB/shim/shim.so" "$SB/newroot/hbtools/shim.so"
fi
cd "$SB/newroot"
exec env -i LC_ALL=C chroot "$SB/newroot" /hbtools/qemu-mipsel \\
    ${SHIM_ENV[*]} $STRACE -L / $CMDLINE
EOF
chmod +x "$INNER"

exec timeout --kill-after=3 "$TIMEOUT" unshare -m -r --propagation private bash "$INNER"
