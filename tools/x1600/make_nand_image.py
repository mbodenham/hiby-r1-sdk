#!/usr/bin/env python3
"""Build nand-r1.bin — the HiBy R1 SPI-NAND backing image for the QEMU
x1600 SFC model (M2).

Layout: raw page+OOB stream, 2112 B/page (2048 data + 64 OOB), 64
pages/block, 1024 blocks = 128 MiB data. Everything erased (0xFF) except
the payloads below. Partition map mirrors the live device's /proc/mtd
(libra BACKLOG RP3, live read 2026-08-16); kernel slot 5 MiB and ota
512 KiB are confirmed sizes, the rest fill the chip as noted.

  mtd0 uboot    2 MiB   (erased — no SPL/u-boot bytes in our artifacts)
  mtd1 kernel   5 MiB   xImage
  mtd2 rootfs   40 MiB  rootfs.squashfs
  mtd3 kernel2  5 MiB   xImage (A/B copy)
  mtd4 rootfs2  40 MiB  rootfs.squashfs (A/B copy)
  mtd5 ota      512 KiB "ota:kernel" padded-256 @0, theme "1" @0x20000
  mtd6 userdata rest    erased (UBIFS formats/attaches in-guest)
"""
import os
import sys

PAGE = 2048
OOB = 64
STRIDE = PAGE + OOB
PAGES = 64 * 1024
TOTAL = STRIDE * PAGES  # 138,412,032

UBOOT_SZ = 2 * 1024 * 1024
KERNEL_SZ = 5 * 1024 * 1024
ROOTFS_SZ = 40 * 1024 * 1024
OTA_SZ = 512 * 1024

OFF_UBOOT = 0
OFF_KERNEL = OFF_UBOOT + UBOOT_SZ            # 0x00200000
OFF_ROOTFS = OFF_KERNEL + KERNEL_SZ          # 0x00700000
OFF_KERNEL2 = OFF_ROOTFS + ROOTFS_SZ         # 0x02f00000
OFF_ROOTFS2 = OFF_KERNEL2 + KERNEL_SZ        # 0x03400000
OFF_OTA = OFF_ROOTFS2 + ROOTFS_SZ            # 0x05c00000
OFF_USERDATA = OFF_OTA + OTA_SZ              # 0x05c80000


def poke(buf, nand_off, data):
    """Write `data` into the data area stream starting at nand_off,
    hopping over the per-page OOB gaps."""
    for i, b in enumerate(data):
        pos = nand_off + i
        page, col = divmod(pos, PAGE)
        buf[page * STRIDE + col] = b


def poke_file(buf, nand_off, path):
    with open(path, "rb") as f:
        data = f.read()
    poke(buf, nand_off, data)
    print(f"  {os.path.basename(path):20s} -> {nand_off:#010x} "
          f"({len(data)} bytes)")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.abspath(os.path.join(here, "..", ".."))
    fw = os.path.join(root, "unpacked", "1.6")
    out = os.path.join(fw, "nand-r1.bin")

    buf = bytearray(b"\xff" * TOTAL)
    poke_file(buf, OFF_KERNEL, os.path.join(fw, "xImage"))
    poke_file(buf, OFF_ROOTFS, os.path.join(fw, "rootfs.squashfs"))
    poke_file(buf, OFF_KERNEL2, os.path.join(fw, "xImage"))
    poke_file(buf, OFF_ROOTFS2, os.path.join(fw, "rootfs.squashfs"))

    # mtd5 ota: boot-target flag at 0 (padded to 256 like nandwrite -p),
    # theme id at 0x20000 (S11jpeg_display_shell nanddumps the raw 7
    # bytes there and compares against "theme:1" / "theme:2").
    flag = b"ota:kernel"
    poke(buf, OFF_OTA, flag + b" " * (256 - len(flag)))
    theme = b"theme:1"
    poke(buf, OFF_OTA + 0x20000, theme)

    # Ingenic in-flash partition table at byte 0x5800 (driver default
    # when the DT has no partition-offset — decoded from the vendor
    # ingenic_sfc_v2 partition reader):
    #   header  {u32 magic 'nand' (LE), u32 count}
    #   entries 48 B each: {char name[0x20], u32 size @0x20,
    #                       u32 offset @0x24, u32 flags @0x28}
    parts = [
        (b"uboot",    UBOOT_SZ,   OFF_UBOOT),
        (b"kernel",   KERNEL_SZ,  OFF_KERNEL),
        (b"rootfs",   ROOTFS_SZ,  OFF_ROOTFS),
        (b"kernel2",  KERNEL_SZ,  OFF_KERNEL2),
        (b"rootfs2",  ROOTFS_SZ,  OFF_ROOTFS2),
        (b"ota",      OTA_SZ,     OFF_OTA),
        (b"userdata", 128 * 1024 * 1024 - OFF_USERDATA, OFF_USERDATA),
    ]
    hdr = b"nand" + len(parts).to_bytes(4, "little")
    poke(buf, 0x5800, hdr)
    for i, (name, size, off) in enumerate(parts):
        entry = name.ljust(0x20, b"\0") + size.to_bytes(4, "little") \
            + off.to_bytes(4, "little") + (0).to_bytes(4, "little")
        entry = entry.ljust(48, b"\0")
        poke(buf, 0x5808 + i * 48, entry)
    print(f"  partition table      -> 0x00005800 ({len(parts)} entries)")

    with open(out, "wb") as f:
        f.write(buf)
    print(f"wrote {out} ({TOTAL} bytes, "
          f"{TOTAL // STRIDE} pages x {STRIDE} B)")


if __name__ == "__main__":
    sys.exit(main())
