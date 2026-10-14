# Console hygiene + fb readback + live display session log (v0.68–v0.70)

Scope: the ttyS2/console region, the machine's kernel cmdline, the
LCD +0x1000 tap, and the live display surface — nothing else (the
MSC/SDIO wifi model and the DHD cascade are the parallel wifi session's
fault). Method follows the M1/M2 logs: every change pinned by
stock-DTB decode, module disassembly, or a boot symptom. Worktrees
`qemu-console-fb-dump` (vendored commits `1f062d6` + `ad699d0`) and
`qemu-live-display` (vendored commit `e4865d1`).

## v0.68 — ttyS2 console swap (patch 0110)

Two facts drove this (research brief §6b): stock firmware runs
`console=ttyS2,3000000n8` while our machine ran `console=ttyS0`, and
S80_bt_init's `brcm_patchram_plus --baudrate 3000000 … /dev/ttyS0`
writes binary into whatever the BT uart is wired to — with the console
on the same port that means the serial capture.

### Machine changes

- **UART2 (0x10032000) is now a real 16550 serial backend**, mirroring
  uart0 exactly: `serial_mm_init` regshift 2 (LSR at +0x14), baudbase
  230400, `x1600_uart_scr_seed` reset hook re-planting SCR = 0xa9 (the
  early-uart scan probe reads +0x1c expecting it), and the persistent
  ext stub at overlap priority −1 backing [+0x20, +0x100) (the vendor
  `serial_ingenic_set_termios` +0x24/+0x28 RMWs, v0.22 bus error).
- **Backend wiring**: serial0 = UART2 = the ttyS2 console = the captured
  port; serial1 = UART0 = the ttyS0 BT uart, discardable (the boot gate
  keeps it as a file only so the earlycon stage can be checked and BT
  debugging has somewhere to look). The machine now requires both
  `-serial` backends (clear error otherwise).
- **Cmdline**: `console=ttyS0,115200` → `console=ttyS2,3000000n8`
  (stock-faithful); mem/mtdparts/root unchanged. The earlycon stays on
  ttyS0 (it is the stock DTB stdout-path, not a cmdline item).

### IRQ correction: stock DTB over mainline x1000.dtsi

The research brief's "IRQ 49" (and the old uart0 wiring 51) came from
the **mainline** `x1000.dtsi` numbering. The stock DTB embedded in
`unpacked/1.6/vmlinux.bin` (FDT @0x7bdf80, the regmap doc's authority
rule) says otherwise:

| node | interrupts (DTB) | status |
|---|---|---|
| /apb/serial@0x10030000 | 0x2f = **47** | okay |
| /apb/serial@0x10031000 | 0x2e = 46 | disabled |
| /apb/serial@0x10032000 | 0x2d = **45** | okay |
| /apb/serial@0x10033000 | 0x2c = 44 | disabled |

The boot itself agrees, printing `ttyS0 at MMIO … (irq = 55…)` and
`ttyS2 at MMIO … (irq = 53…)` — virq = hwirq + 8, the arithmetic
already verified for SADC (11 → 19) and the LCD (31 → 39). The model
now wires uart0 → INTC line 47 and uart2 → line 45 (uart1/uart3 stay
plain stubs; disabled nodes).

Observable consequence of the fix: **the rcS userland echoes reached
the console for the first time**. In v0.67 the ttyS0 tty-layer TX starved
(line 51 never fired; the polled 8250 console path was unaffected, which
is why nobody noticed) — the v0.67 gate window contains NO
`Starting mdev... OK` / `Starting display...` / `Segmentation fault`
(insmod) lines. With uart2 on line 45 the /dev/console (= ttyS2 now)
writes drain; the v0.68 window gains exactly those userland lines.

### Earlycon → ttyS2 handoff mechanics (4.4.94 empirical)

The 4.4.94 8250 console does **not** replay the pre-handoff printk
buffer to a newly registered console (no CON_PRINTBUFFER rewind is
observable — the capture starts at the handoff). After the swap:

- serial0 (ttyS2 capture) starts at `console [ttyS2] enabled` +
  `bootconsole [early0] disabled` and holds the post-handoff dmesg;
- serial1 (earlycon) holds `Linux version …`, `bootconsole [early0]
  enabled`, `Kernel command line: …`, the `ttyS0/ttyS2 at MMIO (irq…)`
  lines — everything printed before the 0.50 s handoff.

The gate script updated accordingly: the earlycon stage (banner +
`bootconsole [early0] enabled`) is checked against the serial1 log, the
capture is checked for `console [ttyS2] enabled` + `bootconsole
[early0] disabled`, `STRUCT_RE` matches `console \[ttyS2\]`, and
`hrtimer: interrupt took <N> ns` joined the dropped timing-noise
classes (host-load dependent; fired in v0.67, not in the v0.68
baseline boot).

### Baseline + gate

- `git mv docs/traces/boot-baseline-v0.67.txt → boot-baseline-v0.68.txt`,
  re-recorded with `--update-baseline` (622 window lines vs v0.67's
  1306 — the pre-handoff earlycon block moved to serial1, so the window
  is console-only from 0.50 s guest).
- Post-handoff kernel content diffed against the v0.67 window: only the
  console-path lines (`console [ttyS0] enabled` → `[ttyS2]`; the
  `ttyS2 at MMIO` line moved to the earlycon log), the new userland
  echoes, and the one hrtimer noise line. Kernel-side boot otherwise
  identical.
- Gate PASS on the new baseline (332 distinct messages, 154 structural
  lines), re-PASSed after the v0.69 tap landed (the tap writes stderr,
  not the guest serial window).

### Console hygiene (long run)

A full boot (monitor-driven, ~11 min wall, killed in the rcS tail):
**0 non-text bytes in the ttyS2 capture** (3.87 MB, text-only through
the stall) and **0 in the ttyS0 log**. The rcS tail stalls in the
S50 `sys_server` stage (`(MGR:E)server: could not create socket.` /
`(GUI:E)lg_dlna: open server /data/dmr_streamer error.` loop — the
wifi userland stage), so S80/patchram is still unreachable today; the
pollution fix is structural (console moved off the BT uart) and becomes
observable once the wifi session unblocks rcS past S50.

## v0.69 — LCD fb descriptor tap + tools/fb-dump.py (patch 0111)

Machine change: every write to LCD **+0x1000** (the descriptor pointer
`lcdc_pan_display` stores before the +0x1004 kick) logs
`x1600_lcd: fb descriptor @ %08x` to QEMU stderr. Nothing else changes
(no state, no IRQ semantics).

`tools/fb-dump.py` (pure stdlib — struct + zlib, no PIL):

1. parse the tap lines from a QEMU stderr log (`--log`), newest kick
   first (`--desc` overrides);
2. read desc+4 from the RAM dump, strip the 0x80000000 flag bit →
   fb base for that frame (`yoff*stride + fb_phys`; frame_num=2 — the
   two descriptors each hold their own frame's line address, so the
   newest kick is the visible frame);
3. extract 480×800 RGB565 (stride 960 B, 768000 B/frame) at that
   guest-physical offset and write a PNG (8-bit RGB, filter 0 rows,
   zlib). `--list` prints every candidate descriptor + its desc+4.

### End-to-end verification (cap run, splash at ~72 s)

- Tap fired twice: `0x0250a000`, then `0x0250b000` (frame_num=2
  ping-pong; addresses vary per boot — a later boot logged 0x02429000,
  SLUB layout).
- `pmemsave 0 0x4000000 "/tmp/kilo/console-fb/cap/ram.bin"` via the
  unix HMP monitor (filename QUOTED; offsets = guest-physical) →
  67108864 bytes.
- `tools/fb-dump.py ram.bin --log qemu-stderr.log` → frame @
  **0x02600000** via descriptor @ 0x0250b000.
- **PNG verified by decoding it back**: 480×800, 8-bit RGB; light-blue
  splash palette (28 sampled colors, dominant #bddfef = 44.8% of the
  frame) with a dark glyph band at y≈350–430 whose ASCII-luminance
  render reads **HiBy R1** — the stock logo (theme:1 →
  `cmd_jpeg_display /etc/logo1.jpeg`), captured from the real guest
  framebuffer.
- Evidence PNG: `/tmp/kilo/console-fb/cap/splash.png` (RAM-backed
  scratch, not committed).

### Reproduction

```
mkdir -p /tmp/kilo/console-fb
qemu-system-mipsel -M x1600 -kernel unpacked/1.6/vmlinux.bin \
    -serial file:/tmp/kilo/console-fb/cap/console.log \
    -serial file:/tmp/kilo/console-fb/cap/ttyS0.log \
    -display none -no-reboot \
    -monitor unix:/tmp/kilo/console-fb/cap/mon.sock,server,nowait \
    2> /tmp/kilo/console-fb/cap/qemu-stderr.log &
# wait for 2+ "x1600_lcd: fb descriptor @" lines on stderr, then:
printf 'pmemsave 0 0x4000000 "/tmp/kilo/console-fb/cap/ram.bin"\nquit\n' \
    | socat - UNIX-CONNECT:/tmp/kilo/console-fb/cap/mon.sock
tools/fb-dump.py /tmp/kilo/console-fb/cap/ram.bin \
    --log /tmp/kilo/console-fb/cap/qemu-stderr.log \
    --out /tmp/kilo/console-fb/cap/splash.png
```

(The actual run used a small python driver for the unix-socket monitor;
`socat` shown for brevity. HMP echoes the typed command, hence the
filename must be quoted.)

## v0.70 — live display surface (patch 0112, vendored `e4865d1`)

The v0.69 tap + pmemsave + fb-dump.py loop proved the frame is real but
needed a manual dump per look. Patch 0112 gives the machine a real QEMU
display console bound to the guest framebuffer: with `-vnc` or
`-display gtk/sdl` the emulated 480×800 screen is live; with
`-display none` (the boot gate) the model does nothing at all.

### Machine changes

- **Graphic console**: `qemu_graphic_console_create(NULL, 0, ops, lcd)`
  registered once at machine init, `GraphicHwOps` = invalidate (no-op) +
  `gfx_update`. No `DeviceState` link (the LCD is a hand-rolled MMIO
  region, not a qdev), so HMP `screendump` works through the default
  graphic console (no device arg — `qemu_console_lookup_default()`
  picks the machine's only graphic console).
- **Frame upload** (`x1600_lcd_fb_draw`, shared by kick, timer and
  gfx_update): read `desc+4` from guest RAM via `dma_memory_read` (the
  LAST descriptor stored at +0x1000 wins — frame_num=2, the same rule
  fb-dump.py applies), strip the 0x80000000 flag bit →
  `yoff*stride + fb_phys`, bounds-check against the 64 MiB RAM, copy
  the 768000 B frame into a host buffer, and push a full 480×800
  `qemu_console_update_full`. The surface is
  `qemu_create_displaysurface_from(480, 800, PIXMAN_r5g6b5, 960, copy)`
  created once and kept: guest and host are both little-endian, so the
  upload is a plain row copy; VNC/GTK/SDL all accept r5g6b5
  (`qemu_pixman_check_format`), screendump converts via pixman.
- **25 Hz progressive-refresh timer**: `timer_new_ns(QEMU_CLOCK_VIRTUAL)`
  re-resolving desc+4 every 40 ms, so guest writes between kicks appear
  live. It arms at the FIRST `gfx_update` (backend poll or screendump)
  and the kick path draws+re-arms only when a backend exists — with
  `-display none` no timer, no copy and no wakeups ever run.
- **Lazy 768000 B frame copy**: `qemu_memalign(64, …)` at the first
  backend poll, not a static struct member (see the gate section below
  for why this is load-bearing).
- Unchanged: the +0x1000 stderr tap (fb-dump.py), the kick→EOF→INTC 31
  semantics, the W1C at +0x2008, SLCD BUSY=0, the two required
  `-serial` backends, `-display none` default.

### Verification

All runs stock firmware, `unpacked/1.6/vmlinux.bin`, monitor via unix
HMP socket (filename QUOTED), splash taps at ~70–75 s wall
(`x1600_lcd: fb descriptor @ 024e0000/0250c000-style`, fb base
0x02600000, addresses vary per boot).

- **VNC end-to-end**: `-display none -vnc 127.0.0.1:0` serves the
  console (`server init: 480x800`). A raw RFB 3.8 client (None auth,
  server pixel format echoed back, raw encoding, non-incremental
  full-frame FUReq) receives ONE 480×800 rect, 1536000 B; decoded PNG
  equals the HMP screendump pixel-for-pixel (ImageMagick AE = 0, fuzz
  2%). Dominant colour #bddfef at 47% — the stock splash (the v0.69
  palette, 44.8% at 7-px sampling there).
- **Screendump == guest RAM**: `screendump "…" -f png` is rejected by
  this build (no libpng); `screendump "…"` PPM + ImageMagick → PNG24.
  Compared against `tools/fb-dump.py` on a same-moment
  `pmemsave 0 0x4000000`: **AE = 0** on three separate boots.
- **Timer proof (no-kick update)**: gdbstub `tcp::1234`; the visible
  fb's bottom 24 rows (y=776–799) overwritten with red/green RGB565
  rows via RSP `M` packets (≤1024 B each, the stub's packet limit) —
  descriptor tap count unchanged, so no kick occurred; `pmemsave` taken
  while the VM was paused confirms the pattern sits in guest RAM at
  `0x026b5c00`; `cont` → screendump shows the red strip (#ff0000)
  within a second — the 25 Hz tick re-resolved desc+4 and re-uploaded
  without any kick. (gdb attach pauses the VM and the virtual-clock
  timer freezes with it — by design; resume re-syncs immediately.)
- **Boot gate PASS against the untouched v0.68 baseline** (332 distinct
  messages, 154 structural lines). This one bit back: with the frame
  copy as a `uint8_t[768000]` static struct member the gate failed
  three runs in a row, always the same seam — `Finish display... `
  deterministically glued onto `create proc entry lcd_reg success` in
  the ttyS2 window (the documented async-flush fragility). Control
  experiment: stashing the diff and re-running the gate on the
  unmodified v0.69 build → PASS, so the guest-visible model was never
  the problem; the 768 KB .bss growth had shifted the binary layout
  enough to move that flush boundary. The lazy allocation restores
  v0.69 timing exactly and the gate passes with patch 0112 applied.

### Artifacts (RAM-backed scratch, not committed)

```
/tmp/kilo/livedisp/livedisp-screen.ppm   HMP screendump (the deliverable)
/tmp/kilo/livedisp/livedisp-screen.png   PNG24 conversion
/tmp/kilo/livedisp/livedisp-fbdump.png   fb-dump.py extraction (AE=0 vs above)
/tmp/kilo/livedisp/livedisp-vnc.png      RFB client fetch (AE=0 vs above)
/tmp/kilo/livedisp/v-screen.png /v-vnc.png /v-fbdump.png
                                         shipping-binary re-verification
```

### Reproduction

```
mkdir -p /tmp/kilo/livedisp
qemu-system-mipsel -M x1600 -kernel unpacked/1.6/vmlinux.bin \
    -serial file:/tmp/kilo/livedisp/console.log \
    -serial file:/tmp/kilo/livedisp/ttyS0.log \
    -display none -vnc 127.0.0.1:0 -no-reboot \
    -monitor unix:/tmp/kilo/livedisp/mon.sock,server,nowait \
    2> /tmp/kilo/livedisp/qemu-stderr.log &
# wait for 2+ "x1600_lcd: fb descriptor @" lines, then via the monitor:
#   screendump "/tmp/kilo/livedisp/screen.ppm"
#   pmemsave 0 0x4000000 "/tmp/kilo/livedisp/ram.bin"
#   tools/fb-dump.py ram.bin --log qemu-stderr.log --out fbdump.png
# cross-check: magick compare -metric AE screen.png fbdump.png null:
```

## State after this session

## State after this session

- Vendored QEMU: `e4865d1` (live display surface, patch 0112) on top of
  `ad699d0` (LCD fb tap, 0111) and `1f062d6` (UART2 backend + stock
  console, 0110).
- Gate: PASS against `docs/traces/boot-baseline-v0.68.txt` (unchanged
  baseline; lazy fb_copy keeps the gate path at v0.69 timing).
- Live display: `-vnc`/`-display gtk` show the emulated screen live;
  HMP `screendump` (no device arg) captures the guest fb; with
  `-display none` the display model is inert (gate-verified).
- M3 next: the player's first UI frame arrives live on the console (or
  via screendump / fb-dump.py) — no pmemsave needed.

## v0.71 (2026-10-14, manager round): the splash is device-correct; the blue frame was the player's fallback

Device ground truth (user): the real R1's boot splash is BLACK with WHITE
text — that is `/etc/logo1.jpeg` (black bg, white-grey HIBY wordmark), the
`theme:1` branch. Verified by viewing both jpegs: logo.jpeg = pale blue,
logo1.jpeg = black+white.

The VM's theme read is CORRECT: in the real boot (init=`console::respawn:-/bin/sh`
shell from the inittab) `nanddump -q -s 0x20000 -l 7 /dev/mtd5 -a` returns
exactly `theme:1` (ECC clean, no bad blocks). The S11 splash drew logo1
(black) at the ~50 s pan. The earlier "pale blue" frames captured at
100-150 s were **the player's fallback draw**, not the splash:

- S92 ran — hiby_player launched (its lg_dlna threads spam the console).
- `/usr/data` did NOT mount: `mount: mounting /dev/ubi1_0 on /usr/data/
  failed: Invalid argument` (twice — mount_ubifs.sh erased + retried).
- With /data missing, the player's `nanddump ... > /data/theme_id` failed
  (its wrapper prints the stale-errno `[ERROR] nanddump failed:
  Address family not supported by protocol`) and its GUI fell back to
  drawing the default logo (logo.jpeg, blue) over the splash.

OPEN FAULT: UBIFS mount returns EINVAL after "UBIFS (ubiX:Y): default
file-system created" — reproduced in a diagnostic shell (init=/bin/sh:
ubiattach -m 6, ubimkvol -m, mount -t ubifs ubi0_0 → format message then
EINVAL, with and without -o sync; no ubifs_err printed). Decode target:
ubifs_fill_super's silent -EINVAL paths after the created-fs message in
vmlinux.bin; suspect a geometry check on the UBI layout the model's NAND
reports (VID hdr offset 2048, data offset 4096, LEB 126976, PEB 131072).
- Vendored QEMU: `e4865d1` (live display surface, patch 0112) on top of
  `ad699d0` (LCD fb tap, 0111) and `1f062d6` (UART2 backend + stock
  console, 0110).
- Gate: PASS against `docs/traces/boot-baseline-v0.68.txt` (unchanged
  baseline; lazy fb_copy keeps the gate path at v0.69 timing).
- Live display: `-vnc`/`-display gtk` show the emulated screen live;
  HMP `screendump` (no device arg) captures the guest fb; with
  `-display none` the display model is inert (gate-verified).
- M3 next: the player's first UI frame arrives live on the console (or
  via screendump / fb-dump.py) — no pmemsave needed.
