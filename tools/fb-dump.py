#!/usr/bin/env python3
"""fb-dump.py — extract the LCD frame from a QEMU guest RAM dump (M3 prep).

The X1600 machine model taps every write to LCD +0x1000 (the frame
descriptor pointer, stored by soc_fb's lcdc_pan_display before the +0x1004
kick) and logs the guest-physical value to QEMU stderr:

    x1600_lcd: fb descriptor @ <guest-phys>

This tool takes a guest RAM dump + that stderr log, reads desc+4 (the fb
line address as yoff*stride + fb_phys with bit31 = flag — strip bit31),
extracts the 480x800 RGB565 frame (960 B stride, 768000 B/frame) starting
at that guest-physical address and writes a PNG. Pure stdlib: struct +
zlib, no PIL.

Capture pipeline (HMP pmemsave needs the filename QUOTED; ~10-20 s of
guest time past the splash is enough, then quit QEMU):

    qemu-system-mipsel -M x1600 -kernel unpacked/1.6/vmlinux.bin \
        -serial file:console.log -serial file:ttyS0.log \
        -display none -no-reboot \
        -monitor unix:/tmp/kilo/console-fb/mon.sock,server,nowait \
        2> /tmp/kilo/console-fb/qemu-stderr.log &
    # ... wait for "x1600_lcd: fb descriptor @" lines on stderr, then via
    # the monitor socket:
    pmemsave 0 0x4000000 "/tmp/kilo/console-fb/ram.bin"
    quit
    tools/fb-dump.py /tmp/kilo/console-fb/ram.bin \
        --log /tmp/kilo/console-fb/qemu-stderr.log \
        --out /tmp/kilo/console-fb/splash.png

pmemsave dumps guest-physical memory verbatim from the given physical
address (0 = the machine's DDR base), so file offsets equal guest
physical addresses.

frame_num = 2: lcdc_pan_display ping-pongs two descriptors, each holding
its own frame's first-line address, so the most recent kick (the last log
line, or any --desc override) shows the visible frame.

Usage:
  tools/fb-dump.py [--log QEMU_STDERR] [--desc GUEST_PHYS] [--out PNG]
                   [--list] RAM_DUMP
"""

import argparse
import struct
import sys
import zlib

WIDTH = 480
HEIGHT = 800
STRIDE = 960                 # 480 * 2 bytes per RGB565 line
FRAME_BYTES = STRIDE * HEIGHT
ADDR_FLAG = 0x80000000       # soc_fb's lcdc_pan_display flag bit in desc+4

TAP_PREFIX = "x1600_lcd: fb descriptor @ "


def parse_descriptors(log_path):
    """All descriptor addresses logged by the machine's LCD tap, in order."""
    out = []
    with open(log_path, "r", errors="replace") as f:
        for line in f:
            i = line.find(TAP_PREFIX)
            if i < 0:
                continue
            try:
                out.append(int(line[i + len(TAP_PREFIX):].strip()[:8], 16))
            except ValueError:
                continue
    return out


def read_u32(dump, off):
    if off < 0 or off + 4 > len(dump):
        return None
    return struct.unpack_from("<I", dump, off)[0]


def rgb565_frame_to_png_rows(dump, fb_phys):
    """480x800 RGB565 frame at fb_phys -> PNG scanline rows (RGB888)."""
    if fb_phys % 2:
        raise ValueError("fb address %08x is not 2-byte aligned" % fb_phys)
    if fb_phys + FRAME_BYTES > len(dump):
        raise ValueError("fb frame [%08x..%08x) exceeds the RAM dump size "
                         "0x%x" % (fb_phys, fb_phys + FRAME_BYTES, len(dump)))
    raw = dump[fb_phys:fb_phys + FRAME_BYTES]
    rows = []
    for y in range(HEIGHT):
        line = raw[y * STRIDE:(y + 1) * STRIDE]
        px = struct.unpack("<%dH" % WIDTH, line)
        row = bytearray(WIDTH * 3)
        for x, v in enumerate(px):
            r5 = (v >> 11) & 0x1f
            g6 = (v >> 5) & 0x3f
            b5 = v & 0x1f
            row[3 * x] = (r5 << 3) | (r5 >> 2)
            row[3 * x + 1] = (g6 << 2) | (g6 >> 4)
            row[3 * x + 2] = (b5 << 3) | (b5 >> 2)
        rows.append(bytes(row))
    return rows


def write_png(path, width, height, rows):
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    raw = b"".join(b"\x00" + row for row in rows)   # filter type 0 per row
    png = (b"\x89PNG\r\n\x1a\n" +
           chunk(b"IHDR", ihdr) +
           chunk(b"IDAT", zlib.compress(raw, 9)) +
           chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def main():
    ap = argparse.ArgumentParser(
        description="Dump the 480x800 RGB565 LCD frame from a QEMU guest "
                    "RAM dump using the machine's LCD +0x1000 descriptor tap.")
    ap.add_argument("ramdump", help="guest RAM dump (HMP: pmemsave 0 "
                                    "0x4000000 \"ram.bin\"; offsets = "
                                    "guest-physical addresses)")
    ap.add_argument("--log", help="QEMU stderr log to parse the 'x1600_lcd: "
                                  "fb descriptor @' tap lines from")
    ap.add_argument("--desc", type=lambda s: int(s, 0),
                    help="explicit descriptor guest-physical address "
                         "(overrides the log; most recent kick wins)")
    ap.add_argument("--out", default="splash.png", help="output PNG path "
                    "(default: ./splash.png)")
    ap.add_argument("--list", action="store_true",
                    help="list candidate descriptors and exit")
    args = ap.parse_args()

    descs = []
    if args.desc is not None:
        descs.append(args.desc)
    if args.log:
        logged = parse_descriptors(args.log)
        if not logged:
            sys.exit("fb-dump: no '%s' lines in %s" % (TAP_PREFIX.strip(),
                                                       args.log))
        descs.extend(reversed(logged))   # newest kick first
    if not descs:
        sys.exit("fb-dump: no descriptor address (pass --log or --desc)")

    with open(args.ramdump, "rb") as f:
        dump = f.read()

    if args.list:
        for d in descs:
            v = read_u32(dump, d + 4)
            fb = (v & ~ADDR_FLAG) if v is not None else None
            ok = (fb is not None and fb != 0 and
                  fb + FRAME_BYTES <= len(dump))
            print("desc @ %08x: desc+4 = %s -> fb %s%s" %
                  (d, "%08x" % v if v is not None else "<out of dump>",
                   "%08x" % fb if fb is not None else "?",
                   "" if ok else " (unusable)"))
        return

    for d in descs:
        v = read_u32(dump, d + 4)
        if v is None:
            print("fb-dump: desc @ %08x outside the dump, trying next" % d,
                  file=sys.stderr)
            continue
        fb = v & ~ADDR_FLAG
        if fb == 0 or fb + FRAME_BYTES > len(dump):
            print("fb-dump: desc @ %08x gives unusable fb %08x, trying next"
                  % (d, fb), file=sys.stderr)
            continue
        rows = rgb565_frame_to_png_rows(dump, fb)
        write_png(args.out, WIDTH, HEIGHT, rows)
        print("fb-dump: wrote %s (%dx%d RGB565 frame @ %08x, via descriptor "
              "@ %08x)" % (args.out, WIDTH, HEIGHT, fb, d))
        return
    sys.exit("fb-dump: no usable framebuffer address in any of %d "
             "candidate descriptor(s)" % len(descs))


if __name__ == "__main__":
    main()
