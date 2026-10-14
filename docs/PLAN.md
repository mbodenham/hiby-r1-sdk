# Plan — QEMU X1600 full-system emulation (v1.1)

STATUS (2026-10-13, after the v0.64 MSC/SDIO session):

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
  SDIO wifi card present, msc1 an empty TF slot; the mmc core sees the
  card but SDIO card init fails -34 at the CMD52/CCCR stage (open).
- **Boot state now (v0.64):** MSC0/MSC1 are real jzmmc_v12 host models
  (qemu e282fd9, exported as patch 0005): **msc0 @0x13450000 (INTC 37)
  carries the SDIO wifi card** (BCM43438/AP6212 — the wifi is on msc0,
  not msc1 as v0.63 guessed: the DHD's wifi_platform_bus_enumerate
  drives jzmmc_manual_detect(0) synchronously), **msc1 @0x13460000
  (INTC 36) is the empty TF slot** completing fast with STAT_TIME_OUT_RES
  (v0.63's 6-s op:55 retry spam gone). The mmc core now sees the wifi
  card (CMD5 OCR handshake OK, SDIO attach starts) but card init fails
  **-34 (-ERANGE, R5_OUT_OF_RANGE) at the CMD52/CCCR stage**, so cywdhd
  still fails (5 power-cycle loops → -19 → re-probe EEXIST → dangling
  device → module-chain tail oopses #2-#7, sound card last) — the rcS
  stall is unchanged. Everything upstream of that still works: all soc
  modules load, touch probes over the I2C stub, UBIFS on erased userdata
  (`UBIFS (ubi1:0): default file-system created`), userland runs. Device
  model surface now: DDR, TCSM0, OST clockevent (line 4), 16550 UART0 +
  ext, SFC+SPI-NAND (line 7), real INTC (→CPU line 2), RTC
  (write-protocol), CGU (PLL-lock + CE-trigger), I2C0-2, AIC, SADC,
  **MSC0 + SDIO card, MSC1 + empty TF**, persistent: TCU, pinctrl,
  UART1-3, PDMA, USB-PHY.
- **Next (M2 exit):** 1. root-cause the R5/-ERANGE at the CMD52/CCCR
  stage (decode soc_msc.ko's resp[0] handling + the vendor core's
  mmc_io_rw_direct_host/R5_* masks — the ONE open fault on the wifi
  path); 2. EFUSE stub (serve efuse_chip_id); 3. SADC minimal conversion
  semantics (clears the 220 ms spam); 4. JPEG stub 0x13050000 (clears
  the splash oops); then rcS reaches theme →
  `S92_03_start_music_player`. Boot evidence: docs/M1-bringup-log.md
  v0.64.
- Boot evidence, register dumps, and every boot-stop decode live in
  docs/M1-bringup-log.md (v0.1 through v0.64, incl. the M2 section).

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

### M3 — player UI runs *(~2–4 days total at current pace)*
Phase 2 — player runs, UI visible:
- [ ] Walk the player's known probe sequence (fb0 → input → sa-config
      → efuse → mtd5) fixing each fault as it appears (guest oops =
      task list, same method as M1/M2)
- [ ] **/dev/fb0**: confirm soc_fb (already loads clean) serves a
      framebuffer without panel init; if it needs the panel, model
      LG35583 as an I2C write-sink (fixed init sequence)
- [ ] **See the UI**: framebuffer is guest RAM — dump to PNG (gdb/
      memory); optionally route LCD I2C writes as live framebuffer
      updates for real-time view
- [ ] Input: keyboard via GPIO (loaded); touch cst8xx I2C slave only
      if interaction is wanted

Phase 3 — sound (the one real model left):
- [ ] **AIC + PDMA audio engine**: ALSA PCM → AIC regs → DMA →
      CS43131 codec (I2C sink). Biggest remaining model; player is
      expected to run without it first (strace: degrades gracefully)

Exit: UI renders (viewer: QEMU fb dump → PNG, or a live windowed
variant chosen for least CI friction). No firmware bytes are modified.
The regression gate is then: any OS change → repack → boot in VM →
screen renders.

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
