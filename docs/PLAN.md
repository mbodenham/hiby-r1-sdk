# Plan — QEMU X1600 full-system emulation (v1.1)

STATUS (2026-10-14, after the v0.74 wifi-srom session; worktree
qemu-wifi-srom; supersedes the earlier headers for the wifi item —
**cywdhd now insmods clean and rcS reaches the product app**):

- **M0: DONE.** QEMU builds in-repo (mipsel-softmmu), `X1600` machine type
  registered, `XBurstR2` from upstream, regmap verified disassembly-wise
  against the stock kernel's embedded DTB (docs/x1600-regmap.md).
- **M1: DONE (exit criterion met, v0.23).** The stock kernel boots its
  real head, prints through the emulated UART (earlycon → real ttyS0
  console handoff), and runs the COMPLETE initcall table to
  `alsa_sound_last_init`, panicking only at `VFS: Cannot open root
  device "(null)"` — zero MTD partitions, the named M2 block. Guest
  time runs near real-time (~274 s guest / 300 s wall).
  History: the v0.1–v0.4 BUG_ON was a mis-diagnosis (PC 0x80010400 =
  `run_init_process`, not head.S); a full kallsyms decode pinned the
  real links (`kernel_entry` 0x80585c60, `start_kernel` 0x807a2764) —
  M1-bringup-log v0.5. v0.7: UART earlycon. v0.8–v0.11: bootmem/cmdline
  (PROM table + argv shape). v0.12–v0.14: OST clockevent periodic
  auto-reload. v0.17: OST free-running counter (udelay).
  v0.18–v0.20: **XBurstR2 Config7.WII** — the vendor idle loop
  (`ingenic_wait_irqoff`) WAITs with IE=0 and relies on XBurst waking
  on any pending interrupt; QEMU only woke on takeable interrupts.
  v0.21–v0.23: USB-PHY-bank (0x10078000), SFC (0x13440000), and
  UART0-extension stubs — each pinned by its bus error.
- **M2: CORE DONE — rootfs mounts from emulated SPI-NAND (v0.34).**
  Built the `ingenic_sfc_v2` SFC + SPI-NAND model (CDT command engine,
  FIFO + DMA-descriptor transfers, GD5F1GQ4UC chip, in-flash partition
  table at NAND 0x5800), a real INTC (IRQ delivery to CPU line 2), an RTC
  write-protocol model, and a CGU PLL-lock model — each pinned by a boot
  symptom. `VFS: Mounted root (squashfs) readonly on device 50:2`, then
  devtmpfs and the rcS module-load chain (~14 `soc_*` modules).
  **v0.63:** I2C/AIC/SADC/msc1 stubs + CGU CE-trigger semantics fixed the
  module-load cascade (the "soc_msc park" root cause: oopsed insmods leak
  `dev->mutex`); soc_i2c/soc_aic/soc_adc load clean, both msc hosts
  register, **UBIFS on erased userdata works**, userland runs.
  **v0.64:** MSC0/MSC1 became real jzmmc_v12 host models — msc0 with the
  SDIO wifi card present (BCM43438/AP6212; the wifi is on msc0 — the
  DHD's wifi_platform_bus_enumerate drives jzmmc_manual_detect(0)), msc1
  an empty TF slot.
  **v0.65:** the -34 (-ERANGE) root cause was the RES byte-window: the
  vendor host composes resp[0] from THREE separate RES reads
  (`(RES1<<24)|(RES2<<8)|(RES3&0xff)`), the model returned the same
  value on all three, so CIS bytes landed on the R5 flag bits
  (`&0x100` → -ERANGE per the vendor core's non-upstream masks).
  Fixed with a byte-window RES queue — **the SDIO card now enumerates
  completely** (`mmc0: new SDIO card at address 0001`), CCCR/CIS/FBR1
  reads all complete.
  **v0.66–v0.67 (stubs session, merged to main):** **LCD controller
  stub 0x13050000/0x10000** (persistent regfile; +0xa018 busy=0;
  +0x1004 kick → +0x2010 EOF bit17 + INTC 31 — the old "JPEG stub"
  framing was wrong: cmd_jpeg_display is pure userland fb ioctls, the
  oops was soc_fb bus-erroring on the unmapped LCD block; the IRQ is
  mandatory — pan_display_sync=1 waits on state==2); **SADC conversion
  semantics** (CFG bit n 0→1 → 12-bit 0xFFF sample, W1C IFLAG, INTC 11 —
  kills the 3595× "adc get value timeout" from the sa_sound_switch
  200 ms poller; 0xFFF = correct emulated idle for all consumers);
  **CGU div_ahb2 = 200 MHz + EFUSE stub 0x13540000/0x100** (trigger/
  poll/data-window protocol; soc_efuse's init validates timing from
  clk_get_rate("div_ahb2") — it failed insmod at the old rate BEFORE
  any MMIO; serves `CHIP_ID: <32 hex>`); **AHB2 PWM stub
  0x134c0000/0x10000** (fifth unmapped block, pinned by the
  pwm_backlight DBE the moment the LCD stub landed). **Verified:
  0 bus errors, 0 adc timeouts, EFUSE initcall 0, pwm_backlight
  initcall 0, splash path clean.** Evidence: docs/M2-stubs-log.md
  (v0.66–v0.67); patches 0100–0104; the decoded register protocols and
  the player-launch checklist live in
  docs/research-brief-stubs-player-launch.md.
  **The v0.65 "DHD never registers its sdio driver" fault is
  ROOT-CAUSED** (wifi session; patch 0006, verification in flight):
  the DHD power-up loop arms notify_semaphore via
  dhd_bus_reg_sdio_notify → sdio_func_reg_notify (registers
  dummy_sdmmc_driver), which completes only from dummy_probe when
  `func->num == 2` — the model card advertised NF=1, so no func2 ever
  existed. Fix: the card advertises **NF=2 + FBR2/F2 CIS**.
- **Boot state now (v0.67 main):** all soc modules load clean through
  the stubs; the ONLY remaining faults are the unchanged DHD cascade
  (cywdhd O+ taint → keyboard_adc_multifunc, leds_pwm_add,
  sa_config_module, sa_earpods_adc, tcs1421_add,
  x1600_hiby_r1_sound_card, oopses #1–#6) stalling rcS before the
  theme → `S92_03_start_music_player` sequence. Device model surface
  adds on top of the v0.64 list: **LCD controller (INTC 31), SADC
  conversions (INTC 11), CGU div_ahb2 200 MHz, EFUSE, AHB2 PWM**; the
  nand image now serves `theme:1` at ota+0x20000 (rcS compares the raw
  7 bytes; previously `1      ` → always the else branch).
- **M4 gate live:** `tools/x1600-boot-test.sh` boots the unmodified
  stock firmware, captures the serial window, and diffs a canonical
  message SET + the ordered init-thread SEQUENCE against
  docs/traces/boot-baseline-v0.67.txt. The v0.67 baseline is recorded
  and verified (0 DBE / 0 adc timeouts / EFUSE + pwm initcall 0 / SDIO
  card enumerates).
- **Wifi/DHD (v0.68, this session): the backplane path WORKS.** With
  patches 0006 (NF=2) + 0007 (IOR mirror, fn1 space, CMD53/PIO skeleton)
  + 0008 (fn1 CIS FUNCE max-blksize 64, corrected CMD53 completion
  semantics, chunked backplane window, chipcommon CHIPID badge
  0x1000a9a6), the DHD now: parses the fn1 CIS, sdio_bus_probe sets
  cur_blksize=64, reads the F1 badge successfully
  ("F1 signature read @0x18000000=0x1000a9a6" — the earlier
  0xffffffff/-ENOMEM failure was FUNCE-less max_blksize=0 → blksz=0 →
  sg_alloc_table nents underflow), si_doattach rev=1 routes ai_scan to
  the module's built-in bcm43430_* static core tables (no EROM walk;
  tables extracted into M1-bringup-log v0.68), and walks the enum live
  via the BCM window (SBADDRLOW=b15, MID=[23:16], HIGH=[31:24]; port =
  0x8000|addr&0x7fff): chipcommon 0x18000000, GCI 0x00410000, PMU
  0x00428000. soc_msc completion semantics decoded: the request fn wants
  STAT bit6 CLEAR (v0.65 reading was inverted), drains MSC_RXFIFO 0x38
  itself, then polls STAT bit12 (read) / bit13 (write).
- **Parked blocker:** the DHD spins re-reading GCI+0x29e0..8 and
  PMU+0x4..0x18 (~1.09M requests/60 s boot); the model returns zeros —
  decode of that wait loop is DONE (M1 log v0.69): it is not a GCI/PMU
  poll but the DHD's RAM size walk inside si_doattach - a linear
  word-by-word backplane scan from 0x0 that stops at the first nonzero
  word. Patch 0009 models the real decode (backplane [0x80000,
  0x18000000) reads 0xffffffff, before the chunk-cache lookup) so the
  walk breaks at exactly 0x80000 (512KB SOCSRAM) in ~1.1 s instead of
  walking the 32-bit space for ~4.7 h.
- **Wifi state after the pdma-dmac round (M1 log v0.70-v0.71):** the DMAC
  question is answered - the 512-byte data path is the **MSC controller's
  internal DMA** (MSC_DMAC 0x44 bit0 + MSC_DMADA 0x48 = the descriptor's
  physical address; the descriptor = {dcmd, dat(phys), dln, flags-bit0=end};
  completion = the msc's own IFLG bit15 data-done), NOT the SoC PDMA. The
  SoC PDMA (0x13420000, 16 ch stride 0x40, IRQ block +0x1000, INTC line 3)
  is decoded and modeled too (patch 0010) and is exercised by the AIC
  audio path (PCM0_TX dreq 0x20, the ~250 s channel programming in the
  traces); the audio completion is still future work. The model's CMD53
  data path now stages the phase and completes it on the internal-DMA
  kick, including multi-block phases and the fn-space byte semantics.
  Gate boot-baseline-v0.70 still passes: the probe fails BEFORE any
  512-byte CMD53 is issued, in si_doattach immediately after the RAM-size
  walk (~5.2 s, breaks at 0x80000), with zero further SDIO traffic - the
  DHD's CIS reads would be 512 CMD52 byte reads per fn into fn0's CIS
  space (sdioh_cis_read loops sdioh_sdmmc_card_regread), which the model
  already serves, so the walk (or the check on its result inside
  si_doattach.isra.10 - see M1 log v0.71 for the disassembly pointers)
  is the standing blocker.
- **Wifi state after the srom round (M1 log v0.72-v0.74): RESOLVED —
  cywdhd insmod returns 0, all six cascade oopses gone, rcS runs into
  the product app (patch 0113).** The "RAM walk" was decoded as the AI
  EROM (enumeration ROM) walk: ai_scan reads the EROM pointer at
  chipcommon+0xfc (= 0) and walks 32-bit entries from backplane 0x0
  (get_erom_ent skips invalid entries unboundedly — the model's zero
  SRAM made it read 131k words to the 0x80000 unmapped break, v0.71's
  mystery). The DHD's cold EROM walk structurally cannot count cores
  (the master-wrapper asd match sets s6; ai_scan 0x21a78 skips the
  numcores++ for every wrapper-matched core), so the DHD arms its OWN
  workaround when CCCR 0x03 == 6 (bcmsdh_sdmmc_probe sets alive =
  0x15151515 and card_dev; cywdhd 0x88cb8) and ai_scan then takes the
  static bcm43430_* tables. The model now: serves a 40-entry EROM image
  reproducing the six 43430 cores (from the DHD's own .data tables),
  makes the fn2 IOR bit sticky so the ready==6 check fires, answers the
  AI wrapper registers (ioctrl/resetstatus so ai_iscoreup is true) and
  the SOCSRAM coreinfo/bankinfo (2 banks x 256 KB = 512 KB, matching
  "DHD: dongle ram size is set to 524288"), and mirrors the ChipClkCSR
  ALP request bit (0x08 -> 0x40). Plus the MSC CMD53 TX PIO path (the
  host pushes write bytes through MSC_TXFIFO 0x3c AFTER starting the
  command; the model stages on the command and delivers on the fifo
  writes) — the host driver's per-write warning trio is gone.
  Gate baseline re-recorded as boot-baseline-v0.74 (the six oopses
  replaced by the wifi attach messages), gate PASSes. wlan0 registers
  (MAC 00:90:4c:11:22:33) and parks OFF at init like the driver wants;
  the ifup/firmware-download flow (devreset ON) is future work if the
  trace demands it.
- **Wifi firmware-download round (M1 log v0.83, worktree qemu-wifi-fw,
  patch 0118): the download is skipped by design; the "running
  firmware" chip-side surface is the actual target — traced to the
  first control-packet TX with its data on the wire, parked at the
  kernel's bare -1 from sdio_memcpy_toio.** `ifconfig wlan0 up` (the
  console respawn shell) drives dhd_open -> wl_android_wifi_on ->
  dhd_bus_devreset(0) -> probe attach -> dhdsdio_download_firmware,
  which skips when the module-global alive == 0x15151515 ("skip
  download FW and nv") — armed by sdioh_probe at ready==6, the same
  workaround the warm-table attach requires (the cold EROM walk is
  fatally broken in this build: get_asd's port loop is called with
  qual=1, which (ent & 0xc0) can never match, so numcores drops to 0).
  The flow then needs the model to play the RUNNING chip: v0.83 fixes
  the ChipClkCSR HT handshake (HT_AVAIL_REQ must read back with
  ALP_AVAIL too — SBSDIO_CLKAV wants 0x40|0x80), advertises CCCR 0x08
  SMB (the kernel's sdio_io_rw_ext_helper gates the block path on it),
  adds fn2's CISTPL_FUNCE (max blksize 0x80 = sd_f2_blocksize; without
  it the byte path passes blksz=0 and the TX dies with garbage sg
  counts), enlarges fn2 to the full 17-bit SDIO space (the 384-byte
  control frame = block-mode CMD53 count=3 x 128 at fn2 0x0000, the
  64-byte = byte-mode count=64 at fn2 0x8000) and raises IFLG
  bit15|bit10 on the data-phase completion (the driver's data-phase
  IMASK unmasks only bit10; the threaded handler dispatches on the raw
  bit15). Result: bus_init passes ("enable 0x06, ready 0x06 waited
  0us"), the OOB irq registers (virq 101 = PA08 host-wake), and both
  control-packet TXs land their bytes on the wire through the
  descriptor DMA. Park: the kernel still returns bare -1 from
  sdio_memcpy_toio (a soc_msc.ko cmd/data error code, precisely scoped
  in v0.83); after that the chip side must serve the DHD's control
  protocol (the response packet + the PA08 host-wake assert) for
  "Firmware up". Gate PASS against boot-baseline-v0.75 unchanged.
- **Wifi firmware-download rounds 4-5 (M1 log v0.86-v0.87, worktree
  qemu-wifi-fw2, patch 0119): DONE for the control chain — the control
  exchange completes end-to-end and `ifconfig wlan1 up` returns 0 with
  "Firmware up: op_mode=0x0001" (28 preinit ioctls complete; wlan1
  registers and is operational). The firmware download itself stays
  skipped by the driver design (the v0.83 alive==0x15151515 gate) —
  the download/handshake arc steps are the driver's documented skip,
  not a model gap.** The decode chain that got there: the read-DMA
  completion arrives via IFLG bit31 (the request fn's READ dcmd masks
  bit23 in IMASK — the v0.84 bit23 raise sat pending until
  request_timeout stored -159), the polling READ word-loop needs STAT
  bit6 CLEAR at staging (staging bit6 deadlocked the 4-byte window
  reads — the run15 6.9 GB re-poll flood), the SDPCM control-response
  header needs channel 0 + dataoffset 32 (readframes dispatches the
  ctrl-buffer handler on channel 0 and validates dataoffset >= 12),
  the CDC ioctl id echoes verbatim past 32, byte 9 carries the credit
  watermark (the DHD's credits = (byte9 - tx_seq) mod 256), and the
  iovar surface answers chanspecs (the 2.4 GHz 20 MHz list, the format
  decoded from the DHD's own masks) and per_chan_info (0x3ffe) with
  real payloads. A 10 ms delayed PA08 re-assert after each fn2 frame
  read covers the DHD's dpc_sched-latched txctl wake-skip. The
  TEMP-FW2-DIAG instruments are worktree-only (stripped from 0119);
  the walk keeps a bounded-iteration guard. Gate PASS byte-identical
  against boot-baseline-v0.75 (the userdata volume must stay in the
  erased factory state — re-run tools/x1600/make_nand_image.py after
  worktree boots that populate it; md5 ae41e974…).
- **Status (M3 opening round, v0.75, worktree qemu-player-ui):**
  **the player's first UI frame renders** — the player's first-boot
  Language selection page (简体中文/繁體中文/English/日本語/한국어/
  Français) is on the emulated screen, stable across minutes of
  polling (HMP screendumps on VNC 127.0.0.1:5910). The blocker was
  the SoC PDMA: the hgl graphics layer draws every frame through
  /dev/sa_hgl_dma → an ingenic_dma descriptor chain →
  wait_for_completion on the PDMA IRQ, and the v0.71 model only armed
  channels. v0.75 executes memory-to-memory chains (slot-linked
  32-byte pool descriptors; dln[31:24] = the next descriptor's page
  slot; 0xc9 interleaved row blits, 0xc0 memcpys; MSC-FIFO descriptors
  stay armed) with the IRQ pending register indexed by the client's
  REQUEST LINE (not the hw channel) and a plain-store complement ack,
  plus the LCD engine stop-done IRQ for the blank path. Patch 0114;
  gate baseline re-recorded as boot-baseline-v0.75 (message set
  identical to v0.74), gate PASS. Operational: the SFC model mmaps
  nand-r1.bin read-write — never run two qemu instances from the same
  worktree directory (concurrent runs shred the UBIFS volume);
  rebuild the image with tools/x1600/make_nand_image.py before gate
  runs (the "default file-system created" marker only exists on a
  fresh volume).
- **Status (M3 input round, v0.76, worktree qemu-vnc-input):**
  **the input chain is wired**: QEMU's VNC keyboard/mouse now drives
  the guest's real evdev devices through faithful hardware models
  (pinctrl/GPIO with bank IRQs chained to INTC 14-17, I2C1 with the
  cst8xx touch slave, SADC commanded key ladder; vendored qemu
  621701f = tools/patches/qemu-x1600/
  0115-vnc-input-gpio-keys-cst8xx-sadc.patch). Verified guest-side:
  HMP sendkey lands EV_KEY 114 (VOLUMEDOWN) in event2 and EV_KEY 163
  (NEXTSONG) in event0; the injected panel INT wakes hyn_ts and the
  driver reads the 9-byte touch frame over i2c1 continuously while
  the pointer is held (246 dispatches / 123 reads in one hold) and
  event1 carries the MT-A report stream; the litegui list reacts to
  the touch stream. Boot gate unchanged: x1600-boot-test.sh PASSes
  against boot-baseline-v0.75.txt byte-for-byte.
- **Status (M3 touch round, v0.77, worktree qemu-touch-cal):** the
  tap->select chain WORKS. Decoded litegui's touch path in the stock
  player (the hgl_ts poller 0x4728a0 + event processor 0x472988: the
  mapping is screen = (480 - raw_x, 800 - raw_y), a fixed inversion
  with no scaling/axis swap; MOVE = the ABS_MT record frames, touch-up
  = BTN_TOUCH 0; the press is inferred from the first MOVE) and the
  cst8xx_touch.ko hyn_irq_handler (full/suppressed record alternation
  via a per-record counter whose reset lives in a branch delay slot;
  the lift frame needs event code 2 in byte3 bits7:6). The model now:
  reports the inverted frame (screen latch kept separate from the
  frame coords), keeps the last position + lift code in the lift
  frame, re-asserts the panel INT at 20 ms (~50 Hz) while held, and
  answers the resume work's reg-0xaa wake check (armed by the sleep
  cmd write 0xa5) with 0x00 so enable_irq survives the fb blank.
  Vendored qemu c4eafc7 = tools/patches/qemu-x1600/
  0116-x1600-calibrate-cst8xx-touch-stream-for-litegui-gest.patch.
  Verified: QMP tap at the English row (240,398) of the first-boot
  language picker selects English — the picker advances and the
  resulting wizard screen renders English strings (twice: the true
  first boot and a re-selection on the persisted state); the model
  trail shows press = 8 held-frame reads + one lift frame (count=0,
  b3=0x80). Boot gate PASS on the factory-state nand image (297
  distinct / 158 structural; the nand user_data volume must be in the
  erased factory state for the rcS UBIFS-format marker the gate keys
  on — demo-session writes move the boot into the journal-replay
  window and the gate keys off a different message set).
- **Status (M3 fb-blank/wake round, v0.78, worktree qemu-fb-wake):**
  the blank/wake mechanism DECODED and the model-side wake chain
  VERIFIED. The stock idle policy: ~25-30 s idle -> backlight 0
  write (+ fb_blank(4) in the pre-shutdown volume state -> the hyn
  suspend + disable_irq_nosync(100)), ~5 min idle -> the power-save
  SHUTDOWN (the player exits -> hiby_player.sh reboots). fbNotifier
  fully decoded (cst8xx_touch.ko): only FB_EVENT_BLANK; blank==0 ->
  queue_work_on(hyn_resume_work); blank==4 -> the inlined
  hyn_ts_suspend (disable + the 0xa5 sleep write + the fail print).
  hyn_resume_work decoded: BTN_TOUCH 0 release, then the wake check
  hyn_read(0xaa) 5x vs the probe-time ts+40 (0xff after the probe
  fallback — NOT bss-0) and a SOFT fall-through that runs
  enable_irq unconditionally after ~1 s. The GUI never issues
  FBIOBLANK(0) (no 0x460b constant in the player; the kernel's
  fb_blank callers are only do_fb_ioctl + the fb0/blank sysfs
  store), and its own wake path (the md-gpio-keys bitmap -> the
  litegui 4096/8192/16384 events -> 0x4ec720) is gated on runtime-
  obfuscated settings (6/93) + the wizard app-state — parked as a
  userspace decode, not a model item. Verified live: fb_blank(0)
  via the fb0/blank sysfs re-enables the touch INT (the tap counts
  9 IRQs post-resume); in the post-shutdown boots the blank is
  backlight-only and the touch chain stays alive — QMP tap at the
  English row selects it and the wizard advances (sel_before/
  sel_after.png). The GUI ignores ALL input while blanked (keys and
  touch), so interactivity depends on which blank variant fires;
  the v0.77 model needs NO further change. Boot gate PASS.
- **Remaining to M3 done:** 1. list scroll-follow: the drag moves
  register (the vertical scroll machinery invalidates, horizontal
  drags are correctly ignored) but the language list does not follow
  the finger in the drag shapes tried; a fast fling or a top-row tap
  drops the list into a re-rendered state with per-row radio marks
  (the pull-down/overscroll zone is the likely trigger) — parked.
  2. the audio path (DONE for the model layer, v0.80-v0.82, worktree
  qemu-aic-audio): the AIC register model (0x10079000: FR/CR/SR/FIFO
  port/divider — decoded from soc_aic.ko, NOT the 0x10020000 guess),
  the PDMA AIC slave channels (one descriptor = one ALSA period
  through the FIFO port, req 62/63, per-period IRQs), the codec/sound
  card verified loading (the card maps, aplay enumerates card 0 and
  the full open/hw_params/prepare/trigger flow passes; the "open
  codec dev error!" line is the bluetooth sys-cmd chain, not audio).
  The captured PCM deliverable: /home/matt/kilo-aic/capture.wav
  (0.512 s 16 kHz mono, byte-verified streamed samples via
  X1600_AIC_CAPTURE). Parked: sustained streaming — the stock
  soc_aic/kernel pair's playback period engine cannot fire
  (dma_device+84 holds prep_dma_sg, not the getter the module polls;
  chan+0xa0 never initialized), so aplay blocks after one ring fill
  and exits -EIO; the capture works at the DMA source (details in
  M1-bringup-log v0.80-v0.82). The wifi flow stays optional (the
  player does not block on it).
- Boot evidence lives in docs/M1-bringup-log.md (v0.1–v0.75),
  docs/M2-stubs-log.md (v0.66–v0.67), and
  docs/research-brief-stubs-player-launch.md.

Goal: **boot the byte-identical stock firmware (v1.6 **unmodified** xImage +
rootfs.squashfs) inside QEMU to the player's first UI frame, using it as the
project's regression gate.** Everything we ship gets tested in the VM exactly
as it would flash. This document is the working contract; amendments go into
this file, not into place-lore.

## 0. Prior art search (done online, 2026-10-12)

Findings that changed M0.3 from a task to a shortcut:

**Register map SOLVED in advance** — mainline Linux already defines the whole
X1000-family SoC map in `arch/mips/boot/dts/ingenic/x1000.dtsi` (saved at
`docs/regmap/x1000.dtsi`). The peripheral bases, sizes, IRQ lines, and clock
parents for the entire P1 bank are documented there:
CGU 0x10000000, INTC 0x10001000 (0x50), TCU 0x10002000 (0x1000; wdt@0, pwm@40),
OST 0x12000000, RTC 0x10003000, pinctrl 0x10010000, UART0/1/2 0x10030000/31000/
32000, AIC/I2S 0x10020000, SSI 0x10043000, PDMA 0x13420000, MSC0 0x13450000,
MSC1 0x13460000, MAC 0x134b0000, OTG 0x13500000; CPU node is
"ingenic,xburst-fpu1.0-mxu1.1"; the intc reuses "ingenic,jz4780-intc".
The X1600E is the X1000E-family cut-down; verify two constants (UART0 + INTC)
against the stock kernel's disassembly in M0.3 and the regmap doc is done.

**No prior QEMU Ingenic machine exists** — GitHub repo searches for
"ingenic qemu" return zero device-model repos; the ecosystem has U-Boot trees
(gtxaspec/ingenic-u-boot-xburst1+2, Ingenic-community/uboot-xburst), kernel
trees (XBurst/Linux-XBurst, mainline jz4780/x1000 DTS), even official sources
(IngenicSemiconductor/XBOMX), but no QEMU machine. The plan is greenfield for
the device models — nothing to fork, nothing to duplicate. Reference shape for
the machine skeleton: any SoC machine model with a small MMIO region +
ram-intc (e.g. hw/mips/malta.c structure, trimmed).

**HiBy R1 ecosystem is bigger than our local mod copy**:
- `bidhata/Hiby-R1-Mod` (167 stars) — the local copy is STALE; upstream now has
  updated firmware (PEQ, i18n, audiobook) post our snapshot. Re-pull before
  citing it.
- `MatthewBriggs/hiby-r1-libra` — MIT-licensed ALTERNATIVE firmware (C):
  podcast/audiobook/music stacks, parametric EQ + MSEB workalike, and
  "Custom Kernel — booting is slightly faster". Its music-app and tools/
  directories are a clean-room vantage of the platform syscall surface;
  BACKLOG.md (428 KB) is likely a full analysis. Caution: author states it is
  LLM-written with heavy manual testing ("lots of bugs" WIP).
- `flariut/hiby-r1-mem-corruption-fix` — binary patch notes for the R1 player
  (cover-art decode corruption; 1.7b1) — directly relevant intel for the M3
  player analysis.
- `HanakoLan/r1-play-next` — r1.upt patch pipeline for 1.8b2 (no HiBy code
  redistributed) — a second reference for .upt tooling.
- `RockinProjex/HiBy-R1-Files` — decompiled 1.6 file tree (we already unpack).
- `BasEijs/hiby-r1-wireless-sync`, `hiby-modding/Meowby-R1` (nix build,
  codeberg mirror) — custom-firmware builds; a possible kernel-rebuild recipe
  to mine if the vendor kernel won't boot in QEMU unmodified.

None of these touch QEMU or this plan: no duplicated work to avoid; the delta our
plan adds (emulation as a regression gate) is unique in the ecosystem.

## 0. Breakthrough that reshapes the plan (verified)

Upstream QEMU **already ships XBurst CPU models**:
`tools/vendors/qemu/target/mips/cpu-defs.c.inc` lines 121 (`XBurstR1`) and
347 (`XBurstR2`), each with `ASE_MXU` in `.insn_flags`, and the full
`mxu_translate.c` decoder is present. The XBurst 9-stage core + Ingenic SIMD
are a zero-cost part of the build: **we do not write a CPU.** The risk column
of the original plan was CPU incompatibility — now deleted; the machine is
peripherals-only.

## 1. Strategy

- **Zero-modification firmware rule** — the VM loads the *unmodified stock
  xImage at the stock load address (0x80F00000)*; nothing is recompiled,
  patched, or shimmed. If a device block the kernel probes is missing, the
  machine model grows — never the firmware.
- **Trace-driven modeling** — a device is added only when bring-up *stops*
  on it (kernel boots until it needs a block, that block is next).
  No speculative device models.
- **Datasheet is the machine's source of truth** — the `X1600_E` datasheet
  gives the boot flow, pinout, DDR layout, and feature list (documented
  sections 4–7 of RESEARCH_NOTES.md). It does **NOT** carry the SoC
  internal register map (verified: zero `0x1003xxxx`-style offsets in the
  text). Register addresses come from:
  1. Ingenic family kernel source trees (GPL) — the SoC family shares
     `arch/mips/xburst` state (X1000/X1600-family files: `intc`, `uart`,
     `tcu`, `cpm`). First source or `arch/mips/boot/dts/ingenic/` DTSs.
  2. Disassembly fallback: the stock kernel binary contains its register
     base constants; `mipsel-linux-musl-objdump` already in `tools/vendors`.
- **Fix-point device surface**: the player's real device contract
  (docs/RESEARCH_NOTES.md §7-8, strace-proven) is the **device-model
  checklist**; any SoC block not on that list is not needed for M3.

## 2. Milestone plan (each with a hard exit criterion)

### M0 — build environment + source baseline *(~1-2 days, part-time)*
Tasks (no code):
- [ ] `meson` + `ninja` (apt or pip) + `libglib2.0-dev` `libpixman-1-dev`
      `zlib1g-dev` `gdb-multiarch` — QEMU host build deps.
- [ ] Stock vendor tree already at `tools/vendors/qemu` (rev `615ece3`,
      2026-10-09): confirm `qemu-system-mipsel -machine help` builds and runs
      (stock board), and that the in-tree `XBurstR2` mips model
      (`-cpu xburstr2`) executes basic userland (test via a musl hello in
      the vendor toolchain, snapshot at `hello.mipsel`).
- [ ] Address baseline: pin down reg bases for UART0, TCU, INTC, CPM, SFC,
      MSC/SD from an Ingenic-family GPL tree or via stock-kernel binary
      disassembly; record in `docs/x1600-regmap.md` (one file, all bases,
      each with a source line).
- [ ] The device `adb` up is STILL wanted the day a debug toggle is found
      (`/proc/mtd` + `dmesg` from real silicon is a plan-quality leak that
      beats every source guess for the boot stage); it is a "helpful"
      item, not a blocker.

Exit: qemu builds, hello.mipsel runs under `-cpu xburstr2`,
regmap doc exists.

### M1 — machine skeleton + kernel early console *(DONE, v0.23)*
Tasks:
- [x] `hw/mips/x1600.c` machine: DDR region + stub machine state +
      `-bios`-less direct-kernel-load (QEMU `-kernel` path), initial
      `-cpu xburstr2`.
- [x] Device model list **for this milestone only**: INTC stub, UART0
      (serial_mm + SCR seed + ext stub), OST clockevent (TCU stayed
      stubbed — the vendor tick is the OST), CGU gate stub — plus the
      trace-driven additions: TCSM0 RAM, USB-PHY bank, SFC stub, and
      the XBurstR2 Config7.WII idle-wake fix.
- [x] Earlycon validate loop: passed — full dmesg through the real
      ttyS0 console (see M1-bringup-log).
- [x] Crash-fwd: everything after earlycon that panics is the NEXT M1
      unit. (panic message = task list.)

Exit MET (v0.23): kernel boots to the end of init and panics on the
named M2 block (`VFS: Cannot open root device "(null)"`, zero MTD
partitions) — exactly the queued M2 task.

### M2 — rootfs reachable at the stock layout *(core DONE v0.34)*
Done:
- [x] mtd + SFC/NAND backend: SFC controller + SPI-NAND model (CDT
      engine, FIFO/DMA, GD5F1GQ4UC) + `nand-r1.bin` image (stock
      `/proc/mtd` shape, in-flash partition table at 0x5800) + INTC/RTC/
      CGU models. **Rootfs mounts (squashfs, device 50:2).**
- [x] Boot-selection mtd-5 "ota" partition modelled in the image
      (`ota:kernel` flag + theme id at +0x20000), so theme/boot state is
      present in-guest.

Remaining — Phase 1: get rcS past the modules to the player launch
*(~1–2 days at current pace; each step verify-then-next, trace-driven)*:
- [x] **1. MSC probe park ROOT-CAUSED (v0.63)** — not an MSC event: the
      oopsed soc_i2c/soc_aic insmods died holding `dev->mutex` (4.4
      `__driver_attach` holds it across probes); soc_msc blocked on the
      leaked lock. Fixed by the I2C/AIC/SADC/msc1 stubs + CGU CE-trigger
      semantics; both msc hosts now register.
- [ ] **2. MSC0/MSC1 host models + SDIO wifi card** — MODELS BUILT
      (v0.64, qemu e282fd9 / patch 0005; msc0 @0x13450000 = wifi SDIO
      card BCM43438, CMD5/CMD3/CMD7/13/52 + CMD52 CCCR/CIS; msc1
      @0x13460000 = empty TF slot, fast timeouts. Correction: the wifi
      is on **msc0**, not msc1 — the DHD's wifi_platform_bus_enumerate
      drives jzmmc_manual_detect(0)). Remaining: the mmc core reaches
      SDIO card init but fails -34 (-ERANGE, R5_OUT_OF_RANGE) at the
      CMD52/CCCR stage — decode soc_msc.ko's resp[0] handling + the
      vendor core's R5_* masks, fix the RES layout in x1600.c.
      *verify: cywdhd returns 0, no page-fault cascade, rcS proceeds*
- [x] **3. I2C + AIC + SADC stubs** — DONE (v0.63); SADC minimal conversion semantics DONE (v0.67 stubs session: CFG-bit-triggered conversions + INTC 11; the 220 ms spam is gone).
- [x] **4. EFUSE stub** — DONE (v0.67 stubs session: CGU div_ahb2=200 MHz seed
      + 0x13540000 read-protocol stub; soc_efuse initcall 0, serves chip id).
- [x] **5. UBI on erased userdata** — DONE (v0.63): ubi1 attaches mtd6,
      empty-device path forms the volume, UBIFS created.
- [x] **6. JPEG block stub 0x13050000** — DONE (v0.67 stubs session: it is
      the LCD controller; regfile + kick→EOF + INTC 31; splash oops gone;
      AHB2 PWM 0x134c0000 stubbed too, pinned by the same session).
- [ ] **7. Theme + splash** (mtd5 ota/theme already in the image)
  - 🏁 *Milestone: `S92_03_start_music_player` execs `hiby_player`*

Exit (M2): rootfs mounts (DONE); rcS runs to the player's attempt;
boot identical to flashing stock.

### M3 — player UI runs *(core DONE v0.75 — the first UI frame renders)*
Phase 2 — player runs, UI visible:
- [x] Walk the player's known probe sequence (fb0 → input → sa-config
      → efuse → mtd5) fixing each fault as it appears — all of those
      load/open clean; the REAL blocker was elsewhere: the hgl blit
      path (write() to /dev/sa_hgl_dma → dmaengine → SoC PDMA
      completion) blocked forever (v0.75, patch 0114)
- [x] **/dev/fb0**: soc_fb serves the framebuffer without panel init
      (fb_bpp=16, fb_buffers=2, rmem-backed; the live display surface
      reads the panned descriptor — patch 0112, v0.70)
- [x] **See the UI**: the player's first-boot Language selection page
      renders on the live display (HMP screendumps; VNC feed for the
      manager to eyeball)
- [ ] Input: keyboard via GPIO (loaded); touch cst8xx I2C slave only
      if interaction is wanted — the GUI is alive (wchan poll) and the
      power-saving blank path completes; synthetic input events are
      the next step for interacting with the first-boot flow

Phase 3 — sound (the one real model left):
- [ ] **AIC + PDMA audio engine**: ALSA PCM → AIC regs → DMA →
      CS43131 codec (I2C sink). The PDMA side now COMPLETES chains
      (v0.75) — the PCM channel arms will deliver IRQs; the AIC
      register model itself ("open codec dev error!" at player start)
      is still a stub and is the remaining work. Player runs without
      it first (strace: degrades gracefully)

Exit: UI renders (**DONE for the first frame**; the regression gate
any OS change → repack → boot in VM → screen renders still needs a
scripted fb readback, tools/fb-dump.py works off the +0x1000 tap).

Ranked risks (updated with M2 velocity data): (a) the R5/-ERANGE
CMD52/CCCR decode being weirder than a RES byte-layout fix (fallback:
empirically model whichever R5 flag bits the vendor core checks);
(b) UBI-on-erased-mtd edge cases; (c) player hard-needing audio at
startup (evidence says graceful); (d) fb0 without panel init (soc_fb
loading clean suggests it works). The original 1–2 week estimate
predates velocity data; SFC (hardest model so far) took ~1 day.

### M4 — continuous regression gate *(ongoing)*
- [x] `tools/x1600-boot-test.sh` — boot VM with timeout, capture the
      dmesg window, diff against the recorded per-version baseline;
      fail on earlycon mismatch. Runs on every firmware repackage.
      (Baseline for the v0.65 machine state: docs/traces/boot-baseline-v0.65.txt)
- [ ] Later: DVFS/CPM adjustments, battery/USB-mode testing, timing
      profiling — unlockable now that the VM reproduces the boot
      exactly.
- [ ] Keep Tier B as the fast config-only sandbox; it is NOT part of
      kernel work.

## 3. What we will NOT do (respecting spot-limits)

- **No proot work** (the old harness for the sandbox is shelved; does
  not apply to kernel bring-up).
- **No speculative device models** past the boot chain: each modeled
  block is traced to a boot stop (serial message naming it) before
  being built.
- **No firmware modification / flashing** for this project (Tier B
  sandbox and the VM both run unmodified firmware).
- **No storage models not in the boot path**: the_MSC/TF model is
  only added at the point the kernel calls it for the rootfs (M2),
  not before.

## 4. Risk register

| # | Risk | Grade | Mitigation |
|---|---|---|---|
| R1 | Datasheet carries NO SoC register map (pinout only, verified) | Real | Ingenic family trees (GPL) or kernel-binary constants; regmap doc = Task M0.3 |
| R2 | Vendor 4.4.94+ kernel plays clock games that Ingenic mainline doesn't (the reason plaintext boots fail) | Real | Disassembly fallback already in the toolchain; the vendor tree we reverse here is *the* target of the plan |
| R3 | XBurstR2 model corner-cases (CP0/CAM gating in the vendor kernel) vs upstream model behaviors | Medium | QEMU is our tree; the model is upstream-close; the vendor kernel was previously verified to pass most 4.4 Ingenic tests |
| R4 | Time-boxing slips | Ongoing | Every milestone's exit is a *concrete* rendering: stuck = kernel-visible crash, never a "no output" state |
| R5 | Device `adb` stays unavailable | Medium | Not a blocker for any milestone; only for cross-checking `/proc/mtd` + dmesg without guesswork |

## 5. Decisions locked in this document

- The plan is the project's regression approach; Tier B remains the
  config-only sandbox (not for kernel work; hazmat for the kernel = off).
- The mk of "stock binary" is the same as Tier B's: unmodified
  firmware bytes only (the whole premise of the firmware being under
  our control here).
- The project uses the stock boot sequence (not QEMU -bios, not
  re-generated SPLs): BootROM + SPL is QEMU-mock-contained.

## 6. Immediate next actions (M0, in order)

1. `sudo apt-get install -y meson ninja-build libglib2.0-dev
    libpixman-1-dev zlib1g-dev gdb-multiarch` — environment gap
    **needs user run (sudo)**.
2. Confirm the vendor tree hosts works: `cd tools/vendors/qemu &&
    ./configure --target-list=mipsel-softmmu --enable-user 2>&1 | tail`
    — a real build baseline (builds slowly but clearly).
3. Reg-map extraction: use GPL-released Ingenic kernel trees or
    objdump the vendor kernel binary (`mipsel-linux-musl-objdump` is
    already in `tools/vendors`); document addresses in
    `docs/x1600-regmap.md`.
4. PIT stop: grab `/proc/mtd` + `dmesg` the moment a debug toggle is
    available on the device (improves the plan's accuracy; not
    blocking).

-- recorded so the plan document is actionable, not aspirational.

- **Status (M3 listview-plane round, v0.79, worktree
  qemu-listview-plane):** the "not listview plane then listview
  refresh fail" console line DECODED and reclassified: it is a benign
  create-ordering artifact of the stock litegui, NOT the M3 freeze.
  The print's three emission sites (hiby_player 0x495588/0x4959fc/
  0x499bb0, print helper 0x465fa0 with the tag "lg_listview_create")
  all reduce to one check: the registry lookup 0x4f13a0 (list at
  object+700, lock/unlock vtable+712/+716, strcmp on *(node+8)) fails
  to find the listview widget under its parent plane/layout tree —
  the widget's create-time refresh runs BEFORE the widget is attached
  ("not [on] listview plane"), the refresh bails, and the widget
  refreshes normally once attached. Registry objects are the parsed
  litegui layout nodes (constructor 0x4f0bd0 loads
  "z:\layout\%stheme%d\main.json" -> /usr/resource/layout/theme1/).
  Kill-shot evidence: the SAME print appears TEN times in the v0.78
  round's boots (console.txt) where the QMP tap->select chain was
  verified working, and in the v0.75 first-render runs; it is present
  in every boot of the stock firmware, working or not. No model
  capability is missing; nothing to fix without firmware
  modification (forbidden). The REAL interactivity wall remains the
  v0.78 blanked-state gate, and this round PINNED it precisely with
  guest strace: the player's touch poller (main thread, poll
  {event1, timerfd} 33 ms, exactly the v0.77 structure) READS every
  tap's full MT-A frame (X=240/Y=403 for a screen-(240,398) tap) and
  litegui then DISCARDS them before any draw while the GUI is in its
  blanked state (no fb ioctl, screendumps identical); the wake path
  is settings-gated at the wizard (POWER via PC31 retested — no
  reaction). **The recipe correction that unblocked the tap: QMP
  input-send-event abs values are VNC-normalized 0..0x7fff, not panel
  coords — the English row at screen (240,398) is abs (16384,16282);
  raw 240 scales to 240*480>>15 = 3 and misses the list entirely
  (this is what the earlier "(240,398) never processed" attempts
  actually hit).** With the corrected recipe and a tap INSIDE the
  pre-blank window (the picker renders at ~t+20-25 s, the idle blank
  fires ~30 s later), the wizard ADVANCES on this build: i_before
  (the 6-row picker) -> i_after (title + rows re-laid + the bottom
  third dark = the next page rendering) -> i_settled, plus the
  language-applied GUI re-init (lg_guimain: lg_activity_mng_init +
  lg_ial_init) in the console. Evidence: /tmp/kilo/ui2/i_before.png,
  i_after.png, i_settled.png. M3 verdict: the stock picker IS
  interactive on the emulated device (as on the real device: a real
  user taps within the idle window); the blanked-state freeze is
  faithful device behavior whose only escape is the stock 5-min
  power-save shutdown reboot. No model change required this round
  (the vendored qemu diff is empty; no 0117 patch).
  - New operational hazards recorded: kill -9 of hiby_player during
    active blits leaks the hgl DMA pool in rmem_manager for the rest
    of the boot (every later player start fails "sahd_open: malloc
    hgl memory error"; rmmod/insmod of sa_hgl_dma does NOT recover —
    the pool lives in rmem_manager shared with soc_fb; recovery =
    guest reboot), and the guest has no fb_blank(4)-free shortcut:
    `reboot -f` from the console halts a -no-reboot VM (restart the
    qemu process instead).
- **Status (M3 BT round, v0.84, worktree qemu-bt-bluez, patch 0123):**
  the timezone-freeze's root cause is fixed in the BT lane. The stock
  S80_bt_init chain (brcm_patchram_plus over /dev/ttyS0 = uart0, then
  TIOCSETD(N_HCI) + HCIUARTSETPROTO(H4)) never completed because nothing
  answered the UART: the guest sent HCI_Reset every 4 s forever (the
  patchram's SIGALRM retry — the pre-fix ttyS0 capture is exactly 69 ×
  `01 03 0c 00`), hci0 never appeared, and the player's embedded bluez
  client asserted `adapter_get_properties (ADAPTER_IS(self))` and
  crash-looped, starving the wizard at the timezone screen. The new
  `chardev-x1600bt` responder on uart0 answers the full byte-exact
  patchram protocol (0x0C03 reset, 0xFC18 baud 3000000, 0xFC2E minidriver,
  181×0xFC4C RAM blocks + 0xFC4E launch from
  BCM4343A1_001.002.009.1010.1030.hcd, post-launch reset/baud, 0xFC01
  BD_ADDR remembered and reported back, 0xFC27 LPM) and the 4.4 kernel's
  open-time init surface (1003 1001 1009 1005 0c23 0c14 0c25 0c38 0c39
  0c05 0c16 1002 0c01 0c1c 0c47 0c24 — all must complete status 0, since
  __hci_req_sync reports the last command's status as the sync result).
  Verified: download 207 VS commands + kernel init 235 controller
  commands, zero unknowns; `hciconfig -a` in the respawn shell shows
  `hci0 Type: Primary Bus: UART, BD Address 4C:BC:98:B0:<rand>` (the
  patchram-written address echoed back), /sys/class/bluetooth/hci0
  exists; bluetoothd powers the adapter (Powered 1->1, Alias accepted);
  **zero adapter.c assertions across every boot since the fix** (the
  pre-fix console aborted every ~2 s); gate PASS ×2 (with a freshly
  regenerated nand image — see the drift note below). Wizard evidence:
  language tap advances to Region, region tap advances into the Time
  zone page (the former freeze point) rendering Beijing/Urumqi rows
  with the console clean — screendumps /tmp/kilo/bt/v_after_lang.png +
  v_after_region.png. RESIDUAL (parked, input/display lane): the tz
  page's own row tap does not advance — full-process strace in the
  guest shows the player reads nothing but its timerfd during tz-page
  taps and `od /dev/input/event1` reads 0 bytes (the kernel hyn_ts
  chain delivers no events by then; one `hyn_ts_suspend ... ret=-145`
  in dmesg), i.e. the touch chain dies ~2 s after the last accepted
  tap — the v0.78 blanked-state/input wall territory, not the BT path.
  - Operational notes for the integrator: (1) **the nand image is the
    guest's persistence layer** — every boot dirties the cwd's
    nand-r1.bin (UBIFS journal replay changes the next boot's window:
    "UBIFS recovery needed/mounted" instead of the fresh-format
    marker), so re-run `tools/x1600/make_nand_image.py
    unpacked/1.6/nand-r1.bin unpacked/1.6/xImage
    unpacked/1.6/rootfs.squashfs` before recording or checking a gate;
    the shared demo VM boots with cwd = the main repo and drifts MAIN's
    nand-r1.bin the same way. (2) The respawn shell on the ttyS2 console
    (`console::respawn:-/bin/sh`) is reachable via
    `-serial telnet:...,server,nowait` (or a socket chardev with
    `logfile=` to keep the capture tee'd — the demo VM now runs that
    shape: telnet 127.0.0.1:4448 + logfile /tmp/kilo/livedisp/console.log);
    guest tools include strace, hciconfig, hcitool, od — enough to
    diagnose in-guest without model instrumentation.

- **Status (M3 tz round, v0.88-v0.89, worktree qemu-wizard-tz, patch
  0124):** the tz-row flow is decoded and the freeze is pinned to a
  litegui-level event drop, NOT the input chain. Two deliverables plus
  one regression fix:
  - **REGRESSION FOUND AND FIXED:** main's vendored qemu had LOST the
    BT HCI responder — the wifi round's ded9cc0 rewrite of
    hw/mips/x1600.c (337+/471-) removed the 378 lines that 2550167
    (patch 0123) added; every merged-state boot since has the bluez
    adapter.c assert-flood back (hci0 never registers, the patchram
    retries HCI_Reset forever). The BT diff applies cleanly to the
    current tree; restored in the vendored worktree (commit 956210a,
    converges with the still-correct exported 0123) and verified
    across 5 fresh boots (zero assertions, the 207-VS download +
    kernel init complete, bt_init reaches /tmp/bt_init_ok). **The
    integrator should verify the vendored tree actually contains the
    0123 code after applying the patch stack** — the drift was
    invisible in git (the exported patch file survived).
  - **The tz flow decoded (player binary):** language → region →
    time-zone pages; the region click handler stores setting 129 AND
    pre-stores the default zone into setting 130 via the tzlookup.xml
    parser; the tz-page row click handler (0x4d3740) stores the
    override into setting 130 and advances. The tz applier
    (0x469be0, on-change of setting 348) runs
    `ln -sf /usr/share/zoneinfo/<id> /usr/data/localtime` +
    `date +"%Z %z" > /data/time_zone`, then (wifi state COMPLETE)
    ntpdate + hwclock -w --utc. The tz listviews reference
    z:\layout\theme1\listview\vg_listview_{zone_info,select_zone,
    time_zone,region}.listview — none exist in the squashfs (the real
    device ships the same rootfs and works, so they are not the
    differentiator); the rows render from the generic list geometry
    (coordinate/list.ini name/name2 fields).
  - **The freeze pinned by live trace:** the touch chain is ALIVE on
    the tz page (hyn_ts IRQ counts rise, /dev/input/event1 delivers
    the full MT-A stream to an od reader armed on the tz page) and the
    player's tz click handler never runs its first store
    (/usr/data/user.ini byte-identical across the tap; the applier's
    files never appear; the console silent). The drop is inside
    litegui's widget dispatch — the tz listview's items lack the
    click wiring the region page's items have (handler gate = the
    item's owner back-pointer chain *(item+248)→+124). NEXT DECODE
    TARGET (parked with this precise entry): 0x4961e0's
    name/style resolution for ("vg_listview_time_zone", L"time_zone")
    vs the working ("vg_listview_region", L"region") — the item
    template scan loop over the 115-entry widget-name pattern table at
    0x77bf68. The QMP abs convention is settled and documented:
    0..0x7fff fractions of the panel (raw screen pixels land at the
    180°-mirrored point and select the wrong row — proven live: a raw
    (240,398) tap selected Français).
  - **patch 0124 (for the manager's harness):** QemuInputHandler
    abs_info (x/y min/max 0..0x7fff) + QMP input-send-event abs
    scaling through it — makes the QMP abs convention explicit and
    predictable; identity for the registered ranges. Gate: PASS ×2
    against the re-recorded docs/traces/boot-baseline-v0.89.txt (the
    BT+wifi dmesg changed the window; the gate normalize() now
    canonicalizes the two run-to-run adjacent-swap print races).
    Wizard evidence this round: language→region→tz page reached
    in-window repeatedly (screendumps /tmp/kilo/tz/w1-w2, x0-x3, y1,
    v1_final).

## 7. Snapshot/iteration infrastructure (v0.89, worktree
qemu-vmstate-snapshots, patch 0124)

- **Status (vmstate round, v0.89):** every custom device in
  hw/mips/x1600.c now carries a VMStateDescription (version_id 1) —
  OST, CGU, MSC0+MSC1 (regfile, staged RES window, CCCR/CIS, fn1/fn2
  windows, staged CMD53 phase, staged control response, PA08 re-kick
  timer, and the backplane windows moved inline so they snapshot),
  AIC, PDMA, INTC (QOM dc->vmsd), RTC, SADC, GPIO, I2C1/cst8xx,
  EFUSE, LCD (regfile + backend_seen + fb timer; the surface/fb copy
  are runtime-rebuildable), SFC (control window + CDT + page cache +
  feature regs; the NAND array stays the shared image file, re-mmap'd
  by the restore side), and every stub regfile. Timers reload their
  deadlines from the stream (VMSTATE_TIMER_PTR; the lazily-created
  LCD/I2C timers are now created eagerly in x1600_mach_init — no
  functional change). post_load hooks recompute IRQ levels
  (MSC/INTC/SADC/GPIO/SFC/LCD).
- **Verified end-to-end (migrate path; the machine has no qcow2 so
  HMP savevm is unavailable):** boot → picker → `stop` → HMP
  `migrate file:...` (57 MB stream) → `quit` → restart with
  `-incoming file:...` → paused (as saved) → `cont` → the picker
  screendump is BYTE-IDENTICAL to the pre-save dump → a QMP tap
  (abs 16384,16282 + left press/release) ADVANCES the wizard
  (post-tap screendump differs). Recipe committed as
  tools/x1600-snapshot-vm.sh (save/resume/tap/dump/stop; VNC :11 so
  the persistent hiby-live-demo VM on :0 is untouched).
- **The gate:** tools/x1600-boot-test.sh PASS against the committed
  v0.88 baseline, NO re-record — the final run's diff-multiset AND
  diff-struct are both 0 bytes (evidence /tmp/kilo/vm/
  boot-gate-PASS/). Tool fixes that made the committed baseline
  verifiable (it was recorded as a used-image FULL-CYCLE window: no
  "default file-system created" marker, so the verify path's marker
  requirement could never pass): accept `reboot: System halted` as
  the alternate terminal state, timeout 360→480 s, strip only the
  baseline header (the old grep -v '^#' ate shell-prompt "# " window
  lines), and extend the normalizer with the volatile-value/variant
  classes a full-cycle window needs (heap pointers, async-flush burst
  split points, prompt "#" echoes, trailing spaces, the per-image
  UBIFS UUID / per-boot BT_MACADDR / mdev pidfile pid, and the
  scheduling-flip debug-chatter drop list). Comparison semantics
  unchanged. Gate-image caveat: the marker only prints on a pristine
  nand image (make_nand_image.py, md5 ae41e974...); this round's gate
  ran a used-image full cycle to match the baseline's shape — a
  killed mid-boot run leaves the userdata dirty (the next boot dumps
  UBI PEB hexdumps) — rebuild the image before a gate run.
- **Known edge (parked):** saving mid-rcS with the userdata journal
  in flight reproduced one UBIFS read-only transition after restore
  (error -22 at a userdata inode read); the recipe saves at the quiet
  picker and that path is clean.
- **Flagged for the manager:** the merged source has no uart0 BT-side
  HCI responder (the 2550167 commit was dropped by the ded9cc0
  rewrite; the binary matches the source, so the state is
  self-consistent, but the 0123 BT patch no longer applies and the
  post-50 s console shows the documented bluez adapter.c
  crash-loop). The CS43131 codec and I2C0/2 slaves are plain stubs
  (the device list in the round brief was aspirational on those).
- **Status (M3 tz-dispatch round, v0.90, worktree qemu-tz-dispatch):**
  the parked 0x4961e0 decode was completed and the freeze picture
  materially revised; the tz drop itself is now cleanly isolated but
  still unlocalized. Deliverables this round:
  - **A SECOND, INDEPENDENT FREEZE DECODED AND FIXED (ops-level):** the
    shared nand image's ubi1 volume can carry a corrupt UBIFS node; the
    first background commit (~30 s after mount) hits it, UBIFS switches
    READ-ONLY, and every /usr/data write then fails EROFS — after which
    ALL wizard-page input dies GUI-wide (proven: the region page, alive
    pre-flip, is dead post-flip). The tz page was simply where prior
    rounds' taps landed after the +30 s commit. The worktree image had
    diverged from main's via snapshot-restore misuse (restoring an older
    snapshot over a nand file carrying newer UBIFS writes corrupts the
    journal — the recipe's QUIET-moment warning is exactly this);
    re-provisioned from main's clean copy (data fix only, zero
    model/firmware change). Ops rule for the next rounds: re-save the
    snapshot after any write-heavy pass before reusing it as a restore
    base.
  - **The parked static decode completed:** lg_listview_create
    (0x4961e0) fully mapped (the 115-entry pattern table at 0x77d150,
    the item-template lookup "vg_listview_item_%s", the error prints
    that never fire); the wizard's shared create dispatcher 0x4d2fc0
    (screen keys "region"/"zone" → symmetric creates); the descriptor
    table layout (0x867b00, stride 0x20c, click at +0x154); the litegui
    class records ("lg_viewgroup", ctor 0x457800) with the runtime
    callback block at rec+0x150..0x174 and the page click at rec+0x168;
    the name uniquifier 0x430f80 (start counter 150 at 0x4c0d6c/0x4c15a4)
    and the tz page's ##151-suffixed duplicate back-bar names.
  - **The tz drop re-proven on a CLEAN image:** with the RO-flip removed
    (clean image, no UBIFS errors), language → region works and the tz
    row tap STILL does not advance (Beijing and the observable
    Urumqi-store test both dead; a 10-point full-screen hold-tap sweep
    shows zero pixel reaction; keys dead too). The runtime memsave shows
    the tz viewgroup fully wired (click slot 0x4d3740 at +0x168) — the
    drop is upstream in litegui's event routing, exactly the parked
    v0.89 conclusion, now proven independent of the UBIFS state.
  - **Parked leads (next decode targets):** the listview tap→select
    state object (v0.77's 0x4335c0 mode-6 gates state+284/288/324, the
    select callbacks at state+664/668 — the state object is NOT the
    inner widget; find and diff it per page); the generated per-page
    heap thunks cross-linked at viewgroup+0x7c / inner+228 (code not in
    the binary — find their generator); the ##151 duplicate-name
    routing question; the region-list scroll anomaly (a boot entered
    with the region list scrolled two rows).
  - **Gate:** x1600-boot-test.sh did NOT pass this round — not from a
    code change (zero vendored edits) but from the gate's terminal
    marker being the first-boot UBIFS-format line, which cannot print
    on the current main-line image (the userdata is already formatted;
    the demo VM's live file). See the M1 log v0.90 gate note for the
    three runs and the condition for a real PASS (a pristine
    as-extracted userdata volume, or a deliberate re-baseline).

- **Status (M3 tap-regression bisect round, v0.91, worktree
  qemu-tap-regress):** the manager's "QMP tap no longer selects / the
  user cannot interact" report was bisected to a NON-regression: the
  tap-delivery chain (QMP → x1600_input_event → cst8xx MT-A → hyn IRQ →
  driver reads → evdev → litegui) is INTACT on current main, verified
  end-to-end with TEMP-REG-DIAG (since stripped) and two live in-window
  selects (the wizard advanced to the region page in English on a
  PRISTINE first-boot image, both with 0125's abs_info and with it
  A/B-removed — the metadata is an exact identity, INPUT_EVENT_ABS_
  {MIN,MAX}=0/0x7fff and scale(v,0,0x7fff,0,0x7fff)=v, so 0125 and the
  0117-0126 suspect set are exonerated). The symptom is the stock
  firmware's idle blank: the interactive window is last-input + ~30 s
  (with zero input the anchor is ~GUI init at t≈28 s, the blank at
  t≈57-59 s — the same ~30 s gap the v0.79 boots had; the 0120/0121 SFC
  acceleration moved the GUI start ~27 s earlier on the clock without
  shrinking the window). Post-blank, every model stage still fires
  (INT pulses stream) but the driver performs zero i2c1 reads — its IRQ
  is disabled by hyn_ts_suspend and litegui's wizard wake gates never
  unblank (Right/Up/Down/Enter/Esc all dead post-blank, re-verified with
  the 0xaa resume marker; the early "resume after right" note was a
  grep false positive on SFC flash row 0xaa00 addresses). The feed
  shows a BRIGHT picker the whole cycle (the LCD surface does not render
  the FBIOBLANK(4) state), so the dead window is invisible — that is
  the whole "user cannot interact" experience. Practical, faithful
  levers recorded in the M1 log v0.91: tap within ~25 s of the render
  or of the last input; a keeper key every ≤25 s postpones the blank
  (verified last-input+30 s exactly, twice); after the blank only the
  stock 5-min shutdown/reboot re-opens the window. Recommended next
  lever (out of the touch round's remit): model the blanked visual
  state (backlight off) in the LCD surface so the window is visible.
  Gate: tools/x1600-boot-test.sh PASS on the pristine image (296
  distinct / 158 structural vs boot-baseline-v0.89.txt), confirming the
  v0.90 gate-note prediction; no baseline re-record (empty model diff,
  unchanged dmesg). Zero vendored changes this round (no 0128 patch);
  docs only.
