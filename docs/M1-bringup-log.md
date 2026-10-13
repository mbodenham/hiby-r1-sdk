# M1 machine-skeleton bring-up log (QEMU X1600E)

Working tree: `tools/vendors/qemu` (built in-tree, `build/qemu-system-mipsel`).
New machine source: `hw/mips/x1600.c` (wired via `CONFIG_X1600` in
`hw/mips/meson.build` + `hw/mips/Kconfig`; FRESH `./configure` is required
after Kconfig edits — plain `ninja` does not re-evaluate Kconfig).

Status: **M2 — the stock kernel boots, rootfs (squashfs) mounts from
the emulated SPI-NAND, and the rcS module chain runs ~14 modules before
parking in the `soc_msc` (SD card) probe, which sleeps waiting on a
card-detect event the stub MSC never raises (see the M2 section below +
`docs/PLAN-TierC.md`).** All M1 milestones — real head, UART earlycon,
OST tick, XBurstR2 idle-wake (Config7.WII), full initcall sequence —
are done; this file is the running bring-up log (v0.1 → v0.62).
Sections v0.1–v0.4 used the WRONG entry point (0x80010400 =
`run_init_process`); v0.5+ started with the real `kernel_entry` and
superseded that analysis.

## Boot attempt history (v0.1 – v0.2 as of this file)

### v0.1: first boot, instant TLB-store fault
`-M x1600 -cpu XBurstR2 -kernel vmlinux.bin` with PC=0x80010400:

- `-d int` trace: `PC 80010404 EPC 00000000 TLB store exception`,
  address `A fffffff8` ⇒ the first kernel store used `$sp`-relative and
  SP was ZERO. QEMU's `-kernel` path did not set an SPL-style stack.
- Root cause: our reset handler only set PC; SPL sets `sp` before jumping.

### v0.2: SP fix (SPL-style stack) — kernel boots deep
Reset handler now also sets `env->active_tc.gpr[29] = 0x80F00000`
(the uImage load region = free DDR scratch above kernel text).

Result (from `-d int,cpu` runtime ~2 s before the log fills with the
exception loop): execution reaches `pc=0x800bdb24`, then the raise is
`raise_exception_err: 22 (trap)` (kernel BUG path).

Register state at the trap (from `-d int,cpu` dump):
- `ra = 0x800be2b4` (caller inside the kernel's early arg/clock setup path)
- `sp = 0x80efff60` (kernel set its own SP from our 0x80F00000 seed —
  the SP seed is successfully propagating)
- `v1 = 1`, all of s0-s7 and a0-a3 report 0 at the dump point.
- CP0 Config0 0x80000482 / Config1 0x9e190c8f / Config2 0x80000000 /
  Config3 0x00000c20 — consistent with a MIPS32r2 XBurst booting.

Kernel-flow reading (`-d exec,nochain` trace + disassembly):
```
80010400  entry (adds head store; sw a0 -> 0x807620d4 global)
80010410  jal 800d0208            (strlen-style helper)
80010430  j   800c9248
800d0208  prologue; jal 8024e3d0  (strlen)
800d0238  jal 800be228            (prom/mem args parser)
800be2ac  jal 800bdadc            (the function that then BUGs)
800bdb24  trap lands here (pc per dump), BUG at 800bdb44 = tne zero,v1,0xc
```
The BUG: filler at `0x800bdb44` (`tne zero,v1,0xc`, MIPS32r2-encoded)
inside an early list/pointer walk, firing with `v1=1`. Disassembly at the
trap region shows `BUG_ON(!s4)`-style (s4 = `*(s0+0x58)` = 0). The caller
path and the s0+0x58 pointer strongly suggests the kernel's early
clock/timer-list (or plat-list) is EMPTY because all fw args (`a0..a3`)
are 0 — the vendor SPL passes real fw args (`pending: setup fw_arg0..3 /
prom argv table`) — matching the trace-driven model plan's milestones
(clock list / TCU: next).

### v0.3 costs per attempt
- `ninja -C build qemu-system-mipsel` after `./configure` rebuild is slow
  (~1712 units so ~30-40 s incremental), boot trace `-d exec,nochain` is
  tiny (~800 bytes before the BUG loops broken) vs `-d int` (200 MB+ in
  seconds because the exception handler loop churns after the BUG).

## Do-not-forget
- `./configure` must be re-run after Kconfig edits.
- kernel hard-code: `fw_arg0..3` all-zero path hits the BUG: the SPEM
  boot path needs the SPL's fw args, then the CGU/TCU model comes right
  after per trace (no stub section touched before the BUG: CGU was never
  read: model it when the boot gets past this BUG).

### v0.3: fw args wired (2026-10-12, this session)

Machine now writes an SPL-style prom table into RAM (phys 0x000D0000,
kseg0 0x800D0000) and sets gpr a0..a3 in the reset handler:
a0=1 (argc), a1=argv table (cptr to "console=ttyS0,115200"), a2=envp
table {0} at +8, a3=0.

Result (trace `fwint.log` + `env_c.log`):
- the fw args DO reach the kernel: `-d int,cpu` dumps show
  `a0 00000001 a1 800d0000` at the entry region — the kernel's
  `sw a0,0x20d4(s0)` registrа path runs with our values.
- the SAME kernel-side BUG still fires at `tne zero,v1,0xc` (pc
  0x800bdb44) with `ra=800be2b4`; caller regs zeroed at the trap.
- the zero value is read from the kernel's OWN .bss: at vmlinux.bin
  offset 0x750058 (vma 0x80760058) the binary itself contains zeros —
  so `*(s0+0x58)==0` comes from the kernel's own uninitialized global,
  not from our fw-args table.
- writer hunting (pattern scan for `sw reg, 0x58(base)` in the kernel):
  1323 candidates overall; the local-region writers near the BUG are at
  `0x800be70c` (`sw s0,88(s1)` — registering the object into the list
  owner) and peers at 0x800be93c/0x800bf1dc/0x800bf6a8. The writer's
  neighborhood (0x800be6a0) reads a global at 0x8076E340 (`lui 0x8077;
  lw -7360(v0)`) and 0x8059F8B8 before `jal 0x80260340` — an
  object/list registration path with mfhi/mflo math, i.e. the kernel
  registers the object into `*(s1+0x58)` only AFTER something else ran.
  Meaning: the BUG is legitimate kernel logic firing on an empty list —
  some earlier kernel init expected to REGISTER this object first and
  did not run (or ran with wrong state).

Conclusion: the fix is NOT in the fw args alone; either (a) a fw arg we
still pass wrong survives (a3? prom shape?), or (b) an earlier kernel
init stage failed silently (e.g. the builtin DTB application, MMU/clock
early setup, or a CP0/clock-device init we stub as zeros), and the tail
end of that failed init is what left the list empty. Next probes in
order:
1. Re-run with gdb breakpoints on ALL FOUR `sw ???, 0x58(...)` writers
   in the 0x800be6a0/0x800be6f4 neighborhood + trace which of them ran
   (the -d exec,nochain trace of ~2 s captures it); the first writer
   that never runs is the failure point upstream.
2. Check whether the stock kernel applies its embedded DTB via a fw arg
   we did not provide (a3?) before the platform init; disassemble the
   entry function (vma 0x80010400–0x80010438) fully to see which register
   it expects in a1 (we pass argv; it may want something else).

### v0.4: stub-flow attempt + writer forensics (2026-10-12, continued)

**Stock stub boot path**: loaded the whole uImage payload (stub+gz) at
0x80F00000 and set PC at the stub entry. The stub EXECUTED (exec trace
from 0x80F00000 → walks blocks in the stub) but its flow is two-stage:
inspect disassembly — the stub saves our fw args (move s0..s3,a0..a3),
clears its own .bss at 0x8128F000-0x81299050, sets its own SP at
0x812A9050, points a0 at the embedded gz stream (0x80F04220), sizes it
as 0x38A0A8 = exactly (payload − stub) bytes, sets a2 = 0x80010000 as
the decompression target, sets ra = 0x80F00060 (a boot block that
restores a0..a3 for the kernel), and jumps to **k0 = 0x80585C60** — a
decompressor inside the kernel's own text region. Consequence: the stock
boot pre-loads a kernel text chunk into RAM BEFORE the stub runs
(SPL's two-piece arrangement). Without mtd models (M2) we cannot
replicate the full stock stub path faithfully. **The v0.2 direct-host-
decompressed kernel path remains the correct bring-up route; the stub
experiment reverted.**

**Writer forensics on the boot-stop**: scanning vmlinux.bin for writers
of the kernel global 0x8076029C (the read at 0x800d0230, `lw a0,668(s2)`
with s2 = 0x80760000): 13 `sw ?,0x29c(?...)` candidates, but NONE is a
lui-0x8076-based absolute store; all are object-field or stack-relative
writes through register-held base pointers. Reads: 56 sites. Meaning:
this global is filled by a code path whose base pointer is computed at
runtime (e.g. set up in the firmware/SPL region or via a struct pointer
assigned from fw args) — the failure is upstream and data-dependent.

Boot still 11 blocks (identical trace): `0x80010400 → 0x800d0208 →
0x8024e3d0/e8 → 0x800d0230 → 0x800be228 → 0x800be254/0x800be2a4 →
0x800bdadc → 0x800bdb14/0x800bdb24 (trap)` with a0..a3 and s-regs zero
at the dump point. fw-arg shape variants (argv table / direct string,
envp table / envp NULL) do not change the path: the failing chain
depends on kernel-internal state, not our register shape alone.

Suspects to test next (in order):
1. The stock kernel's builtin DTB boot-path: the kernel is a DT device
   kernel (per the M0 finding: builtin DTB, "x1600" compatible).
   Some early setup (of /plat setup with the DTB) may need to apply the
   DTB pointer: check whether fw_arg3 is a DTB pointer (a3 points to a
   copy of the embedded DTB in RAM vs 0 = "builtin only").
2. MMU/TLB/CP0 state the stock SPL configures before the jump: maybe
   the_regs/timer/CP0 registers must carry something (e.g. Config's
   lock/seed, cache state, cdmmcp0).
3. The kernel's own early "plat_mem_setup"-family stage (Ingenic board
   flow) may need the EXCLK/state before it (the 4.4 Ingenic vendor
   boards have hard-coded machine code we don't reach unless the
   entry's early call chain completes).

## Next session's TODOs in order (trace-driven)
1. FW args: set `fw_arg0..3` = the stock SPL's shape (null-terminated
   argv-table for "console=..." bootargs; possibly a0=2 a1=argv_table_ptr,
   a2=?? a3=??, prom-style). If that doesn't advance past `0x800bdb44`,
   dump the next block.
2. `-d int,cpu` after each change: per the boot MUST remain below 15 s /
   log under ~700 MB before grep.
3. When the BUG clears: re-run `-d unimp`-log and the `-stub read` book
   appears (the stub logging is in the machine code); nothing logged yet
   means no SoC block access happened BEFORE the clock-list BUG — so the
   CGU/TCU models now become trace-driven next steps.

---

# v0.5 – v0.13 (2026-10-12, second session): the entry-point break

**Everything in v0.1–v0.4 chased the wrong PC.** A full kallsyms decode
of the stock `vmlinux.bin` (unpacked/1.6/vmlinux.bin regenerated from
xImage via `dd bs=1 skip=16992 | gzip -dc`; md5 dceda6683b9bc56b9a4110530b9add3f)
pinned every address and the whole picture flipped.

### v0.5: kallsyms decode + real entry point

Blob decode (byte offsets inside vmlinux.bin; vma = 0x80010000 + off):
- `kallsyms_addresses` @ file 0x5fe820: 44,589 ascending u32 VMAs,
  0x80010000 … 0x808f9b10.
- `kallsyms_num_syms` @ 0x62a0e0 = 0xae2d (44,589 ✓).
- `kallsyms_names` @ 0x62a0f0 (12 bytes of pad after the count):
  44,589 `[len][tok]…` entries ending exactly at 0x6aa18a.
- `kallsyms_markers` @ 0x6aa190 (175 u32; first=0, last=0x7fe84).
- `kallsyms_token_table` @ 0x6aa450 (256 NUL-terminated ASCII tokens,
  token0="ree_", idx@0x6aa7e0).
Tooling for this session lives in /tmp/kilo/tierc (kall*.py, dtb.py —
temporary; regenerate on need). Result: syms.json = full (addr,name) map.

Decisive symbols (image vma):
- `kernel_entry` = **0x80585c60** — this is the address the stock stub's
  `k0` held in v0.4 (the "decompressor" misread). It is head.S: CP0
  Status setup, UHI-ish DTB check (`if *(0x807d414c)==d00dfeed → a0=-2,
  a1=fdt` — `__appended_dtb`; slot EMPTY in our image ⇒ builtin
  `__dtb_start` @0x807cdf80 (15,833 B, FDT v40) is what gets used — the
  old "fw_arg3 DTB pointer" probe is MOOT, head handles it), .bss clear
  [0x808e0000, 0x808f9b0c), fw_arg0..3 globals @0x808e2360/5c/58/54,
  kernelsp @0x808e2364, then `j start_kernel` (0x807a2764).
- `0x80010400` = `run_init_process` (`_stext` also points there). The
  v0.1–v0.4 11-block BUG chain was: run_init_process → getname_kernel
  (0x800d0208) → kmem_cache_alloc (0x800be228) → cache_alloc_refill
  (0x800bdadc, BUG_ON(!array_cache @+0x58) at 0x800bdb44) — SLAB
  uninitialized because the boot head never ran. CLOSED.

Machine change: reset PC = X1600_KERNEL_ENTRY = 0x80585c60; SP seed
retained (head sets its own: 0x8075ff28).

### v0.6: plat_mem_setup reached → TCSM0 bus error

With the real head, boot progressed to `plat_mem_setup` (0x807a3748,
Ingenic vendor code): sets `mips_io_port_base=0xa0000000`, io/iomem
resource globals @0x80764014/18 & 0x80763ff8/fc, CGU+0x20 RMW at
0xa0000020, then `sw 0x00010003 → 0xB34F0240` (phys **0x134f0240**) and
`sw get_fdt_addr() → 0xB34F0244`. Our machine had nothing at
0x134f0000 → QEMU raised **DBE** → BEV=1 reset vector 0xbfc00380 (empty
BootROM) → IBE re-loop (the earlier "frozen trace").

Symbols settle the block: `plat_mem_setup` + the PM gang live there —
`tcpu_resume/tcpu_sleep/tload_func_to_tcsm` all use 0xB34F0000 = off-chip
PM scratch ("TCSM0"); on silicon it's SRAM, never a bus error. MODELED:
plain RAM region at phys 0x134f0000, size 0x40000 (unsized in stock DTB;
PM code only touches +0x0/+0x8/+0x240/+0x244). Also aligned stub sizes
to the parsed stock DTB (pinctrl 0x1000, pdma/msc 0x10000, intc 0x100).

### v0.7: FIRST SERIAL OUTPUT

`Linux version 4.4.94+ (zcz@androidserver3) … bootconsole [early0]
enabled … MIPS: machine is ingenic,x1600_halley6_module_base`.
Fixed: UART0 SCR seeding. The early-uart scan (prom_putchar 0x800135d0 +
scout 0x80013618) polls each UART+0x1c expecting **0xa9**; QEMU's serial
device resets SCR to 0 → all four probes miss → putchar_dummy → silent
boot. On silicon the SPL leaves 0xa9 in SCR. Machine now re-seeds
UART0's scr after the serial device reset (qemu_register_reset ordering:
device resets run before legacy handlers registered after realize).

### v0.8–v0.10: fw args shape + PROM placement (bootmem stop cleared)

New stop after "Wasting 512 bytes…": `__bzero` fault, TLB-store at
A=0x7ffff000. Chain: `init_bootmem_core` (0x807ab1a0) memset(bitmap =
(pfn<<12)|0x80000000, 0xff, size=(maxpfn-minpfn+7)/8). GDB proved the
memset DEST = 0x7ffff000 = **((u32)-1 << 12) + 0x80000000** — bitmap pfn
= -1. Why: setup_arch's own `arch_mem_addpart` calls (0x807a433c) build
`boot_mem_map` @0x808e2368 with exactly two regions (the bootlog's
"Determined physical RAM map": [0x10000,0x7a2000) and [0x7a2000,0x8e0000)
usable-after-init) — both END below the kernel end (0x8fa000), and the
min-pfn selection loop (setup_arch+0x180, r2-decoded with
`-m mips:isa32r2`: s5 = max(region_start, kernel_end_page) over regions
whose end > kernel_end_page) therefore never fires → s5 stays -1 →
0x7ffff000. The kernel has no `mem=`-less RAM source: extra RAM must
come from the cmdline (`mem=64M`; handler `__setup_early_parse_mem`
@0x807d20b8 exists — the "mem=" string I grepped for initially was
only a substring of "iomem="; the param table stores "mem").

Then: `fw_init_cmdline` (0x807b0b00) semantics (from disasm): if
fw_arg1 < 0 (signed — KSEG0 pointers ARE negative, that's the "valid"
case) it takes fw_argc = fw_arg0 & 0xffff, _fw_argv = fw_arg1, and
copies **argv[1..argc-1]** (argv[0] = bootloader name, SKIPPED) joined
with spaces into boot_command_line @0x807c68d8. Our old shape
(argc=1, argv[0]=cmdline) therefore produced an EMPTY cmdline.
Also found via gdb: the PROM table at phys 0x000d0000 sat INSIDE the
kernel image [0x10000, 0x7c414c) so `load_image_targphys` overwrote the
argv table with kernel text (0x800d0000 showed `0x02402025`…).
Fixes (one round): PROM relocated to phys **0x00a00000** (above the
image and above the bootmem bitmap [0x8fa000,0x8fa800)), and argv shape
a0=2, argv={name "linux", cmdline "console=ttyS0,115200 mem=64M", 0},
envp={0} (+0xC), a2 = envp table.

Result: "User-defined physical RAM map: memory 0x04000000 @ 0x00000000",
memory zones built (64 MiB), PID hash, Dentry/inode caches, RCU,
NR_IRQS:200, **"x1600 Clock Power Management Unit init!"** with clock
list (all CGU-sourced rates = 0 — our CGU stub returns 0; ext_clk = 24
MHz comes from elsewhere), then a NEW stop:
`Data bus error, epc == 807b9c88 (ingenic_ost_init+0x168)` — driver
read at 0xB2000000 = phys 0x12000000: the OST is unmodeled.

### v0.12: OST modeled → calibrate freeze

OST (`/core-ost@0x12000000`, ingenic,x1600-ost, size 0x100 per stock
DTB) first modeled as plain RW RAM: `ingenic_ost_init` RMWs read fine
(clocksource registered: "ingenic_clocksource mask 0xffffffffffffffff",
sched_clock 64 bits at 1500kHz, dummy console…), boot then froze at
**"Calibrating delay loop…"** — jiffies never tick (no event IRQ).

### v0.13: OST device + OPEN: clockevent IRQ line

OST now a real register block (+perf: writes stored; **+0x14 write =
compare/event delta → arm a QEMU timer at delta/1.5 MHz; +0x0C write =
ack → lower IRQ line**; the 1.5 MHz rate is the driver's own derived
value printed by sched_clock). DRIVER FACTS (disasm 0x80400424-
0x80400560): `ingenic_set_next_event` writes +0x10/+0x38 +0x0C(-2)
+0x14(delta) +0x8 +0x34 +0x10(-2); `ingenic_timer_interrupt` acks +0xC
and calls the clockevent handler. Full register sequence captured via LOG_UNIMP
logging in the model (x1600-ost read/write lines): arm value 0x3a97 =
14,999 ticks ≈ 10 ms = 100 Hz tick ✓ host-gdb confirms x1600_ost_tick
runs.

REMAINING BUG: raise goes to `cpu->env.irq[4]` (stock DTB: /core-ost
interrupt-parent = cpuintc, interrupts = <4>) but the kernel takes
nothing (`-d int` = zero exceptions taken in 12 s). v0.10 oops dump
showed Status 0x10000c02 = IM2|IM3 only. Next probes, in order:
1. Wire the OST to CPU line 3 (mainline x1000.dtsi uses <3> for OST;
   the vendor cpuintc domain `mips_cpu_intc_map`/`mips_cpu_irq_controller`
   @0x802762e4 may map hw→IP with an offset) and re-run: watch for
   "Calibrating delay loop... OK, xxx loops per jiffy".
2. If that fails, host-gdb the `cpu_mips_irq_request` level=1 path and
   read CP0_Status/CP0_Cause at arm-time to see which IM bit the kernel
   actually unmasks (`Trace` symbol map: init_IRQ 0x807a3dec,
   do_IRQ 0x8001947c).
3. Then re-enable CGU-pinned reads if a later stage stalls on zero
   clock rates (the clock-list prints 0 for every CGU-sourced clock;
   ext=24 MHz).
### v0.14: OST periodic auto-reload — calibration completes

The v0.13 stop (IRQ raised, jiffies frozen) decoded via the full
host-gdb → guest-gdb chain: the raise latched Cause.IP4, the guest
TOOK the HW exception, do_IRQ(4) → ingenic_timer_interrupt ran, and
`tick_handle_periodic` (event_handler 0x8007e400) executed — but it
checks `clockevent_state_oneshot` and, seeing mode=2 (PERIODIC),
returns WITHOUT reprogramming. Vendor HW semantics: a periodic OST
compare auto-reloads the last +0x14 delta and re-fires. Our model
armed exactly once → one jiffy, then forever silence inside
calibrate_delay's wait-for-jiffy-edge.

Fix: `x1600_ost_tick` re-arms `s->period` after each fire. Result:
jiffies tick (59 ISR acks / 15 s), "Calibrating delay loop" completes,
boot marches to fuse init, io schedulers, **"loop: module loaded"**,
then freezes silently — CPU parked in the idle `wait/ei` loop, init
thread sleeping (no MMIO, no progress).

### v0.15–v0.16: name the blocker — `dwc2_platform_driver_init`

Added `initcall_debug ignore_loglevel` to the machine cmdline (KERN_DEBUG
is console-suppressed without it). Last line before the silence:

```
[    0.442656] calling  dwc2_platform_driver_init+0x0/0x10 @ 1
```

DesignWare USB OTG driver registration; the DTB already created the
`/ahb2/otg@0x13500000` (ingenic,dwc2-hsotg) platform device, so
`platform_driver_register` runs `dwc2_driver_probe` (0x8033de74)
synchronously. Probe chain (kallsyms-resolved): devm_kmalloc →
`devm_usb_get_phy_by_phandle` (0x80338d9c) → of_clk_get →
platform_get_irq → devm_request_threaded_irq →
devm_regulator_get_optional (-19 tolerated) → ioread32 (GSNPSID mode
detect) → device_create_file ×3 → `usb_add_gadget_udc` (0x8035ee1c)
→ `dwc2_hsotg_udc_start` → `dwc2_phy_init` (0x8033c2f8).

`-d unimp` at the freeze: the tail is CGU reads **0xC4, 0xC4, 0x24,
0x20, 0x24** followed by endless OST 0x20/0x24 read pairs. Decoded the
pairs as `udelay`/`local_delay` spinning on the OST counter — and found
the counter frozen: `x1600_ost_read` served 0x20/0x24 from the static
regfile, which nothing ever updates, so it reads 0 forever. Any driver
wait loop with udelay parks inside udelay. (v0.15 got further only
because its hot path never called udelay: calibration uses jiffies, the
early CGU PLL-stable polls are tight MMIO loops.) An earlier 438-read
burst on CGU+0x00 / 105-read burst on CGU+0x2C is a BOUNDED
PLL-stable poll that the kernel tolerates — boot continued past it.

### v0.17: OST counter fix — probe passes PHY spin, parks on PLL-lock wait

Fix: `x1600_ost_counter()` = virtual-clock ns × 1.5 MHz (the rate the
kernel's own "sched_clock: 64 bits at 1500kHz" print derives); 0x20 =
low 32, 0x24 = high 32; counter reads excluded from the unimp log
(hot path). Guest timestamps now advance with real durations
(loop_init 7656 usecs, ingenic_usb_phy_driver_init 3113 usecs) and the
OST ISR re-arm deltas drift correctly (0x39ce → 0x39f2 → 0x39f4).

Boot reaches the dwc2 call at guest 0.4426 s; the probe now runs the
PHY PLL sequence (CGU +0xC4/+0x24/+0x20 reads — DTB confirms the PHY
registers ARE the CGU block: /apb/otg_phy + /apb/otg_new_phy @
0x10000000 size 0x100, ingenic,innophy-x1600 / ingenic,usbphy-x1600)
and then the thread PARKS: CPU sits in the idle loop, jiffies + OST
ISR re-arms continue (the timer is alive), the parked task never
wakes — consistent with an unbounded completion/IRQ wait for the
PLL-lock event. Two model gaps behind it:

1. `x1600_stub_write` is a NO-OP (discards every write, logs nothing) —
   the PHY PLL enable is invisible and the lock bit can never be set.
2. CGU reads all return 0 — no PLL status semantics.

OPEN (next probes):
1. Identify the parked task + exact wait (walk the task list from the
   captured RAM dump /tmp/kilo/tierc/ram16.bin, or break in guest gdb
   on `schedule`/completion-wake and capture the waking context).
2. Give the CGU stub a persistent regfile (store writes, log them) and
   USB-PLL semantics: once the enable is written, the lock-status read
   returns the locked value. If the driver's wait is bounded instead,
   the probe should time out and boot continue — verify which.
3. The OTG core region (0x13500000, size 0x40000 per DTB) is NOT yet
   mapped; if the probe reaches core registers (it already ioreads the
   GSNPSID — check where that lands) a bus error will follow. Add the
   stub when the trace demands it.

Reference table of pinned firmware addresses (vma):
kernel_entry 0x80585c60 · start_kernel 0x807a2764 · setup_arch
0x807a43a0 · plat_mem_setup 0x807a3748 · prom_init 0x807a35a0 ·
fw_init_cmdline 0x807b0b00 · boot_command_line 0x807c68d8 ·
boot_mem_map 0x808e2368 · fw_arg0..3 0x808e2360/5c/58/54 ·
bss [0x808e0000, 0x808f9b10) · __dtb_start 0x807cdf80 ·
__appended_dtb 0x807d414c (empty) · ingenic_ost_init 0x807b9b20 ·
clocksource_probe 0x807b5cb8 · of_clk_init 0x807b7c88 ·
ingenic_clockevent 0x808f4e80 · ingenic_timer_interrupt 0x80400514 ·
plat_time_init 0x807a37d4 · init_IRQ 0x807a3dec · do_IRQ 0x8001947c ·
init_bootmem_core 0x807ab1a0 · tcpu_resume/tcpu_sleep/tload_func_to_tcsm
 0x800136c4/0x80013b78/0x800140c8 (TCSM0 users) ·
dwc2_driver_probe 0x8033de74 · dwc2_phy_init 0x8033c2f8 ·
dwc2_hsotg_udc_start 0x8035216c · dwc2_platform_driver_init
0x807b4dc8 · usb_add_gadget_udc 0x8035ee1c ·
devm_usb_get_phy_by_phandle 0x80338d9c · ingenic_usb_phy_probe
0x80339f8c · ingenic_usb_phy_driver_init 0x807b0128 ·
schedule 0x805877a4 · wait_for_completion 0x805883c0 ·
wait_for_completion_timeout 0x805883d0 · msleep 0x8006e960 ·
init_task 0x8073fc3c.

# v0.18 – v0.23 (2026-10-12, third session): idle-wake break → M1 exit

### v0.18/v0.19: persistent stubs expose the PHY sequence, then a hard freeze

Stubs became per-instance persistent regfiles (writes stored + logged).
The CGU sequence decoded: `0xC4=0x1000` pulse (USB PLL enable),
`0x24=0x80`, INTC `+0xC=0x2` (line-1 enable) — the clock framework's
USB-clock enable path inside `common_phy_init` (0x80339dd4), followed by
`usleep_range(5000,5000)` (0x8058a218; 5 ms, NOT 5 s). Then ALL guest
activity stops: 500 s wall, guest time frozen at 0.444378, no OST ISR
re-arms, no MMIO — the vCPU is parked, not slow.

### v0.20: XBurstR2 Config7.WII — the idle-loop wake fix (QEMU target change)

Guest-gdb probe at the freeze: PC 0x800193cc = `ingenic_wait_irqoff+0x54`
(the vendor idle loop `sync; wait; ei; ehb`, called from
`cpu_startup_entry+0xa4`), **SR=0x10001c00 (IE=0), Cause=0x40809000
(IP4 pending), IM4|IM3|IM2 unmasked**. The Ingenic idle loop runs WAIT
with interrupts DISABLED and relies on the core waking on any pending
interrupt; QEMU's `mips_cpu_has_work` (target/mips/cpu.c) only wakes on
interrupts-that-can-be-taken unless pre-R6 Config7.WII ("Wait IE
ignore") is set. Real XBurst silicon wakes regardless of IE (the vendor
loop's existence is the proof). Fix: `.CP0_Config7 = 1 << CP0C7_WII` on
the XBurstR2 def (target/mips/cpu-defs.c.inc) — QEMU's own architected
mechanism, no behavioral invention.

Result: the parked 5 ms usleep completes, dwc2 probe continues,
initcalls march on. Next stop: `x1600_phy_init+0x6c` bus error —
`lw v1,0x30(v0)` with v0=0xB0078000.

### v0.21: USB PHY bank stub 0x10078000

`x1600_phy_init` (0x8033a9e8) decoded fully: base_a (CGU) writes
0x48=0x200000, 0x3c=0x80400000, udelay(500), 0x3c=0x80000000,
0x48=0x70000000, udelay(500); then base_b=0xB0078000 RMWs: +0x30 |= 7,
+0x40 |= 0x38, +0x10C/+0x110 &= ~0x3F |= 0x2D, +0x108 |= 8 (conditional
on a priv byte). The 0x10078000 bank is vendor-private (ABSENT from the
stock DTB; nearest nodes sadc@0x10070000 / aic@0x10079000 — stub sized
0x1000, ends exactly at aic). Next stop: `sfc_clk_set_init+0x58` bus
error — RMW of SFC+4 with a0=0xB3440000.

### v0.22: SFC stub 0x13440000 — probe runs, no NAND (expected until M2)

`ingenic_sfc_drv_init` now RUNS for 3.0 s and returns **-19 (ENODEV)**:
the stub has no SPI-NAND behind it (`ingenic-sfc 13440000.sfc:
sfc_sync_cdt error ! ... ingenic_sfc_nand_set_feature 623` — the
driver's SET_FEATURE goes nowhere). No crash; boot continues through
ALSA/snd_soc/TCU/MMC initcalls. Next stop:
`serial_ingenic_set_termios+0x268` bus error — `sw v1,0x24(v0)` with
v0=0xB0030000: the vendor serial driver touches Ingenic extension
registers at UART+0x24/+0x28, OUTSIDE the 16550's 8<<2 window (serial_mm
maps only 0x20 bytes).

### v0.23: UART0 ext stub → FULL initcall sequence → VFS root panic = M1 EXIT

UART0's 0x100 range now has a persistent stub at priority -1 under the
real serial_mm device (regs 0x00-0x1f stay real, extensions store).
Boot then runs the COMPLETE initcall table to `alsa_sound_last_init` +
`clk_disable_unused` (guest time advances near real-time: 274 s guest
in ~300 s wall), real console handoff works (`console [ttyS0] enabled`,
`bootconsole [early0] disabled`), `kernel_init_freeable` finishes, and
the kernel panics on exactly the M2 boundary:

```
VFS: Cannot open root device "(null)" or unknown-block(0,0): error -6
Please append a correct "root=" boot option; here are the available
partitions:                     <-- ZERO partitions: no MTD device
Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
```

(One non-fatal warning on the way: `/dev/console` open path oopses in
chrdev_open — init falls through to the root mount anyway.)

**M1 exit criterion MET** — kernel boots through emulated UART, runs
every initcall, and panics on the named M2 block: mtd + SFC/NAND
backend + root= bootarg. M2 entry facts from v0.22/v0.23 evidence:

- The SFC probe failure is `ingenic_sfc_nand_set_feature` (SET_FEATURE
  command) — the real model must speak enough SPI-NAND (READ ID,
  GET/SET FEATURE, READ FROM CACHE) backed by the stock flash image.
- `root=` is ours to add: argv[1] cmdline (SPL would have passed it;
  we replicate). Stock layout: `root=/dev/mtdblockX
  rootfstype=squashfs` matching the device's /proc/mtd shape.
- SFC register map starts at /ahb2/sfc@0x13440000 (0x10000); the
  driver file names itself `ingenic_sfc_v2/ingenic_sfc_nand.c` —
  Ingenic's v2 SFC controller.

Session notes: a `-d unimp` run at this stage produces ~100M log lines
in 300 s (3.4 GB — mostly UART-ext/RTC/OST noise); unimp logging is
now for SHORT captures only.

---

# M2 — rootfs at the stock layout (QEMU X1600E)

M2 opens where M1 ended: the VFS root-mount panic with zero MTD
partitions. The work below takes the kernel from that panic to a
**mounted squashfs rootfs read from an emulated SPI-NAND**, then through
`devtmpfs` and the rcS module-load chain, where it parks in the
`soc_msc` (SD card) driver.

## The SFC controller + SPI-NAND model (v0.24–v0.34)

The stock `ingenic_sfc_v2` driver (`ingenic_sfc_nand.c`) talks to the
SFC at 0x13440000 via a **Command Descriptor Table (CDT)**: 16-byte
command entries at reg 0x800+, a transfer configured through reg 0x7c
(CDT index + mode bits), params at 0x80–0x8c, length at 0x2c, started by
`0x64 |= 1`. Completion is an IRQ (INTC line 7) whose handler
(`ingenic_sfc_pio_irq_callback`) moves bytes between a guest buffer and
the PIO FIFO at reg 0x1000, then the DONE bit (0x68 bit4) →
`complete()`. Page reads/writes additionally use a **DMA descriptor
chain** (reg 0x90) of `{next, data_phys, len, more}`.

Register names came from the driver's own `dump_sfc_debug` (the vendor
prints SFC_GLB0/DEV_CONF/…/ROW_ADDR/COL_ADDR/… on timeout) — a reliable
map: **ROW_ADDR = 0x84, COL_ADDR = 0x80** (initially swapped; v0.28).

Key model facts, each pinned by a boot symptom:
- **Chip ID** READ ID (0x9F) → `GD5F1GQ4UC` (mfg 0xC8, dev 0xD1). The
  driver's table match printed `Found Supported device, id_manufactory =
  0xc8, id_device = 0xd1` on first try.
- **Descriptor base (0x90) is a guest VIRTUAL address** (`desc_va +
  0x80000000`). For a kseg1-aliased buffer it reduces to
  `phys = 0x90 − 0x20000000`. Reading 0x90 directly as bus address failed
  (DECODE_ERROR, ~545 MB out of 64 MB RAM); the kseg1 offset made the
  BBT scan read real OOB (all 0xFF → zero bad blocks).
- **In-flash partition table**, not cmdline: the vendor driver reads a
  table at NAND byte **0x5800** (driver default when DTB has no
  partition-offset) — header `{u32 magic 'nand' (LE), u32 count}` then
  48-byte entries `{char name[32], u32 size @0x20, u32 offset @0x24,
  u32 flags @0x28}`. Without it the probe prints
  `NOTICE: this flash haven't param` and `read partition from flash
  failed!` and registers NO mtd (cmdline `mtdparts=` is ignored by this
  driver). The table is now written by the image builder.
- Backing store: a raw **page+OOB image** (`nand-r1.bin`, 2112 B/page,
  64 pages/block, 1024 blocks = 128 MiB data + OOB), mmap'd next to the
  kernel. OOB synthesized 0xFF (no bad blocks).

**v0.34 — M2 CORE ACHIEVED:** `VFS: Mounted root (squashfs filesystem)
readonly on device 50:2.` (mtdblock_bbt_ro, rootfs partition). Boot then
mounts devtmpfs and enters the rcS module-load chain.

## The rcS module chain + the three model gaps it exposed (v0.53–v0.62)

rcS loads ~14 `soc_*` modules via `/module_driver/*.sh` (plain-text
`insmod <mod.ko> <params>` — per libra, "the DTS in plain text").
Three model gaps surfaced, each fixed:

1. **RTC write-protocol storm (v0.53).** The vendor `ingenic_rtc_writel`
   polls `+0x00` bit7 (write-ready) and, after writing the 0xa55a key to
   `+0x3c`, polls `+0x3c` bit31 (write-accepted). The plain stub returned
   0 for both → every poll timed out → the RTC set-time retry loop spun
   the CPU in a `+0x3c` read storm, starving the `soc_msc` insmod thread
   (boot appeared frozen at msc_init with ~100k RTC reads). Fix: RTC
   model returns write-ready/accepted so writes complete.
2. **CGU PLL-lock poll (v0.59).** The clock framework's `clk_set_rate`
   (for the MSC clock) programs the PLL (CGU 0x7c/0x60) then polls
   `+0x2c` for lock. The all-zero stub never locked → unbounded retry.
   Fix: CGU model returns all-locked at `+0x2c`.
3. **soc_msc probe park (v0.60+, OPEN).** After the clock + GPIO/pinctrl
   setup, the MSC probe **sleeps** (CPU idle, guest frozen at ~3.5 s)
   BEFORE any MSC (0x13450000/0x13460000) MMIO. It is not a register
   poll (no MMIO storm) — it waits on an MSC event (card-detect IRQ /
   completion) that the inert MSC stub never raises. This is the current
   blocker to rcS reaching the player.

Non-fatal module oopses (insmod continues past each): `soc_i2c`
(`jz_i2c_hal_disable_smb`, I2C 0x10050000 unmapped) and `soc_aic`
(`aic_hal_init`, AIC 0x10079000 unmapped). Both are simply missing stubs.

## NAND image + partition layout (tools/tierc/make_nand_image.py)

Layout mirrors the live device's `/proc/mtd` (libra BACKLOG, live read):
`uboot(2M) kernel(5M) rootfs(40M) kernel2(5M) rootfs2(40M) ota(512K)
userdata(rest)` over 128 MiB. The image places `xImage` in both kernel
slots, `rootfs.squashfs` in both rootfs slots, the `ota:kernel` flag +
theme at the ota partition, and the in-flash partition table at 0x5800.
Everything else erased (0xFF).

## Next (to reach the M2 exit)

1. **Model the MSC controller** (0x13450000 msc0, 0x13460000 msc1)
   enough for the probe's no-card path to complete: the card-detect /
   state-machine event the probe waits on. `soc_msc.sh` configures msc1
   with `cd=PB22 cd-inverted, pwr=PC25, bus_width=4`.
2. Add I2C (0x10050000) + AIC (0x10079000) stubs to clear the module
   oopses (cosmetic; boot already continues past them).
3. Then rcS should run `mount_ubifs.sh` (userdata), the theme, and
   `S92_03_start_music_player` — the M2 exit.
