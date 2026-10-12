#!/bin/bash
# Repack a HiBy R1 firmware (.upt) from an unpacked tree.
#
# Usage: tools/repack.sh <unpacked-dir> <out.upt>
#   <unpacked-dir> must contain: xImage, squashfs-root/ (as produced by unpack.sh)
#
# Rebuilds rootfs.squashfs (squashfs v4.0, lzo, 128K blocks, all-root —
# matching the stock image), splits both images into 512KB chunks and builds
# the ota md5-chain, writes ota_update.in / ota_config.in / ota_v0.ok and
# wraps everything as an ISO 9660 image, which is what the .upt format is.
set -euo pipefail

DIR="${1:?Usage: repack.sh <unpacked-dir> <out.upt>}"
OUT="${2:?Usage: repack.sh <unpacked-dir> <out.upt>}"

command -v mksquashfs >/dev/null || { echo "mksquashfs missing"; exit 1; }
command -v xorriso   >/dev/null || { echo "xorriso missing (genisoimage not present here)"; exit 1; }

[[ -d "$DIR/squashfs-root" && -f "$DIR/xImage" ]] || {
    echo "Need $DIR/squashfs-root/ and $DIR/xImage (run tools/unpack.sh first)"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/payload/ota_v0"
OTAV="$TMP/payload/ota_v0"

# chunk + md5-chain: filename of chunk N carries the md5 of chunk N+1;
# ota_md5_<name>.<md5-of-first-chunk> lists the chain, one md5 per line.
chain() { # chain <src> <chunk-prefix>
    local src="$1" name="$2" md5 next
    md5=$(md5sum "$src" | awk '{print $1}')
    local md5file
    md5file="$OTAV/ota_md5_$name.$md5"
    : > "$md5file"
    split -b 512k "$src" --numeric-suffixes=0 -a 4 "$TMP/$name."
    for part in "$TMP/$name".[0-9]*; do
        next=$(md5sum "$part" | awk '{print $1}')
        echo "$next" >> "$md5file"
        mv "$part" "$part.$next"
        md5="$next"
    done
    mv "$TMP/$name".[0-9]*.* "$OTAV/"
}

echo "1. Building rootfs.squashfs..."
mksquashfs "$DIR/squashfs-root" "$TMP/rootfs.squashfs" -no-recovery \
    -comp lzo -b 131072 -all-root > /dev/null

ROOTFS_MD5=$(md5sum "$TMP/rootfs.squashfs" | awk '{print $1}')
ROOTFS_SIZE=$(stat -c%s "$TMP/rootfs.squashfs")
KMD5=$(md5sum "$DIR/xImage" | awk '{print $1}')
KSIZE=$(stat -c%s "$DIR/xImage")

echo "2. Chunking + hash-chaining..."
chain "$TMP/rootfs.squashfs" rootfs.squashfs
chain "$DIR/xImage" xImage
rm "$TMP/rootfs.squashfs"

echo "3. Writing OTA metadata..."
{
    echo "ota_version=0"
    echo ""
    echo "img_type=kernel"
    echo "img_name=xImage"
    echo "img_size=$KSIZE"
    echo "img_md5=$KMD5"
    echo ""
    echo "img_type=rootfs"
    echo "img_name=rootfs.squashfs"
    echo "img_size=$ROOTFS_SIZE"
    echo "img_md5=$ROOTFS_MD5"
} > "$OTAV/ota_update.in"

: > "$OTAV/ota_v0.ok"
echo "current_version=0" > "$TMP/payload/ota_config.in"

echo "4. Building ISO 9660 image ($OUT)..."
xorriso -as mkisofs -quiet -f -J -joliet-long -r -allow-lowercase -allow-multidot \
    -o "$OUT" "$TMP/payload"

echo "Rebuilt: $OUT"
