#!/bin/bash
# Unpack a HiBy R1 firmware (.upt):
#   .upt = ISO 9660 image -> ota_v0/ holds 512KB chunks of xImage + rootfs.squashfs.
#   Each chunk filename carries the md5 of the NEXT chunk (hash-chained);
#   ota_md5_* files list the chain; ota_update.in carries sizes + image md5s.
#
# Usage: tools/unpack.sh <firmware.upt> [dest-dir]
#   Builds <dest-dir>/xImage, rootfs.squashfs, squashfs-root/ and verifies md5s.
set -euo pipefail

UPT="${1:?Usage: unpack.sh <firmware.upt> [dest-dir]}"
DEST="${2:-unpacked/by-version/$(basename "${UPT%.upt}")}"

command -v 7z  >/dev/null || { echo "7z missing"; exit 1; }
command -v unsquashfs >/dev/null || { echo "unsquashfs missing"; exit 1; }

[[ -f "$UPT" ]] || { echo "No such file: $UPT"; exit 1; }
mkdir -p "$DEST"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

7z x -o"$TMP" "$UPT" >/dev/null
OTA="$TMP/ota_v0"

echo "Reconstructing images..."
cat "$OTA"/xImage.*        > "$DEST/xImage"
cat "$OTA"/rootfs.squashfs.* > "$DEST/rootfs.squashfs"

echo "Verifying md5 against ota_update.in..."
awk '/img_name=/ {n=$0; sub("img_name=","",n)} /img_md5=/ {m=$0; sub("img_md5=","",m); print n"\t"m}' \
    "$OTA/ota_update.in" > "$TMP/manifest"
for IMG in xImage rootfs.squashfs; do
    WANT=$(awk -F'\t' -v n="$IMG" '$1 == n {print $2}' "$TMP/manifest")
    GOT=$(md5sum "$DEST/$IMG" | awk '{print $1}')
    if [[ "$WANT" == "$GOT" ]]; then
        echo "  $IMG: OK ($GOT)"
    else
        echo "  $IMG: MISMATCH want=$WANT got=$GOT" >&2
        exit 1
    fi
done

echo "Extracting squashfs..."
unsquashfs -f -q -d "$DEST/squashfs-root" "$DEST/rootfs.squashfs" > /dev/null

echo "Unpacked: $DEST"
