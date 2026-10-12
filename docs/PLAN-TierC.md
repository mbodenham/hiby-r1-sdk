# Tier C Plan — QEMU X1600 full-system emulation (v1.1)

STATUS (2026-10-12, after the second bring-up session):

- **M0: DONE.** QEMU builds in-repo (mipsel-softmmu), `X1600` machine type
  registered, `XBurstR2` from upstream, regmap verified disassembly-wise
  against the stock kernel's embedded DTB (docs/x1600-regmap.md).
- **M1: IN FLIGHT — the kernel boots its real head, prints through the
  emulated UART, calibrates, and runs initcalls to guest time ~0.44 s.**
  History: the v0.1–v0.4 BUG_ON was a mis-diagnosis (PC 0x80010400 =
  `run_init_process`, not head.S); a full kallsyms decode pinned the
  real links (`kernel_entry` 0x80585c60, `start_kernel` 0x807a2764) —
  M1-bringup-log v0.5. v0.7: UART earlycon. v0.8–v0.11: bootmem/cmdline
  (PROM table + argv shape). v0.12–v0.14: OST clockevent (IRQ line 4
  delivery worked all along; the stop was the model arming the compare
  once instead of the vendor's periodic auto-reload). v0.17: OST
  counter fix (frozen 0x20/0x24 reads parked every `udelay` forever).
- **Boot state now (v0.17):** stock kernel stops inside
  `dwc2_platform_driver_init` (named by initcall_debug): the USB OTG
  probe programs the **USB PHY PLL — whose registers live IN the CGU
  block** (stock DTB: /apb/otg_phy + /apb/otg_new_phy @0x10000000
  size 0x100) — then parks the thread waiting for a PLL-lock event the
  all-zero, write-discarding CGU stub can never produce. Timer, IRQ
  delivery, udelay, sched_clock all work. Open probe order:
  1. CGU stub semantics: persistent regfile (store+log writes) and
     USB-PLL enable→locked status; if the driver's wait is bounded,
     verify the timeout/error path lets boot continue.
  2. Parked-task forensics (RAM dump + task-list walk / schedule-break)
     if the probe does not proceed on a locked PLL.
  3. OTG core region 0x13500000 (ingenic,dwc2-hsotg, size 0x40000 per
     DTB) is still unmapped — add the stub when the probe reaches core
     registers (trace-driven rule).
  4. INTC (0x10001000) still a zero-return stub; TCU unmodeled —
     required as soon as a peripheral IRQ matters (the USB PHY may
     want one for its lock event).
- Boot evidence, register dumps, and every boot-stop decode live in
  docs/M1-bringup-log.md (v0.1 through v0.17).

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
(IngenicSemiconductor/XBOMX), but no QEMU machine. Tier C is greenfield for
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

None of these touch QEMU/Tier C: no duplicated work to avoid; the delta our
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

### M1 — machine skeleton + kernel early console *(~1–3 weeks part-time)*
Tasks:
- [ ] `hw/mips/x1600.c` machine: DDR region + stub machine state +
      `-bios`-less direct-kernel-load (QEMU `-kernel` path), initial
      `-cpu xburstr2`.
- [ ] Device model list **for this milestone only**: Ingenic INTC, UART
      (8250-compatible with the clock tweaks the vendor kernel plays —
      the key unknown; mitigated by reading the exact `cpm`/clock gate
      writes via early probe loops), TCU clocksource, CPM gate stub.
- [ ] Earlycon validate loop: the single-line goal is `Booting Linux on
      physical CPU 0x0` … the first dmesg lines.
- [ ] Crash-fwd: everything after earlycon that panics is the NEXT M1
      unit. (panic message = task list.)

Exit: kernel early log prints through emulated UART (achieved with all
of M1's devices and nothing else), then either it reaches init/ or a
panic whose block is queued for M2/M3 (never a "nothing after earlycon"
state: each panic maps to a named model task).

### M2 — rootfs reachable at the stock layout *(~1–3 days after M1)*
Tasks:
- [ ] mtd + SFC/NAND backend: a QEMU nand image built from
      `unpacked/1.6/rootfs.squashfs` + a stub data partition, layout
      mapped to the stock `/proc/mtd` shape (kernel-computed).
- [ ] Verify: `cat /proc/mtd` matches the device's; rcS reaches
      `S92_03_start_music_player` without a different boot shape.
- [ ] Add the boot-selection mtd-5 model (theme id + `ota:kernel` state)
      so theme/boot changes are testable in-guest.

Exit: rootfs mounts; `/etc/init.d/rcS` chain runs to the player's
attempt; the boot process is identical to flashing stock (the goal).

### M3 — player UI runs *(~1–2 weeks)*
Tasks — driven by the device-contract list, not speculation:
- [ ] LCD: QEMU-level 480x800 RGB565 surface (mapped into the guest at
      the fbdev base the kernel provides; the existing
      `tools/fb-viewer.py` then shows the guest's screen unchanged).
- [ ] Input: evdev via host keyboard (already validated at Tier B).
- [ ] Stub set: DAC/codec (null sink), pmu (AXP2101 ack for the
      player's probe), touch (host evdev), wifi (absent = ids show
      missing; the player's slow path tolerates that from strace),
      usb gadget (kernel side), `S50sys_server` file/socket stubs.
- [ ] Boot-obsessed player path: the stock player renders a full UI
      inside the model. This is Tier C's *actual* goal: the exact
      artifact we need for optimisation regression testing.

Exit: UI renders (same window viewer as Tier B, or a device-windowed
variant chosen for the least CI friction). No firmware bytes are
modified. The regression gate is then: any OS change → repack → boot
in VM → screen renders.

### M4 — continuous regression gate *(ongoing)*
- [ ] `tools/tierc-boot-test.sh` — boot VM with timeout, capture the
      dmesg window, diff against the recorded per-version baseline;
      fail on earlycon mismatch. Runs on every firmware repackage.
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

- Tier C is the project's regression approach; Tier B remains the
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
