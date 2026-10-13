# Next-round research brief — stubs + player launch (2026-10-13)

Produced by a read-only research round (stock rootfs `.ko` disassembly — all
modules carry symtabs — plus the embedded DTB in `unpacked/1.6/vmlinux.bin`,
FDT at file off 0x7bdf80, totalsize 15,833; validated against
msc0=37/msc1=36/ost=4 already in the working model). Disassembler:
`tools/vendors/mipsel-linux-musl-cross/bin/mipsel-linux-musl-objdump`.

Headline corrections vs the v0.65 plan queue:

- "JPEG block 0x13050000" is a misnomer — it is the **LCD controller**.
- **AHB2 PWM 0x134c0000** is a fifth unmapped block, hit by the splash's
  backlight step right after the LCD stub lands.
- The **EFUSE stub is gated on CGU rate fidelity** (`div_ahb2` = 200 MHz)
  — soc_efuse fails insmod before any MMIO matters otherwise.
- The nand image theme bytes did not match rcS's raw `theme:1` comparison
  (fixed in `tools/x1600/make_nand_image.py`).

## 1. rcS tail: module chain → theme → player

`busybox init` → `inittab` `::sysinit:/etc/init.d/rcS` → rcS sources every
`S??*` in order (paths in `unpacked/1.6/squashfs-root/`):

| # | script | does |
|---|---|---|
| S10mdev | mdev populates devtmpfs |
| S11module_driver_default | `cd /module_driver && ./driver_default_init_script.sh` — 29-`sh` insmod chain: utils, rmem_manager, soc_utils, soc_i2c, i2c_gpio_add, axp2101, cw2015, keyboard_gpio_add, soc_gpio, soc_pwm, pwm_backlight, soc_fb, soc_aic, soc_msc, soc_adc, lcd_lg35583, sa_sound_switch, codec_cs43131, cst8xx_touch, cywdhd, keyboard_adc_multifunc, leds_pwm_add, sa_config, sa_earpods_adc, sa_hgl_dma, soc_efuse, tcs1421, x1600_hiby_r1_sound_card |
| S11jpeg_display_shell | splash, runs before userdata mount; poll-waits `/dev/fb0` at 20 ms, then theme-selects, `cmd_jpeg_display`, `echo 60 > /sys/class/backlight/backlight_pwm0/brightness` |
| S20urandom, S21mount_ubifs | `mount_ubifs.sh userdata /usr/data/` (works since v0.63) |
| S30dbus, S39_recovery.recovery, S40network, S43wifi_bcm_init_config, S50sys_server, S80_bt_init | wifi MAC, dbus, BT |
| S92_03_start_music_player | `[ -f $PL01 ] && ( $PL01 & )`, `PL01=/usr/bin/hiby_player.sh` |

`usr/bin/hiby_player.sh`: `killall hiby_player`, dead batd branch, then
`/usr/bin/hiby_player` foreground, `sleep 1`, `reboot` — player exit ⇒
guest reboot.

Theme step (S11jpeg_display_shell:15-25):

```sh
theme=$(nanddump -q -s 0x20000 -l 7 /dev/mtd5 -a)
if [ "$theme" == "theme:1" ]; then cmd_jpeg_display /etc/logo1.jpeg
elif [ "$theme" == "theme:2" ]; then cmd_jpeg_display /etc/logo2.jpeg
else cmd_jpeg_display /etc/logo.jpeg; fi
sleep 0.1; echo 60 > /sys/class/backlight/backlight_pwm0/brightness
```

`nanddump` `-a` = `--forcebinary`, `-q` = quiet — the comparison is against
the raw 7 bytes at ota+0x20000, which must be exactly ASCII `theme:1`.

What hiby_player opens in its first seconds
(docs/traces/proot-player-firstboot.strace-full): `config.json`,
`/etc/localtime`, leds `{red,blue}`, `access /data/mnt/sd_0/get_cover_switch`,
`/dev/fb0` O_RDWR, `/dev/input` readdir + openat(eventN), `ot_devices.json`,
`/sys/class/android_usb/f_uac_sa/dsd_native_enable` (write),
`/sys/class/switch/{headset,lineout,balance,spdif,i2s}/state`,
`/dev/sa-config` O_RDWR + `ioctl(-1, 0xffff00f0, …)` (sa-config SET ioctl),
`/proc/jz/efuse/efuse_chip_id`, forked
`nanddump -s 0x20000 -l 256 /dev/mtd5 -a > /data/theme_id`,
`/data/user.ini`, `litegui/theme1/boot_animation/en/{config.ini,0.png}`.
Everything missing so far is ENOENT-tolerated.

### Launch checklist vs x1600.c, in demand order

| demand order | node / step | needs from the machine | state in x1600.c |
|---|---|---|---|
| 1 (S11 splash, blocking 20 ms poll) | `/dev/fb0` | LCD controller 0x13050000 stub + INTC line 31 (fb frame-done IRQ); fb0 appears only after `lcd_lg35583` → `jzfb_register_lcd` (GPIO-bitbang panel init — no model needed) | ABSENT (bus error ⇒ the splash oops) |
| 2 (S11 last line) | backlight write | AHB2 PWM 0x134c0000 (soc_pwm.ko hardcodes `0xb34c0000`) | ABSENT — was not in the queue |
| 3 (S43) | wlan0 + efuse fallback | DHD fix (wifi session) + EFUSE §2 | efuse ABSENT |
| 4 (S80) | `/dev/ttyS0` for brcm_patchram_plus | uart0 already real | console pollution only |
| 5 (S92) | `/dev/input` | keyboard + cst8xx already load → evdev nodes exist | OK |
| 6 | `/dev/sa-config` | sa_config_module.ko (dies in the DHD cascade); pure software chardev — ioctls 0xffff00f0/f1 are copyin/out of a config struct. No machine model. | loads once cascade fixed |
| 7 | `/sys/class/switch/*` | sa_sound_switch already loads | OK (+SADC §3) |
| 8 | leds | leds_pwm_add.ko (cascade) + PWM block | PWM ABSENT |
| 9 | `/proc/jz/efuse/efuse_chip_id` | §2 | ABSENT |
| 10 | `/dev/mtd5` → `/data/theme_id` | works; needed the `theme:1` image fix | image fix |
| 11 | `/proc/asound` | sound-card chain tail; player degrades gracefully | Phase-3 AIC model |

## 2. soc_efuse

**Block = physical 0x13540000, size 0x100.** Triple-verified:
`soc_efuse.ko` hard-codes KSEG1 `0xb3540000` (read) / `0xb354000c` (write);
the stock DTB has `/ahb1/efuse@0x13540000`, compatible
`ingenic,x1600-efuse`, `reg <0x13540000 0x100>`, status okay (vmlinux.bin
@0x7c16d4); `strings vmlinux.bin` hits `efuse@0x13540000`, `gate_efuse`.

**The real blocker is CGU**: soc_efuse init (@0xd4-0x184) computes
rd_adj/rd_strobe/wr_strobe from `clk_get_rate("div_ahb2")` (period
`p = 1e9/rate` ns must satisfy `(floor(7/p)+1)*p ≥ 8`,
`(q1+5+max(floor(35/p)-4-q1,0))*p ≥ 36`,
`9000 ≤ (q1+1666+max(floor(10000/p)-1666-q1,0)+1)*p < 11001`), then writes
the packed CFG to REG+0x4. Valid p = {1,2,3,5,6} ns → rate ∈ {1000, 500,
333, 200, 166.7} MHz; the real h2clk is 200 MHz (p=5, all pass). Our CGU
yields ~24 MHz-ish → wr_strobe fails → `EFUSE: failed to get efuse cfg
wr_strobe` → insmod returns -1 and **no proc entries are ever created**
(the observed v0.63/64 lines). Fix div_ahb2 = 200 MHz first, then stub.

**Read protocol** (soc_efuse_read @0x16c, per ≤32-byte chunk):

1. `REG+0x00 = 0`; `REG+0x08 = 0`
2. `REG+0x00 = (byte_off << 21) | ((n-1) << 16)` then again `| 1`
   (bit0 = start; byte_off = segment offset [27:21], n = bytes [20:16])
3. poll `REG+0x08` bit0 until 1 (read-done; loop @0x2ac-0x2b4)
4. copy ≤32 bytes from the data window `REG+0x0c .. +0x2b` (8 words,
   ≤4 bytes per word, @0x2bc-0x328)

Write path sets bit15 of +0x00 and polls bit1 of +0x08, but is
unreachable: `insmod soc_efuse.ko gpio_efuse_vddq=-1` makes
soc_efuse_write bail ("EFUSE: efuse vddq gpio should be set when write
segment!"). A stub needs no write support.

**Segments** (9-entry table @.rodata+0xd8, `{byte_off, size, name}`,
contiguous, total 0x80): CHIP_ID @0x00 0x10, CUSTOMER_ID @0x10 0xb,
TRIM_DATA @0x1b 0x10, SOC_INFO @0x2b 2, HIDE_BLK @0x2d 1,
PROGRAM_PROTECT @0x2e 2, CHIP_KEY @0x30 0x20, USER_KEY @0x50 0x20,
NKU @0x70 0x10.

`/proc/jz/efuse/efuse_chip_id` (efuse_read_chip_id_proc @0x4e8 →
"CHIP_ID", "%s: ", "%02x", "\n") prints:

```
CHIP_ID: <16 bytes as %02x each, no separators>\n
```

Consumers: S43wifi getmac (strips non-hex, takes 6 chars →
`d0:31:10:XX:YY:ZZ`) and hiby_player. The module also
`misc_register("efuse-string-version")`; S43 checks
`/sys/class/misc/efuse-string-version/dev` before the efuse path.

**Stub**: persistent regfile; decode +0x00 trigger {off[27:21], n[20:16],
start bit0}; fill +0x0c..+0x2b from a 128-byte virtual efuse array
(16-byte CHIP_ID = first segment; any stable non-zero value); +0x08
returns bit0 set after a trigger (0x1 permanently also satisfies the
write-busy poll bit1, harmless); accept the init CFG write to +0x4.

## 3. SADC (0x10070000) — the 220 ms poller

**Who polls: `sa_sound_switch.ko`** (`switch_work_schedule`) — the
audio-routing driver behind `/sys/class/switch/{headset,lineout,balance,
spdif,i2s}`. It loads clean since v0.63 and is the only loaded ADC poller
(keyboard_adc_multifunc and sa_earpods_adc die in the DHD cascade;
cst8xx_touch reads ADC ch3 once).

**The 220 ms math (exact)**: SASS work is a delayed_work re-queued with
delay = `sass_debounce_time=200` ms; each pass calls
`adc_read_channel_value`, whose wait loop has budget 2 jiffies
(`li s3,2` @0x248) and prints `"%s:adc get value timeout!"` + returns
-EBUSY on exhaustion. HZ=100 (pinned by M1 log v0.12) → 200 + 20 = 220 ms.

**Channels** (module params): SASS headset = ch1, raw range [2800,3300]
(compares the RAW value; membership → state 1). keyboard_adc_multifunc =
ch0. sa_earpods_adc = ch2 (poll_ms=10). cst8xx = ch3 one-shot
(`<1000` check in hyn_ctpm_get_upg_ver).

**Register map** (soc_adc.ko uses hard-coded `0xb0070000` → 0x10070000;
DTB `/apb/sadc@10070000`, `reg <0x10070000 0x32>`, interrupts = <11> on
core-intc → module virq 19, hwirq+8 arithmetic):

| off | reg | semantics |
|---|---|---|
| +0x00 | CFG | bits[3:0] per-channel enable (set bit=chan then poll same bit until set, @0x790-0x7b4); bit9 repeat; bit14 power-optimize; bit15 PEN — enable_controller clears it and polls until 0, disable sets it and polls until 1 |
| +0x04 | soft reset bit0 |
| +0x08 | IMASK bits[3:0], 1 = masked |
| +0x0c | IFLAG bits[3:0], write-1-to-clear |
| +0x10 | data: ch0 [11:0], ch1 [27:16] |
| +0x14 | data: ch2 [11:0], ch3 [27:16] |
| +0x20 | CLKDIV |
| +0x24 | WAIT sampling-stable time |
| +0x28 | repeat-sampling time |

Read flow: consumer → pending |= 1<<chan → adc_hal_enable_channel (CFG
bit + poll) → wait for the IRQ → handler reads IFLAG, W1C, clears
pending, wakes → data from +0x10/+0x14. Voltage = raw * 3300 >> 12.

**To add** (current stub is a plain persistent regfile, x1600.c:1413): on
a 0→1 transition of CFG bit n: latch a 12-bit sample for channel n into
+0x10/+0x14, set IFLAG bit n, assert INTC input 11 while
`(IFLG & ~IMASK) != 0`. IFLAG is W1C. **Serve 0xFFF for every channel**:
raw 4095 is outside SASS's [2800,3300] → headset state 0 (correct emulated
idle), outside keyboard/earpods ranges → no phantom keys, passes cst8xx's
<1000 check. This clears the 220 ms spam and the 20 ms read stalls that
would hit lcd_lg35583 (one ch1 read in probe, @0x37c-0x3a4) and cst8xx
once the cascade is fixed.

## 4. "JPEG block" 0x13050000 = the LCD controller

- `cmd_jpeg_display` (usr/bin, 7.1 K MIPS ELF) contains **no MMIO**: it
  links libjpeg.so.9 + libhardware2.so (`fb_open`, `fb_enable`,
  `fb_pan_display`, `fb_close`) and prints a `/dev/fb0` usage string.
  `fb_open`: open("/dev/fb0", O_RDWR) → FBIOGET_FSCREENINFO (0x4602) →
  FBIOGET_VSCREENINFO (0x4600) → mmap; `fb_pan_display` sets yoffset +
  FBIOPAN_DISPLAY (0x4606); `fb_enable` → FBIOBLANK (0x4611, 0).
- Kernel side `soc_fb.ko` (jzfb) touches `0xb3050000` (KSEG1) =
  0x13050000 — 17 `lui reg,0xb305` sites. The v0.63 "splash oops on the
  unmapped JPEG block" is the kernel bus-erroring inside the fb ioctl
  path on behalf of cmd_jpeg_display.
- Register offsets used by soc_fb: dense 0x00-0xfc (jz4775-style
  LCD_CFG/VSC/HSC/VS/HS/VAT/DAH/DAV/CTRL…, +0x34 = CTRL hit 28×),
  descriptor regs 0x220/0x230-0x244, +0x1000/+0x1004, int/state block
  +0x2000/+0x2008/+0x2010/+0x2014, SLCD panel-SPI window
  +0xa000/+0xa014/+0xa018.
- **Load-bearing semantics:**
  1. +0xa018 bit0 = BUSY — `slcd_wait_busy_us` polls it with 500 µs
     sleeps (@0x3c-0x88). Stub must read 0.
  2. +0x1000 = frame descriptor pointer, +0x1004 = kick —
     `lcdc_pan_display` (0x26d8) picks one of frame_num=2 descriptors,
     sets `desc->addr = fb_phys + yoff*stride` (plus 0x80000000 flag bit,
     @0x2764-0x276c), then `sw desc, +0x1000; sw 1, +0x1004`
     (@0x283c-0x2844 and the IRQ-enabled twin @0x2878-0x287c).
  3. +0x2010 = STATE, +0x2008 = W1C clear — `jzfb_irq_handler` (@0x934):
     reads +0x2010; bit17 (EOF) → write 0x20000 to +0x2008, state=2, wake
     (jzfb+0x2c); bit7 → clear 0x80, state=3; bit8 → clear 0x100.
  4. `pan_display_sync=1` (soc_fb.sh) makes FBIOPAN_DISPLAY wait on
     state == 2 (schedule with timeout; non-IRQ path bounds at
     `li a0,10000` ticks ≈ 100 s at HZ=100). Without the IRQ it stalls
     ~100 s per frame and errors. The stub must raise the IRQ.
- **IRQ**: init_module does `request_threaded_irq(39, jzfb_irq_handler,
  NULL, IRQF_SHARED(0x80), …)` (@0x2c38-0x2c58) → INTC input 31
  (39 − 8, same arithmetic as SADC 11 → virq 19).
- **Minimal stub** (region 0x13050000, size 0x10000 to cover 0xa018 and
  0x2010): persistent regfile; +0xa018 reads bit0=0; on a write of 1 to
  +0x1004: set +0x2010 |= 0x20000 and assert INTC line 31 (synchronously
  is fine). Clears the splash oops AND makes pan_display complete.

## 5. soc_fb / M3 prep

- **fb0 does NOT appear from soc_fb alone**: soc_fb registers no fb
  device at insmod; fb0 is registered when the panel module calls
  `jzfb_register_lcd(lcd_info)` (validates width/height ∈ [32,2048], mode
  count, bpp @+0x2c < 4, computes stride = w*bpp rounded to 8, allocates
  via `rmem_alloc_aligned`). Chain: `lcd_lg35583 probe → jzfb_register_lcd
  → register_fb0`.
- **Panel init is NOT I2C and NOT needed as a model.** `lcd_lg35583.sh`:
  `gpio_lcd_rst=PA31 gpio_spi_cs=PA30 gpio_spi_sck=PA00 gpio_spi_mosi=PA01
  spi_bus_num=5 vcc=bldo1 vccio=bldo2` — the LG35583 is programmed by
  GPIO-bit-banged SPI into the existing pinctrl stub + AXP2101 regulators
  (axp2101 already loads). The probe also does one SADC ch1 read. The
  "model LG35583 as an I2C sink" contingency in PLAN §M3 can be dropped.
- **The driver waits on the frame-done IRQ (INTC 31)**, not vsync
  polling. With the §4 stub, nothing blocks.
- **Framebuffer readback (QEMU → PNG)**: the fb memory is ordinary guest
  RAM (rmem_manager falls back to kmalloc; our cmdline has no
  `rmem=`). Hook: record every write to LCD +0x1000 — the value is the
  descriptor's guest-physical address; desc+4 holds the fb line address
  with a 0x80000000 flag bit; strip bit31 → fb base. Frame geometry is
  480×800 RGB565 (stride 960 B, 768,000 B/frame, frame_num=2). Dump
  960*800 bytes from guest RAM → PNG.

## 6. Extras

**(a) Theme value — was a confirmed mismatch.** make_nand_image.py wrote
`b"1"` + 6 spaces at OTA+0x20000; S11 compares the raw 7 bytes against
`theme:1` (mtd-utils `-a` = forcebinary). Splash always fell to the
else → logo.jpeg, and the player's `/data/theme_id` dump was
unrecognizable (theme parser defaulted to theme1). **Fixed: write
`b"theme:1"` (7 bytes) at OFF_OTA+0x20000.** No other consumer:
`bootmode.sh` writes its own `ota:kernel`/`ota:kernel2` (256 B padded) at
offset 0, which the image already matches.

**(b) Other predicted first-time faults for the player launch:**

1. **PWM block 0x134c0000 (AHB2, DTB `ahb2/pwm@0x134c0000` size 0x10000)
   is unmapped and WILL be hit** — soc_pwm.ko hardcodes `0xb34c0000` in
   16 sites (pwm_set_clk_div, set_pwm_mode, set_pwm_init_level,
   set_pwm_idle_level, pwm2_set_level, pwm_enable_channels…). S11's
   `echo 60 > /sys/class/backlight/backlight_pwm0/brightness` runs
   seconds after the splash — right after the LCD stub lands, this
   becomes the next bus error. Add the persistent stub (it also unblocks
   leds_pwm's PWM LEDs).
2. **BT pollutes the console**: `bt_init` runs `brcm_patchram_plus
   --baudrate 3000000 … /dev/ttyS0`. Our cmdline uses `console=ttyS0`;
   stock uses `console=ttyS2,3000000n8`. Patchram writes spew binary into
   the serial log (backgrounded, so rcS survives). Clean fix: move the
   console to ttyS2 (0x10032000 — give the stub a real serial backend +
   SCR seed like uart0; IRQ 49).
3. **efuse silent-absence**: without the CGU rate fix soc_efuse insmod
   fails — no `/proc/jz/efuse/*`, no `/sys/class/misc/
   efuse-string-version` — getmac falls to
   `/proc/sys/kernel/random/uuid`, so S43 still works; the player's efuse
   read stays ENOENT. Both tolerated, fixed by §2.
4. `/sys/class/android_usb/f_uac_sa/*` absent — player continues on
   ENOENT (strace); not a launch blocker (USB gadget = M3 item at most).
5. alsa state files absent on first boot; player tolerates. The
   sound-card chain tail should load after the DHD fix even without the
   AIC engine.
6. leds `/sys/class/leds/{red,blue}` come from leds_pwm_add.ko (cascade
   oops #3) — loads after the DHD fix; then needs the PWM stub.
7. `/data` writes (theme_id, user.ini): fine — ubi1 attach works since
   v0.63.
8. The litegui `0.png` SIGBUS seen under qemu-user (RESEARCH_NOTES §8) is
   a qemu-user artifact — not expected in full-system, no action.

### Consolidated next-round queue (evidence-backed, in order)

1. LCD controller stub @0x13050000/0x10000 (+0xa018 busy=0; +0x1004 kick
   → +0x2010 bit17 + INTC 31) — clears the splash oops and the
   pan_display stall.
2. PWM stub @0x134c0000/0x10000 — pre-empts the splash's backlight write.
3. SADC conversion model @0x10070000 + INTC 11 (CHEN-triggered
   conversion, W1C IFLAG, data 0xFFF) — kills the 220 ms SASS timeout
   loop and future pollers.
4. CGU: make `div_ahb2` compute 200 MHz, then EFUSE stub
   @0x13540000/0x100 (trigger/poll/data-window protocol, 16-byte
   CHIP_ID) — `/proc/jz/efuse/efuse_chip_id` = `CHIP_ID: <32 hex>\n`.
5. nand image: `theme:1` at ota+0x20000 (done in
   tools/x1600/make_nand_image.py).
6. (parallel, wifi session) DHD sdio-driver registration — the cascade
   gate for keyboard_adc/leds_pwm/sa_config/sa_earpods/tcs1421/
   sound_card, i.e. for `/dev/sa-config`, leds and `/proc/asound`.
