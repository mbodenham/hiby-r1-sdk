#!/usr/bin/env python3
"""R1 framebuffer viewer: renders the sandbox's fake /dev/fb0 as a window.

The guest treats /dev/fb0 as 480x800 RGB565 (960-byte stride); it mmaps the
regular file the proot sandbox binds at /dev/fb0, so this host watcher reads
the same bytes at ~20fps and blits them scaled.

Usage: tools/fb-viewer.py [fb0-path] [scale]
Defaults: /tmp/kilo/r1sb/dev/fb0, scale 2. Close the window to stop.

Note: if the guest renders top-down (device panel is mounted rotated), flip
the view with tools/fb-viewer.py --noflip / --sdl etc. as needed; rotation
and orientation get settled against real frames, not theory.
"""
import sys
import mmap
import tkinter as tk
import numpy as np
from PIL import Image, ImageTk

args = [a for a in sys.argv[1:] if not a.startswith("--")]
NOFLIP = "--noflip" in sys.argv
FB = args[0] if args else "/tmp/kilo/r1sb/dev/fb0"
SCALE = int(args[1]) if len(args) > 1 else 2
W, H = 480, 800
SZ = W * H * 2  # RGB565

fd = open(FB, "r+b")
fd.truncate(SZ)
mm = mmap.mmap(fd.fileno(), SZ, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)

root = tk.Tk()
root.title("HiBy R1 sandbox — /dev/fb0")
lbl = tk.Label(root, bg="black")
lbl.pack()
img_ref = None

def rgb565(buf):
    c = np.frombuffer(buf, dtype="<u2").reshape(H, W)
    r = ((c >> 11) & 0x1F).astype(np.uint8) * 8
    g = ((c >> 5) & 0x3F).astype(np.uint8) * 4
    b = (c & 0x1F).astype(np.uint8) * 8
    return np.stack([r, g, b], axis=-1)

def frame():
    global img_ref
    buf = bytes(mm[0:SZ])
    px = Image.fromarray(rgb565(buf))
    if not NOFLIP:
        px = px.transpose(Image.FLIP_TOP_BOTTOM)
    px = px.resize((W * SCALE, H * SCALE), Image.NEAREST)
    img_ref = ImageTk.PhotoImage(px)
    lbl.configure(image=img_ref)
    root.after(50, frame)

try:
    frame()
    root.mainloop()
finally:
    mm.close()
    fd.close()
