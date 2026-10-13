# M2-exit stubs log — LCD / SADC / CGU+EFUSE / PWM (QEMU X1600E)

Session of 2026-10-13 (seventh bring-up session, parallel worktree).
Scope: the M2-exit stub queue pinned by boot symptoms — the "JPEG block"
(that is really the LCD controller), the SADC 220 ms poller spam, and the
EFUSE probe — plus the AHB2 PWM block the trace pinned mid-session.
Working tree: an isolated checkout of `tools/vendors/qemu` (baseline commit
`1c06c36` = the v0.65 model state from the main checkout). All verification
boots ran the UNMODIFIED stock xImage/rootfs (zero-modification firmware
rule); every fix is a machine-model change. Scratch (serial logs) under
/tmp/kilo/stubs/.

Boot command used throughout (serial to file, monitor/display off):

    build/qemu-system-mipsel -M x1600 \
        -kernel ../../../unpacked/1.6/vmlinux.bin \
        -serial file:/tmp/kilo/stubs/<tag>-serial.log \
        -monitor none -display none -no-reboot

(the machine resolves `nand-r1.bin` next to the kernel path; `-d unimp`
stderr captures were used for the MMIO-trace runs).

Method note: this session ran in parallel with the MSC/SDIO wifi session
(its v0.65 RES byte-window model is in the baseline). The manager's
research round (docs/research-brief-stubs-player-launch.md) supplied the
block semantics; this session independently re-decoded the same modules
from the rootfs `.ko`s and confirmed every register/protocol fact below,
with one correction to the brief noted in §2 (SADC trigger polarity).

## v0.66 (2026-10-13): the baseline re-verified + static decodes

Baseline boot (base-serial.log, v0.65 state): 5190 serial lines, 3595 ×
`adc_read_channel_value:adc get value timeout!` (every ~220 ms), the splash
oops `Data bus error, epc == c0153778 jzfb_blank+0x4ac [soc_fb]` at 5.04 s
(Code: `3c03b305 <ac64200c>` = `sw a2,0x200c(0xb3050000)`), and
`EFUSE: failed to get efuse cfg wr_strobe!` → `jz_efuse_init` -1, twice.
The rcS tail stalls exactly as v0.63-v0.65 (DHD cascade oopses #2-#7).

### The "JPEG block" is the LCD controller (block = 0x13050000/0x10000)

cmd_jpeg_display (usr/bin) has zero MMIO — it links libjpeg.so.9 +
libhardware2.so and drives /dev/fb0 ioctls (FBIOGET_*SCREENINFO, mmap,
FBIOPAN_DISPLAY 0x4606, FBIOBLANK 0x4611). The kernel-side bus error came
from `jzfb_blank` (soc_fb.ko) inside the fb ioctl path on behalf of the
splash: first touch `sw` to +0x200c, then reads +0x2010/+0x2014, write
+0x2008, read +0x8000. The stock DTB node is /ahb0/dpu@0x13050000
(ingenic,x1600-dpu, status disabled, IRQ <31>).

Load-bearing semantics from soc_fb.ko (17 `lui reg,0xb305` sites):

1. +0xa018 bit0 = SLCD BUSY — `slcd_wait_busy_us` polls it with 500 us
   sleeps; the model reads it as 0 (self-clears on write).
2. +0x1004 = frame kick — `lcdc_pan_display` stores the frame descriptor
   pointer at +0x1000, then writes 1; the model sets STATE (+0x2010)
   bit17 (EOF) and raises the frame-done IRQ.
3. +0x2008 = W1C of STATE — `jzfb_irq_handler` (request_threaded_irq(39)
   → INTC input 31, hwirq = virq - 8 like SADC 11 → 19) reads +0x2010,
   W1Cs +0x2008 (0x20000 on EOF), sets state=2 and wakes pan_display.
   `pan_display_sync=1` (soc_fb.sh) makes FBIOPAN_DISPLAY wait on
   state==2, so without the IRQ every frame stalls ~100 s then errors —
   the IRQ is mandatory, not cosmetic.

### SADC = 0x10070000 — the 220 ms poller decode

An `-d unimp` trace run (unimp.log, 77 s guest) settled the shape of the
problem: the SADC sees only ~28 accesses per boot (probe/init + one ch3
read attempt); the 220 ms poller does ZERO MMIO — it is an IRQ wait
timing out. The poller is sa_sound_switch's delayed_work
(sass_debounce_time=200 ms) + the 2-jiffy wait budget inside
`adc_read_channel_value` (soc_adc.ko 0x160) = 220 ms at HZ=100.

Register map (soc_adc.ko, hard-coded 0xb0070000; DTB /apb/sadc@10070000,
reg <0x10070000 0x32>, interrupts <11> on core-intc → module virq 19):

    +0x00 CFG      bits[3:0] per-channel enable/start (adc_hal_enable_channel
                   sets bit ch then polls it until set, @0x790-0x7b4);
                   bit9 repeat; bit14 power-optimize; bit15 PEN —
                   enable_controller clears it and polls until 0,
                   disable_controller sets it and polls until 1 (plain RMW
                   persistence satisfies both: boot trace 1-3/16-18)
    +0x08 IMASK    bits[3:0], 1 = masked (module init writes 0xf = mask-all;
                   adc_enable's enable_all_interrupt writes 0)
    +0x0c IFLAG    bits[3:0], write-1-to-clear (clean_all writes x|0xf)
    +0x10 data     ch0 [11:0], ch1 [27:16]   (adc_hal_read_channel_data)
    +0x14 data     ch2 [11:0], ch3 [27:16]
    +0x20 CLKDIV   adc_hal_set_clkdiv ([7:0], [15:8], [31:16])
    +0x24 WAIT     sampling-stable time ([15:0])
    +0x28 REPEAT   repeat-sampling time

Flow: adc_read_channel_value sets pending = 1<<ch, calls
adc_hal_enable_channel (CFG bit write), waits on the IRQ; adc_irq_handler
reads IFLAG, W1Cs the flags, clears pending and wakes; the waiter reads
the sample from +0x10/+0x14. Channels: SASS headset = ch1 (raw range
[2800,3300]), keyboard_adc_multifunc = ch0, sa_earpods_adc = ch2,
cst8xx = ch3 one-shot (<1000 check).

## v0.67 (2026-10-13): the stubs, verified by boot

Five machine-model commits, exported as tools/patches/qemu-x1600/
0100-0104 (vendored qemu commits d0fb481, 9b77590, d8644b9, 5fe1ed3,
5cf252a):

### 0100 — LCD controller stub (0x13050000, 0x10000)

Persistent regfile (covers the jzfb RMW surface: 0x00-0xfc cfg/timing,
descriptors 0x220/0x230-0x244, +0x1000/+0x1004, int/state 0x2000-0x2014,
SLCD window +0xa000-0xa018) with the three semantics above; frame-done
IRQ wired to INTC input 31.
**Verified (v067-serial.log):** the splash oops is GONE — zero
`Data bus error` lines in the whole boot (baseline: 1 at 5.04 s); the
splash completed without the 100 s/pan_display stall (rcS reached
S21/UBIFS at 56.4 s guest vs the baseline's 55.7 s — same schedule, so
FBIOPAN_DISPLAY did not wait).

### 0101 — SADC minimal conversion semantics

The plain v0.63 stub became a conversion model: IMASK +0x08 (1 = masked),
IFLAG +0x0c W1C, IRQ = INTC input 11 asserted while (IFLAG & ~IMASK) != 0,
and **every write that SETS a CFG (+0x00) bit n in [3:0] runs channel n's
conversion synchronously** — latch the 12-bit sample into +0x10/+0x14 and
set IFLAG bit n.

DELTA vs the research brief: the trigger keys on the WRITTEN bit, not a
0→1 edge. Repeat polls rewrite the CFG bit 1→1 (nothing in the driver
clears it) and the IRQ handler W1Cs IFLAG every pass, so an edge-triggered
model re-spams after the first successful read — the first post-fix SASS
poll would have been the only quiet one.

Sample = 0xfff for every channel: raw 4095 is outside SASS's [2800,3300]
headset range (state 0 = correct emulated idle), outside the
keyboard/earpods windows (no phantom keys), passes cst8xx's <1000 check.
CFG bit15 (PEN) toggle+poll semantics are satisfied by plain persistence
(boot trace: init disable_controller = read 0/write 0x8000/read 0x8000
poll-pass; adc_enable's enable_controller = read 0x8000/write 0/read 0).

**Verified (v067-serial.log):** zero `adc get value timeout` lines
(baseline: 3595). The one-time ch1 reads (lcd_lg35583's lcd_id_vol) now
return a value instead of -16-timeout noise.

### 0102 — CGU SPL-shape seed (div_ahb2 = 200 MHz) — the EFUSE prerequisite

The CGU reset state was all-zero, so the vendor clock framework computed
ext-fallback rates (~24 MHz) for every PLL-derived clock. soc_efuse's
insmod fails BEFORE any efuse MMIO: jz_efuse_init (.init.text 0xd4-0x184)
computes rd_adj/rd_strobe/wr_strobe from clk_get_rate("gate_efuse") and
validates period p = 1e9/rate ns against

    (floor(7/p)+1)*p >= 8
    (q1+5+max(floor(35/p)-4-q1,0))*p >= 36          (q1 = floor(7/p))
    9000 <= (q1+1666+max(floor(10000/p)-1666-q1,0)+1)*p < 11001

Valid p = {1,2,3,5,6} ns (this session's independent decode reproduces
the set; p=4 also passes the code check). At ~24 MHz (p=41) the wr check
fails → "EFUSE: failed to get efuse cfg wr_strobe" + initcall -1. The
real h2clk = 200 MHz (p=5).

Seeded reset state (machine model, not guest writes):
- APCR/MPCR/EPCR (+0x10/+0x14/+0x18) = the ingenic-v2 PLL 1.2 GHz config.
  Rate formula (ingenic_v2_pll_recalc_rate, vmlinux.bin 0x80400298):
  rate = ext/(sel*m)/n*p with the hwdesc byte fields sel [10:8],
  m [13:11], n [19:14], p [31:20] and the register offset in hwdesc[0]
  (0x10/0x14/0x18 for apll/mpll/epll). Seed = sel 2, m 3, n 4, p 1200
  from the 24 MHz ext clock = 0x4b011a00. All three PLLs seeded so the
  mux selection is immaterial.
- CPCCR (+0x00) = 0x02005000:
  - ahb2 divider field [15:12] = 5 → div 6. div_ahb2 is a table-less CGU
    divider (the x1600_div table entry pins reg 0x0 = CPCCR, shift 12,
    width 4, flags 0 → div = field + 1).
  - **mux_ahb2 SEL [25:24] = 2 → parent 'mpll'.** The mux_ahb2 table
    entry (x1600_mux table @0x807cb2a0) pins SEL = CPCCR[25:24]; its
    parent list is {<zero-rate entry>, sclka, mpll}. The first seeded
    boot (CPCCR = 0x5000, SEL = 0) still failed wr_strobe with the rate
    ≤ 142 MHz — SEL 0 selects a garbage parent; SEL 2 selects the seeded
    mpll. (Boot-verified discrimination.)
- div_ahb2 = 1.2 GHz / 6 = 200 MHz.

**Verified:** the early banner now prints `apll = 1200000000 ,
mpll = 1200000000` (was 0/0), and `pwm clk source rate 1200000000` (the
PWM clock chain resolves the seeded tree). MSC/SDIO behaviour unchanged
(the sibling's enumeration still completes).

### 0103 — EFUSE stub (0x13540000, size 0x10000 per the DTB)

soc_efuse.ko hard-codes KSEG1 0xb3540000. Read protocol (soc_efuse_read
@0x16c, per ≤32-byte chunk): +0x00 = 0; +0x08 = 0; +0x00 =
(byte_off<<21)|((n-1)<<16); +0x00 |= 1 (start); poll +0x08 bit0 until 1;
copy the data window +0x0c..+0x2b — the driver loads WORDS at +0x0c+4i
and memcpy's the chunk out of them, so the model composes the window
little-endian from the latched array offset.

Segments (9-entry table {byte_off, size, name} at .rodata+0xd8):
CHIP_ID@0x00 16 B (/proc/jz/efuse/efuse_chip_id prints "CHIP_ID: " + 32
hex chars), CUSTOMER_ID@0x10 11 B, TRIM_DATA@0x1b 16 B, SOC_INFO@0x2b
2 B, HIDE_BLK@0x2d 1 B, PROGRAM_PROTECT@0x2e 2 B, CHIP_KEY@0x30 32 B,
USER_KEY@0x50 32 B, NKU@0x70 16 B. Write support not needed:
gpio_efuse_vddq=-1 (the rcS insmod parameter) bails soc_efuse_write
before any MMIO. CHIP_ID = stable non-zero bytes; the first six give
S43wifi's getmac a plausible Ingenic MAC (d0:31:10:16:04:c2).

**Verified (v067-serial.log):** `calling jz_efuse_init ... returned 0
after 1119 usecs` — the wr_strobe prints and the -1 returns are gone
(baseline: two failures). initcall 0 = the proc entries and the
"efuse-string-version" misc device registered.

### 0104 — AHB2 PWM stub (0x134c0000, 0x10000) — trace-driven fifth block

Pinned by the first post-LCD-stub boot (v066-serial.log):
pwm_backlight's insmod died at 4.16 s — `Data bus error, epc ==
c013b174 pwm_set_clk_div+0xd4 [soc_pwm]` ($16 = 0xb34c0040, the +0x40
RMW). soc_pwm.ko hard-codes KSEG1 0xb34c0000 in 16 sites; the block is
/ahb2/pwm@0x134c0000 in the stock DTB. Model: plain persistent regfile
(no polled PWM semantics pinned by the boot). Unblocks pwm_backlight,
the S11 `echo 60 > /sys/class/backlight/backlight_pwm0/brightness`
write and leds_pwm_add's PWM LEDs.
**Verified (v067-serial.log):** `initcall init_module [pwm_backlight]
returned 0 after 1602 usecs` — the 4.16 s oops is gone.

### Boot state after v0.67 (v067-serial.log)

- ZERO `Data bus error`, ZERO `adc get value timeout`, ZERO `wr_strobe`.
- The splash path runs clean (no jzfb oops, no pan_display stall).
- Remaining oopses #1-#6 are the unchanged DHD cascade (cywdhd O+
  taint → keyboard_adc_multifunc, leds_pwm_add, sa_config_module,
  sa_earpods_adc, tcs1421_add, x1600_hiby_r1_sound_card) — the wifi
  session's fault, untouched here per scope.
- The rcS tail stalls at the same post-UBIFS point as the baseline
  (S30+/wifi userland path) — expected; the M2-exit sequence
  (theme → S92_03_start_music_player) still needs the DHD fix.

### Verification summary (dmesg deltas, baseline v0.65 → v0.67)

| Symptom | v0.65 baseline | v0.67 |
|---|---|---|
| Splash oops (jzfb_blank DBE) | 1 @ 5.04 s | 0 |
| adc get value timeout | 3595 | 0 |
| EFUSE wr_strobe / initcall -1 | 2 | 0 (initcall 0) |
| pwm_backlight DBE @ 4.16 s | (pinned in v066) | 0 (initcall 0) |
| Data bus error (total) | 1 | 0 |
| DHD cascade oopses | #2-#7 | #1-#6 (unchanged, wifi session) |

### Next

1. Wifi session: the DHD sdio-driver registration (the cascade gate).
2. After the cascade clears: keyboard_adc/leds_pwm/sa_config/sa_earpods/
   tcs1421/sound_card load; then rcS → theme → S92_03_start_music_player.
3. Player launch followups (research brief §6): BT console pollution
   (ttyS2 swap), the PWM polled semantics if a later stop pins any,
   framebuffer readback hook (LCD +0x1000 descriptor → fb base).
