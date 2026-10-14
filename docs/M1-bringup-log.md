# M1 machine-skeleton bring-up log (QEMU X1600E)

Working tree: `tools/vendors/qemu` (built in-tree, `build/qemu-system-mipsel`).
New machine source: `hw/mips/x1600.c` (wired via `CONFIG_X1600` in
`hw/mips/meson.build` + `hw/mips/Kconfig`; FRESH `./configure` is required
after Kconfig edits — plain `ninja` does not re-evaluate Kconfig).

Status: **M2 — the stock kernel boots, rootfs (squashfs) mounts from
the emulated SPI-NAND, the rcS module chain runs (~14 soc_* modules +
touch/codec/UBIFS working), and the remaining stall chains from the
wifi path: msc0 now carries an SDIO wifi card model and the mmc core
reaches SDIO card init, but card init fails -34 at the CMD52/CCCR
stage, so cywdhd still fails and its dangling device kills the
module-chain tail (see the v0.64 section + `docs/PLAN.md`).** All M1
milestones — real head, UART earlycon, OST tick, XBurstR2 idle-wake
(Config7.WII), full initcall sequence — are done; this file is the
running bring-up log (v0.1 → v0.64).
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

## NAND image + partition layout (tools/x1600/make_nand_image.py)

Layout mirrors the live device's `/proc/mtd` (libra BACKLOG, live read):
`uboot(2M) kernel(5M) rootfs(40M) kernel2(5M) rootfs2(40M) ota(512K)
userdata(rest)` over 128 MiB. The image places `xImage` in both kernel
slots, `rootfs.squashfs` in both rootfs slots, the `ota:kernel` flag +
theme at the ota partition, and the in-flash partition table at 0x5800.
Everything else erased (0xFF).

## v0.63 (2026-10-13, fourth session): the "soc_msc park" root cause + I2C/AIC/SADC/msc1/CGU fixes

### The park was never an MSC event — it was a leaked device mutex

v0.60+ concluded the probe "waits on an MSC event". Wrong. Method: parked-VM
RAM dump + kernel-stack forensics (module base solved via the loader's own
relocated symtab found in the dump; core VA c017c000 confirmed by five
self-consistent internal call targets). The parked thread's stack:

    insmod(soc_msc) -> do_init_module -> do_one_initcall -> msc_init
    -> __platform_driver_register -> driver_register -> bus_add_driver
    -> bus_for_each_dev -> __driver_attach -> device_lock(dev)
    -> mutex_lock -> __mutex_lock_slowpath -> schedule  (idle)

In 4.4 `__driver_attach` holds `dev->mutex` across each probe. The prior
modules **soc_i2c** (`jz_i2c_hal_disable_smb`, 0x10050000 unmapped) and
**soc_aic** (`aic_hal_init`, 0x10079000 unmapped) had died in data-bus-error
oopses *mid-probe while holding that mutex* — a kernel oops kills the insmod
task and the mutex is never released. soc_msc's attach then walked the bus
into the dead-held device and blocked forever. The MSC stub was innocent.

### Fixes (all verified by boot)

1. **Persistent stubs** for I2C0/1/2 (0x10050000/51000/52000), AIC
   (0x10079000), SADC (0x10070000 — soc_adc died the same way), and msc1
   (0x13460000 — the msc1 probe itself bus-errored on MSC1+0x8).
   Result: soc_i2c/soc_aic/soc_adc load clean; **both msc hosts register**
   ("md_ingenic,mmc.0/1: register success!").
2. **CGU trigger semantics.** cgu_divider_enable (0x803ff640) writes the CE
   bit (e.g. +0x20=0x8 div_msc0, +0x74=0x20000000, +0x68 gate RMW) then
   polls the SAME register for ZERO — HW applies and self-clears (~1M
   bounded poll). Persistent read-back kept the poll failing ("WARNING :
   why cannot wait cgu stable ???" ×N), the vendor framework's error path
   oopsed the mmc_rescan kworker (clk_set_rate unlocking a mutex with a
   corrupt wait list), and the kworker died mid-unlock leaving
   module_mutex with a stale WAITERS flag. Fix: CGU offsets written since
   reset read back 0 (+0x2c stays the all-locked PLL status). Warnings
   gone; msc registration 5.5/8.1s -> 4.3/4.3s.

### Boot state now (v0.63)

- ALL soc modules load through the full rcS chain: touch probe succeeds
  over the I2C stub ("Touch Screen(I2C BUS) driver prboe successfully"),
  LCD registers, wifi powers up, sound-card modules chain.
- **UBIFS on erased userdata WORKS** (M2 task 5): ubi1 attaches mtd6,
  empty-device path, "UBIFS (ubi1:0): default file-system created".
- Userland runs (splash: cmd_jpeg_display — oopses on the unmapped JPEG
  block 0x13050000, non-fatal, killed by SIGBUS-style die).
- Remaining faults, in causal order:
  a. **cywdhd (wifi) fails EEXIST after a 39 s SDIO wait**: it registers
     its wifi device at 15.5 s, waits for the SDIO card on msc1 (the
     R1's wifi IS an SDIO device on msc1 — our inert stub never
     enumerates one), re-registers "md_bcmdhd_bt_power" at 54.7 s ->
     -EEXIST -> module freed -> **dangling device at c04060a4** on the
     platform bus.
  b. The dangling device kills every later device-registration attach
     (`__device_attach_driver+0x24` page fault; keyboard_adc, leds_pwm,
     sa_config, sa_earpods insmods die — each leaking whatever its probe
     held).
  c. The sound-card insmod (x1600_hiby_r1_sound_card, last initcall)
     blocks in mutex_lock on a codec-board mutex leaked by one of those
     dead probes — **the current rcS stall** (boot silent except a 220 ms
     adc-timeout kworker poll; SADC stub needs minimal conversion
     semantics eventually).
  d. soc_efuse returns -1 twice (EFUSE block unmapped — M2 task 4).
- **MSC register map for free**: the driver's own timeout REG dump names
  the block: CTRL2 STAT CLKRT CMDAT RESTO RDTO BLKLEN NOB SNOB IMASK
  IFLG CMD ARG RES LPM DMAC DMANDA DMADA DMALEN DMACMD RTCNT DEBUG
  (e.g. CMD=0x37/ARG=0xc00 = CMD55, CMD=0x34 = ACMD41-ish writes seen).

### Next (revised — to reach the M2 exit)

1. **MSC1 + SDIO card-present model** (upgraded from "no-card path"): the
   R1's wifi lives on msc1, so cywdhd needs the SDIO enumeration to
   complete (CMD5/CMD3/CMD7 + the card-interrupt path is NOT needed for
   module load). That removes the 39 s wait, the EEXIST, the dangling
   device and the whole cascade in one move. The register map above is
   the modeling contract; CMD flow observed: CMD8?, CMD55+ACMD41 loop
   (op:55 arg:0), then op:8.
2. EFUSE stub (task 4) — cheap, clears the -1.
3. SADC minimal semantics (answer conversions) — clears the 220 ms spam
   and un-blocks adc-dependent probes.
4. JPEG block stub 0x13050000 — clears the splash oops.
5. Then rcS continues past the sound-card mutex (no more leaks) to the
   theme and `S92_03_start_music_player` — the M2 exit.

## v0.64 (2026-10-13, fifth session): MSC0/MSC1 host models + SDIO wifi card

### What was built (qemu commit e282fd9, exported as patch 0005)

Task 1 of the v0.63 list, on the register map the driver's REG dump gave
for free (CTRL2 STAT CLKRT CMDAT RESTO RDTO BLKLEN NOB SNOB IMASK IFLG
CMD ARG RES LPM DMAC DMANDA DMADA DMALEN DMACMD RTCNT DEBUG — jzmmc_v12
layout, cross-checked against the X1000 SDK's jzmmc_v12):

- **Correction first**: the wifi is on **msc0**, not msc1 as v0.63
  guessed. msc0 is rm_method=manual — the DHD's
  wifi_platform_bus_enumerate(1) triggers jzmmc_manual_detect(0)
  synchronously — and the boot log's SDIO activity is all on mmc0.
- **msc0 @0x13450000 (INTC 37) = the wifi host, card present.** Card
  model = BCM43438/AP6212 (per the rootfs firmware fw_bcm43438a1.bin +
  nvram_ap6212a.txt; vendor 0x02d0 device 0xa9a6): CMD5 (R4 OCR: ready,
  1 IO function, voltage window covering the host's 1800–3300 mV — the
  first R4 window missed the host ocr_avail and mmc_select_voltage
  bailed with -EINVAL, boot13), CMD3 (RCA=1), CMD7/CMD13 (tran state),
  CMD52 IO_RW_DIRECT (R5: func-0 CCCR space 0x00-0xff, common CIS at
  0x1000 with CISTPL_MANFID 0x02d0/0xa9a6).
- **msc1 @0x13460000 (INTC 36) = the TF slot, empty.** Commands complete
  FAST with STAT_TIME_OUT_RES so card scans fail cleanly — the v0.63
  6-second "timeout 3000ms op:55" retry spam is GONE (md_ingenic,mmc.1:
  "Got CD GPIO", "register success!", no loop).
- Completion protocol: synchronous — on CTRL_START_OP the command
  executes against the card model, STAT gets END_CMD_RES (+TIME_OUT_RES
  when no card), RES holds the response, IFLG latches the sources, and
  the INTC line asserts while (IFLG & ~IMASK) != 0. Per-command status
  is cleared first (a stale TIME_OUT_RES from a previous no-card scan
  became cmd->error = -ETIMEDOUT and reset-looped the enumeration).

### Boot evidence (v0.64, this session's run)

Progress: the mmc core now SEES the wifi card. Both hosts register at
4.5 s with no TF spam, and at 15.5 s the SDIO attach chain runs — the
core decided an SDIO card exists (CMD5 OCR handshake OK) and is
initialising it.

Still failing, in causal order:

a. **SDIO card init fails -34 (-ERANGE) at the CMD52/CCCR stage**
   (`mmc0: error -34 whilst initialising SDIO card` ×3 at 15.5 s — the
   rescan's per-frequency retries). -ERANGE in the mmc core =
   R5_OUT_OF_RANGE seen in resp[0]; our CMD52 RES carries only the
   8-bit data byte, so either the vendor host driver (soc_msc.ko)
   reassembles RES before storing cmd->resp[0] (flag/data placement),
   or the vendor core's R5 flag masks differ. NEXT DECODE: soc_msc.ko's
   response path + the vendor core's mmc_io_rw_direct_host / R5_* masks
   (kallsyms + disasm of vmlinux.bin) — no guess-fix.
b. cywdhd: the cascade is unchanged — 5 power-cycle loops 15.4→54.4 s
   ("failed to power up DHD generic adapter, 3 retry left" ...),
   dhd_module_init returns -19 (ENODEV), the immediate re-probe oopses
   on duplicate sysfs `/devices/platform/md_bcmdhd_bt_power`
   (-EEXIST → initcall -17), module freed → dangling device
   (c04060a8 region) on the platform bus.
c. The dangling device kills the module-chain tail again: keyboard_adc
   (#2), leds_pwm (#3), sa_config (#4), sa_earpods (#5), tcs1421 (#6),
   and the last initcall x1600_hiby_r1_sound_card (#7) — all
   `__device_attach_driver+0x24` paging fault, same as v0.63.
d. soc_efuse -1 twice ("EFUSE: failed to get efuse cfg wr_strobe").
e. UBIFS on erased userdata still works; after the sound-card oops
   (~55 s) the boot idles in the 220 ms ADC-timeout poll; rcS end
   state unchanged (theme / `S92_03_start_music_player` not reached).

### Next

1. Root-cause the R5/-ERANGE (a) — decode soc_msc.ko's resp[0]
   handling; expect a small RES-layout fix in x1600.c.
2. EFUSE stub (M2 task 4) — serve the chip ID, clear the -1.
3. SADC minimal conversion semantics — clears the 220 ms spam.
4. JPEG block stub 0x13050000 — clears the splash oops.
5. rcS → theme → `S92_03_start_music_player` — the M2 exit.

## v0.65 (2026-10-13, sixth session, IN PROGRESS): the R5/-34 root cause + the RES byte-window model

### The -34 root cause — SOLVED (binary-verified on both sides)

Two disassemblies pinned the CMD52 response contract exactly:

- **Vendor host driver** (`soc_msc.ko` `ingenic_mmc_command_done`): the core
  response word is composed from **THREE separate RES reads** —
  `resp[0] = (RES1<<24) | (RES2<<8) | (RES3 & 0xff)` for 32-bit responses
  (R1/R4/R5/R6/R7), and `resp[i] = (RES1<<24)|(RES2<<8)|(RES3>>8)` per word
  for R2 (12 reads). The Ingenic RES register delivers the response in
  byte steps, not as a static word.
- **Vendor core** (`vmlinux.bin` `mmc_io_rw_direct` @ VA 0x803902f8): the R5
  flag masks are NOT upstream-4.4 positions — `resp[0] & 0x800` → -EIO,
  `& 0x200` → -EINVAL, **`& 0x100` → -ERANGE (the -34!)**, and the data
  byte is `resp[0] & 0xff` (non-SPI path). The SPI path extracts data from
  `resp[15:8]` instead.
- The MANFID tuple parser (@ VA 0x80390cb4) stores `func->vendor` at
  func+0x16a and `func->device` at func+0x16c (LE, body[0]|body[1]<<8),
  plus card->vendor/device at card+0x2cc/0x2ce.

**The v0.64 bug**: the model returned the SAME value on all three RES reads,
so the composition ORed data bits into the flag positions — a CIS byte like
0x21 (bit 0 set) landed on bit 8 → -ERANGE. v0.64's `mmc0: error -34
whilst initialising SDIO card` ×3 died exactly there.

**Fix (x1600.c)**: model RES as a byte-window queue
(`x1600_msc_res_pop`) — read n returns, with `p = n + (n+1)/3`:
`bytes[p]` at [7:0] (n%3==0), `(bytes[p]<<8)|bytes[p+1]` (n%3==1),
`(bytes[p]<<8)|bytes[p]` duplicated (n%3==2, satisfying both the `&0xff`
and `>>8` forms). The queue is filled per command from the response word
(4 bytes MSB-first; empty on no-card timeout).

**Verified by boot (v0.65-a/b/c)**: ZERO `-34` lines — the SDIO card now
enumerates completely: `mmc0: new SDIO card at address 0001` (15.6-15.7 s,
right after the DHD powers the wifi rail). CCCR reads, the common CIS,
FBR1 and its CIS pointer all complete.

### The F1 CIS chain (func1 device id = 0x0004)

`bcmsdh_sdmmc_probe` (cywdhd 0x88928) gates the WLAN path on
**`func->device == 4`** (`lhu 364(s0); li v1,4; bne → bail`). Since the
DHD is the R1's own module and works on real hardware, the real card's F1
CIS MANFID must be {0x02d0, 0x0004}. The model now serves a separate F1
chain at fn0 0x1200 (FBR1 CIS ptr → 0x1200) beside the common CIS at
0x1000 (MANFID {0x02d0, 0xa9a6} — the chip id). Boot trace confirmed the
core reads the F1 chain at 0x1200-0x120a.

### NEW open fault: the DHD never registers its sdio driver

With the card enumerating, the DHD STILL fails (5 power-cycle retries →
-19 → re-probe EEXIST → dangling device → module-chain tail oopses #2-#7
→ the same rcS stall as v0.63/64). Evidence gathered:

- The sdio bus bind never happens: **zero DHD prints** although
  `dhd_msg_level` defaults to 0x100801 (DHD_ERROR on) and the sdioh layer
  `sd_msglevel` = 0x1 — the probe's prints would show. The probe does not
  run.
- The id table `bcmsdh_sdmmc_ids` (11 × 12-byte entries) is fine: nine
  Broadcom entries + catch-all {class 0x00, vendor 0xffff, device 0xffff}
  + terminator. The vendor core's `sdio_match_one` (@ VA 0x803908e0,
  decoded) matches the catch-all against func1 {class 0, vendor 0x02d0,
  device 4} — the match logic is NOT the problem.
- **gdb breakpoint evidence** (module core base 0x816dc000, solved from a
  pmemsave RAM dump via the probe prologue signature; probe =
  0x81764928, dummy = 0x81764dd0, register_client_driver = 0x81764f74):
  **zero hits** on all three, including `bcmsdh_register_client_driver`
  — so `sdio_register_driver` is NEVER called. The DHD's driver never
  registers with the sdio bus.
- Registration chain decoded from the module:
  `init_module` → `bt_power_dev_init` + `bt_power_init` +
  `dhd_wifi_platform_register_drv` (registers THREE platform drivers),
  and separately `dhd_bus_register` (0x9f070) → `bcmsdh_register`
  (0x85500) → `bcmsdh_register_client_driver` (→ `sdio_register_driver`).
  **dhd_bus_register's caller is NOT init_module** — the candidate is the
  platform-device probe path (bt_power_probe @ 0x8175fba4 /
  `dhd_wifi_platform_load` @ 0x8174aba8). PENDING: find why the chain
  stops before dhd_bus_register.
- The probe flow once registration works (decoded for the next round):
  `bcmsdh_sdmmc_probe` → `dhd_wifi_platform_get_adapter(3, ...)` →
  `wl_cfg80211_set_parent_dev` → `osl_attach` (NULL → -12) →
  `osl_static_mem_init` → `sdioh_attach` (sdio_enable_func → CCCR 0x02
  IOE write; sdio_set_block_size) → `sdioh_cfg_read` → `bcmsdh_probe` →
  dhdsdio probe → backplane (CMD53 modelling needed later).
- Note: the DHD reads "firmware and NVRAM path by CIS" (string in the
  module; `firmware_path`/`nvram_path` module params are read by
  init_module) — the rootfs has fw_bcm43438a1.bin + nvram_ap6212a.txt.
- Also observed: 16× FBR1+0x10/0x11 block-size writes with data=0 come
  from the soc_msc host driver itself (guest PC c017da38) — a vendor
  driver quirk, not the DHD.
- gdb/HMP mechanics that work: HMP `pmemsave` needs the filename QUOTED
  (`pmemsave 0 0x4000000 "/tmp/kilo/ram-e2.bin"`); gdb needs
  `set architecture mips:isa32r2` before `target remote`; the batch
  `interrupt` + `info breakpoints` path is flaky — prefer a definite-hit
  breakpoint or HMP stop while gdb is attached.

### Model state (x1600.c, uncommitted in the vendored QEMU repo)

RES byte-queue + per-command status clearing; fn0 space `cccr[0x1000]` +
`cis[0x400]` (common chain @0x1000, F1 chain @0x1200); CCCR rev 0x11;
CIS pointers 0x09-0x0b → 0x1000 and FBR1 0x109-0x10b → 0x1200; DEBUG
guest-PC annotation on the MSC trace lines (`x1600_msc_cpu`).

### Next

1. Find `dhd_bus_register`'s caller and why the registration chain stops
   (gdb: breakpoints on `bt_power_probe` 0x8175fba4 /
   `dhd_wifi_platform_load` 0x8174aba8 / `dhd_bus_register` 0x8177b070
   with a reliable stop; the last run was inconclusive on mechanics).
2. Once the sdio driver registers: walk the probe chain; the first card
   access will be CCCR 0x02 (IOE) via CMD52 — verify against the MSC
   trace, then the F1 backplane reads (CMD53 eventually).
3. EFUSE stub, SADC conversion semantics, JPEG stub 0x13050000 (M2 exit
   queue, unchanged).

## v0.68 (2026-10-14, eighth session, worktree qemu-dhd-backplane): the fn1-CIS FUNCE root cause of the 0xffffffff signature read

Scope this round: MSC/SDIO model + DHD backplane only (UART2/cmdline/LCD-tap
belongs to the sibling session). Baseline: main v0.67 + patch 0006 (NF=2) +
prior session's uncommitted continuation, committed here as patch 0007 after
stripping the temporary physical-memory scanner instrumentation from
x1600.c (TEMP DEBUG block in the ChipClkCSR write handler + the
system/physmem.h include it needed).

### Boot with 0007 (b68a-serial.log): the WARN reproduces

17.45 s, dhdsdio_probe_attach:
    WARNING ... sdio_ops.c:134 mmc_io_rw_extended+0xb0        (blksz == 0)
    WARNING ... lib/scatterlist.c:287 __sg_alloc_table+0x78   (nents overflow)
    F1 signature read @0x18000000=0xffffffff
    si_doattach fails -> "dhdsdio_probe_attach: si_attach failed!" (3 attempts)

### Decode chain (all from vmlinux.bin + cywdhd.ko, tooling in /tmp/kilo/dhd + dhd2)

- sdio_io_rw_ext_helper (0x80391b6c) is vendor-modified vs upstream:
  * entry gate card[712] bit0 = cccr.multi_block (the CCCR bitfield byte
    parsed in mmc_sdio_init_card: bit0 <- CCCR 0x08 & 0x02 SMB, bit1 <- &0x40,
    bit2 <- &0x80 via seb/bgez, bit3 <- reg 0x12 & 1).
  * byte-path blksize selector: card[368] bit1 -> func->cur_blksize (0x174)
    vs func->max_blksize (0x170); bit8 -> additionally clamp to host[440].
  * block path always uses func->cur_blksize as unit (divu at +0xd4).
- mmc_io_rw_extended (0x803902f8): WARN at line 134 = blksz == 0 (arg8).
  Byte path computes nents = (blksz-1)/card[428] + 1 BEFORE choosing
  sg_init_one -- with blksz = 0 the (blksz-1) underflows to 0xffffffff ->
  nents huge -> sg_alloc_table WARN (scatterlist.c:287) -> -ENOMEM, and no
  MMC command is issued.
- sdio_readl returns 0xFFFFFFFF on error -> "F1 signature read
  @0x18000000=0xffffffff" -> si_doattach fail. No CMD53 reaches the MSC.
- THE WORD READ IS fn1, NOT fn0: bcmsdh_reg_read (0x84a40) word path calls
  sdioh_request_word(sd, cmd_type=0, rw=0, fn=1, addr|0x8000, size, &word)
  (0x84ae0: li a3,1; 0x84ac0-84ac4: movz a1, addr|0x8000, size^4). 0x8000 =
  the fn1 32K data-port window (low 15 bits of the backplane address).
  sdioh_request_word uses sd->func[fn] (0x87244: lw a0,1016(s5), s5=sd+4*fn).
  The fn0 pseudo-func (&sdioh+616 = sd->func[0], memset-zero) is only used
  by genuine fn0 word reads, which never happen here. The v0.65 fn=0 theory
  was wrong.
- Who zeroes cur/max: sdio_bus_probe (0x803909a8) calls
  sdio_set_block_size(func, 0) before every driver probe (0x80390a24;
  host[416] bit 0x2000 disables it). Vendor sdio_set_block_size
  (0x803915bc) blksz==0 path: blksz = min(func->max_blksize, host[440]),
  writes FBR+0x10/0x11 and func->cur_blksize -- it never writes
  max_blksize. func->max_blksize is set ONLY by cistpl_funce_func
  (0x803912b0): max_blksize = buf[12] | buf[13]<<8; requires size >= 42
  when cccr.sdio_vsn != 0 (28 only for spec 1.00); buf[28..29]*10 ->
  func+376. The v0.65 note "no writer of func+368 exists" was wrong --
  the writer is the FUNCE CIS tuple parser.
- Our model's fn1 CIS (MANFID+FUNCID only) has no CISTPL_FUNCE ->
  max_blksize(fn1) = 0 -> cur(fn1) = 0 after sdio_bus_probe -> the word
  read dies with blksz=0 as above. The live cur(fn1)=64 seen by the v0.66
  scanner came later (sdioh_start: sdio_set_block_size(func1,
  sd_f1_blocksize=64) at 0x8839c; fn2 <- sd_f2_blocksize=128 at 0x8840c).
- Fake-func facts re-confirmed: sdioh_attach (0x87e64) mallocs 1048 B,
  sd.func[0] = &sd.card (sdioh+616), sd.func[1] = card->sdio_func[0]
  (card+728), sd.func[2] = card->sdio_func[1] (card+732). mmc_card:
  +360 = type (3 = SD combo), +704 = cccr.sdio_vsn, +712 = cccr bitfield
  byte, +716..724 = cis (vendor/device/blksize?/max_dtr), +728 =
  sdio_func[].

### Fix (model-side, zero firmware change)

Add a 42-byte CISTPL_FUNCE (0x22) tuple to x1600_msc_cis_f1 with
TPLFE_MAX_BLK_SIZE (buf[12..13]) = 64. Then sdio_bus_probe's
set_block_size(func1, 0) sets cur(fn1) = 64 before the DHD probe, and the
F1 signature read becomes a CMD53 fn1 byte-mode count=4 @0x8000 that the
model already serves from the backplane window.

### v0.68 (cont.): the CMD53 data path + the chip badge (same session)

- The remaining hang after the FUNCE fix was the MSC model's CMD53
  completion signaling. Decoded soc_msc.ko (ingenic_mmc_request 0x1b88,
  the PIO/DMA poll loop 0x2238-0x22e8, thread 0xe94, state machine 0xb34,
  polling_status 0x638):
  * request fn rejects requests while host[2372] bit0 is clear
    (cmd->error = -159 + mmc_request_done).
  * After CTRL START_OP: polling_status waits END_CMD_RES (STAT bit11,
    model already sets it), command_done reads RES, then the request fn
    polls STAT in a loop at 0x2244: while STAT bit6 (0x40) is SET it
    spins (its dma flag host[2372] bit0 is 1 for our requests). When
    bit6 is CLEAR and (STAT & 0x3f) == 0 (the delay slot at 0x2260
    overwrites v1 with STAT&0x3f, which is what 0x22a8 tests) it drains
    MSC_RXFIFO 0x38 word-by-word into the sg buffer (0x22b0, kseg0 VA
    computed from the sg page walk) plus a byte-tail loop, then
    bytes_xfered = blksz*blocks, polls polling_status(0x1000) for reads
    / (0x2000) for writes (request fn 0x2338-0x234c), then completes the
    request itself (mmc_request_done at 0x23c4).
  * The v0.65 reading "STAT bit6 = RX ready, driver polls it" was
    INVERTED: bit6 set = hang ("timeout 3000ms op:53 ... state:0"), the
    driver wants bit6 CLEAR to start draining.
- Model fix (x1600.c CMD53 handler): removed the STAT bit6 set; set
  STAT bit12 (0x1000) on CMD53 reads / bit13 (0x2000) on writes so the
  post-drain poll exits.
- Boot b68h: "F1 signature read @0x18000000=0x424380a1" — the full
  kernel->helper->CMD53->FIFO->window path WORKS. si_doattach still
  fails because 0x424380a1 was a placeholder.
- si_doattach decode (cywdhd 0x2d3d0): the word at SI_ENUM_BASE
  (0x18000000) is the chipcommon CHIPID badge: sih->chip = sig & 0xffff,
  chippkg = (sig>>16)&0xf, (sig>>20)&0xf -> sih+68, rev = sig>>28 (the
  (sig&0xfffff)==0x24335 case applies a -0xfffc rev fix). rev==0 ->
  sb_scan; (rev & 0xfffd) == 1 (rev 1 or 3) -> ai_scan (EROM walk);
  anything else loops back re-reading the signature. Expected chip for
  this board: BCM43430A1/AP6212 (fw_bcm43438a1.bin, nvram_ap6212a.txt,
  and the common-CIS MANFID device 0xa9a6) -> badge word should be
  (rev<<28) | 0xa9a6, rev=1 -> 0x1000a9a6. Next: ai_scan/EROM walk.

### v0.68 (cont.): chip badge works, DHD walks the enum; parked at the GCI/PMU poll loop

- Model badge 0x1000a9a6 accepted: "F1 signature read @0x18000000=
  0x1000a9a6", si_doattach rev=1 -> ai_scan -> the module's built-in
  bcm43430_* tables (no EROM access at all). Tables extracted from
  cywdhd.ko .data (file off 0xc7540):
    coreid   : 0800 0812 0829 082a 080e 0240
    coresba  : 18000000 18001000 18002000 18003000 18004000 19000000
    coresba_size: 1000 1000 1000 1000 1000 10000
    wrapba   : 18100000 18101000 18102000 18103000 18104000 18106000
    cia      : 4bf80001 4bf81201 4bf82901 4bf82a01 4bf80e01 43b24001
    cib(43430): 31004211 27004211 15004211 09004211 16080401 00080201
    cib(43436): 31004211 27004211 18004211 0b004211 19080401 00080201
  ai_scan memcpy's 6*4 words of each into si_info (+128 coreid, +256
  coresba, +640 sizes, +1024 wrapba, +1408 cia, +1536 cib, card_rev==2
  selects the 43436 cib) and sets numcores=6 (sih+140), sih+148 =
  0x18107000.
- Window protocol confirmed live: SBADDRLOW (fn1 0x1000a) holds ONLY
  backplane bit15 (brcmfmac "b15"), SBADDRMID (0x1000b) bits[23:16],
  SBADDRHIGH (0x1000c) bits[31:24]; CMD53 port = 0x8000 | (addr&0x7fff).
  The DHD walks chipcommon (0x18000000, reads +0xfc etc.), then GCI at
  0x00410000 (reads +0x29e0..+0x29e8) and PMU at 0x00428000 (reads
  +0x4..+0x18 = pmucapabilities/res_state/res_pending/res_dep*) via
  SBADDRMID 0x41/0x42 — the DHD KNOWS these bases independent of the
  core table (hardcoded 43430 addresses).
- PARKED BLOCKER: the DHD then spins forever re-issuing the same
  GCI+PMU register reads (~1.09M requests in a 60 s boot: GCI+0x29e0/4/8
  and PMU+0x4/8/c/10/14/18, plus CMD52 fn0 CCCR-0x00 reads between
  groups). Model returns zeros; some polled register must report a
  specific value (likely a PMU res_state/res_pending ready bit or a GCI
  status) to break the wait. Next round: decode the cywdhd function
  driving this loop (it runs between si_doattach and the firmware
  download; find it by breaking on the SBADDRMID=0x41 write path or by
  xrefs of the 0x410000/0x428000 bases), feed it the expected PMU/GCI
  values, then expect the firmware download (SOCSRAM at core 0x80e,
  0x18004000) and dhdsdio_download_firmware.
- Boot-state files: /tmp/kilo/dhd2/b68{a..j}* (serial + -d unimp MSC
  traces), tools/patches/qemu-x1600/0007 + 0008 exported.

## v0.69 (2026-10-14, gci round) - the "GCI/PMU poll loop" decoded: it is the
RAM-size walk; unmapped backplane now reads 0xffffffff (patch 0009)

- **The poll loop is not a GCI/PMU poll.** Full-stream decode of
  /tmp/kilo/dhd2/b68j-unimp.log (1,092,800 MSC commands) with a new
  streaming decoder (/tmp/kilo/gci/mscdec_stream.py, mscsum.py,
  mscsample.py, bpmax.py): after si_doattach's chipcommon reads
  (badge @0x18000000 = 0x1000a9a6 via SBADDRHIGH=0x18 window, then
  chipcommon+0xfc) the DHD sets SBADDRLOW/MID=0 and issues a LINEAR
  WORD-BY-WORD SCAN of the backplane starting at 0x00000000:
  CMD53 fn1 byte-mode count=4 reads, arg op=1 (incrementing), 8192
  reads per 32K window, one CMD52 word read at fn1 0xfffc (the
  window's last word) per window, SBADDRLOW bit15 / SBADDRMID
  switching inside bcmsdh_reg_read (its set_sbaddr_window call is
  at bcmsdh_reg_read+0x5c/0x64, relocs 0x84a9c/0x84aa4). The v0.68
  "GCI+0x29e0 / PMU+0x4..0x18" observations were just points along
  this walk (0x4129e0 passed near the b68j tail; PMU 0x428004+ is
  past it). Rate ~18k reads/s traced, ~90k/s untraced.
- **The walk never terminated on the all-zero model.** Scanprog
  instrumentation: base 0x3c10000 at 135 s, 0x5f58000 at 277 s -
  it walks the full 32-bit space (~4.7 h at the model's PIO rate)
  because every word reads 0.
- **Exit condition proven experimentally** (temporary model fills,
  stripped before commit): filling non-chunked backplane reads with
  0xff breaks the walk immediately and the boot proceeds; filling
  only [0x80000,0x18000000) breaks it at the first non-cached
  window there. The walk checks every word and stops at the first
  nonzero read; it is the DHD's RAM size walk inside si_doattach
  (it runs between si_doattach's chipcommon reads and si_doattach's
  return; si_doattach then fails fast with no further SDIO traffic
  whenever the walk's break position is not the real RAM end).
- **Trap found on the way: the 16-slot bp_chunks cache.** The walk
  allocates a zero chunk per visited window, so with a fill that
  only covered [0x80000,...) the cache still served stale zero
  chunks and let the walk overrun to ~0x88000; si_doattach then
  rejected the size. The unmapped check must precede the chunk
  lookup.
- **Model fix (vendored qemu d71ffbe, exported as
  tools/patches/qemu-x1600/0009):** backplane windows in
  [0x80000, 0x18000000) read 0xffffffff, on the CMD53 path (before
  the chunk lookup) and on the CMD52 fn1 word path (the window-end
  reads). With this the walk breaks at exactly 0x80000 (the
  43430A1's 512KB SOCSRAM) in ~1.1 s and the boot reaches the next
  blocker in seconds instead of hanging for hours.
- **Next blocker 1: si_doattach still fails** ("dhdsdio_probe_attach:
  si_attach failed!") in ~1.2 s per attempt, with no further SDIO
  reads after the walk - a local check rejects the walk result or a
  later init step. Break position makes no difference (tried
  0x48000 / 0x7fffc / 0x80000). The walk's exact function could not
  be pinned down: the live module is vmalloc'd (kseg2, per-boot
  base), the stack sniff at the SBADDRMID window writes gave the
  chain insmod -> probe -> ... -> bcmsdh_recv_buf/reg_read ->
  sdioh_request_word -> mmc but the return words did not resolve
  against the .ko (relocated + per-boot layout); candidate
  mechanisms: si_socram_size-style scan or OTP/SROM shadow search.
  dhd_sdio.c CIS loop (bcmsdh_cis_read(sdh, fn, cis, 512) per fn,
  limit = bcmsdh_query_iofnum) sits before si_attach and is NOT the
  walk (its reads are CMD52 bytes / 512-byte reads).
- **Next blocker 2: 512-byte reads hang in the soc_msc DMA path.**
  "md_ingenic,mmc: timeout 3000ms op:53 r sz:512 state:0 STAT:0x1800
  DMALEN:0x00000000 blks:0/1" - the request never reaches the MSC
  (no CMD/ARG writes logged, state 0): 512-byte transfers go through
  the SoC DMAC (dmaengine) and the model implements no DMAC device
  at all. These are the probe's CIS reads
  (bcmsdh_cis_read(sdh, fn, cis, 512)) and will also carry the
  firmware download. Implementing the Ingenic DMAC (descriptor
  chain + completion IRQ, pattern like x1600_sfc_dma) is the next
  model work.
- Evidence: /tmp/kilo/gci/run1/ram.bin (mid-walk RAM dump),
  run6/run8/run9/run11/run12 MSC + console logs, stack walks
  (run6/msc.log n_scan=20000 section), mscdec_stream.py /
  mscsum.py / mscsample.py / bpmax.py / stackscan*.py / bootdump.py.
  Patch 0009 exported; vendored qemu committed.

## v0.70 (2026-10-14, pdma-dmac round, worktree qemu-pdma-dmac) - the SoC DMAC
(PDMA) decoded end-to-end from the stock kernel binary + the first-boot trace

- **Baseline re-check (merged state, patch 0009 in).** The boot no longer
  hangs in the walk: it reaches the player GUI (~30 s) with the DHD
  failing through 4 power-cycle rounds: per attempt "F1 signature read
  @0x18000000=0x1000a9a6" -> ~5.2 s silence -> "dhdsdio_probe_attach:
  si_attach failed!" -> "probe of mmc0:0001:N failed with error -12"
  (-ENOMEM), 2 probes per round (fn1+fn2), dhd_module_init returns -62
  after "try cnt 3..0". NO "timeout 3000ms" print in this state, and
  oopses #1-#6 = __device_attach_driver BadVA c04060a8 at 107.7-108.2 s
  (the module cascade the round has to clear). Gate baseline
  docs/traces/boot-baseline-v0.70.txt matches this window.
- **The DMA evidence (one boot, -d unimp, /tmp/kilo/pdma/run1/).** The
  PDMA stub sees exactly 6 accesses in the whole boot: probe writes
  0x13421000=1 and 0x13421030=1 (plus one read of 0x13421030), and ONE
  channel programming at the first 512-byte transfer:
  0x13420018=0x3af4000 (DDA: descriptor base, physical RAM), 0x1342100c=1
  (IRQ enable, channel 0), 0x13420010=0x40000001 (CTL: start, bit0).
  No MSC register writes follow it (the driver stalls right after
  arming - the transfer never completes, so every later attempt's prep
  fails and nothing re-arms). Everything else in the 24.1M-line trace is
  OST/INTC polling plus the walk's MSC PIO windows.
- **Driver decode: ingenic_dma (the stock kernel's SoC DMAC driver),
  vmlinux.bin 0x80400600-0x80402550, kallsyms ingenic_dma_*.**
  Register map (from the disassembly + the trace):
  - per-channel regs at 0x13420000 + ch*0x40 (16 channels fit below the
    IRQ block): +0x08 DTC (read: current count; tx_status progress),
    +0x10 CTL (write bit0 = start; the IRQ handler writes 0 on
    completion), +0x18 DDA (descriptor-chain base, physical).
  - global/IRQ block at 0x13421000: +0x04 IRQ pending (1 bit per
    channel; read = raw & enable; write-1-clear acks),
    +0x0c IRQ enable (1 bit per channel). Probe writes +0x00=1 and
    +0x30=1 are stored with no pinned semantics. use_external_trigger
    also writes +0x60=0x90 for one path (not hit by the msc flow).
  - IRQ: INTC line 3 ("pdma" per the DTB interrupts <3> <4> "pdma"
    "pdmad"; line 4 = pdmad_int_handler reads +0x1010/+0x1014, line 5 =
    the MCU node's pdmam, a no-op stub handler). The probe unmasks INTC
    lines 3, 4, 5 (IMCR 0x8/0x10/0x20 in the trace).
  - Descriptor: 16-byte records in guest RAM {cmd, sadr, dadr, dln},
    laid out contiguously by prep_slave_sg; the engine walks them in
    order; cmd bit0 = IRQ-enable per desc, cmd bit1 = LAST descriptor
    (the driver ORs 2 into the final one). The msc path's cmd word =
    chan[144]|0x80 = 0x80 (fifo-side width 4 -> 0). CTL register value
    0x40000001 = swdesc[68] (0x40000000, set in prep) | 1.
  - build_one_slave_desc: DLN = min(sg len, 512) & ~3 (capped to the
    MSC block size), SADR/DTA from the sg address / the slave_config
    FIFO address, DSCR = the next descriptor (in-chain).
  - ingenic_dma_config: the vendor dma_slave_config puts the FIFO
    address at +4 (RX src) / +8 (TX dst), the fifo-side width at
    +12 (RX) / +16 (TX) in {1,2,4} (4 -> chan[144]=0), the burst at
    +20/+24, and the dreq at +32 (byte) -> chan[0x78]. dreq numbers =
    dt-bindings/dma/x1000-dma.h: MSC0_TX=0x1a, MSC0_RX=0x1b,
    MSC1_TX=0x1c, MSC1_RX=0x1d. The DTB msc nodes have NO dmas cells -
    the channels come through ingenic_dma_filter_fn (param bits
    [15:8] = dreq, bit16 = "check reserved-chs", bits [20:19] = engine
    type; the filter stores param[7:0] into the channel).
  - Completion: pdma_int_handler reads +0x1004, acks (write-1-clear),
    per channel: reads CTL, writes 0, completes the swdesc, frees the
    descriptor block (dma pool free; ctrl[152] -= n), clears the
    channel's active pointer, completes a completion embedded in the
    channel struct, and re-calls start_trans for queued work.
  - Quota: alloc_swdesc fails (NULL -> prep -> -ENOMEM) when
    ctrl[156] - ctrl[152] < nsg; free_swdesc returns the descriptors.
    With the transfer never completing, ctrl[152] stays at its first
    allocation and every later prep fails: that is the boot's
    "-ENOMEM" cascade (si_attach failed / probe error -12).
- **MSC driver decode (module soc_msc.ko = the live "md_ingenic,mmc"
  host; the built-in copy in vmlinux.bin 0x80403ff0+ is the same
  source).** ingenic_mmc_request: blksz < 64 -> host[2372] |= 4 (the
  PIO/word path: polling_status, no DMA); otherwise the CMD53 runs the
  DMA path: sg entries staged into host[828+], MSC_DMAC (0x44) = 9 or
  25 (bit0 = DMA mode, high bits = the burst encoding from the sg
  alignment), regs[0x48] = a staged sg address, CTRL = 0x4 (START_OP),
  then IMASK = (CMDAT mirror & ~0x8908) - for CMDAT 0x201 that unmasks
  nearly everything incl. the data-done bits (the walk phase keeps
  IMASK = 0xffffffff: the wifi host is fully poll-driven). Data-done
  source = MSC IFLG bit15 (0x8000): ingenic_mmc_thread_handle's final
  pending case wakes flag bit4 -> state 4 -> ingenic_mmc_data_done ->
  mmc_request_done; the handler acks IFLG with write-1-clear and re-
  masks. CMDAT bit0 = DMA enable flag (the CMDAT mirror |= flags|1).
  IFLG bit7 = the SDIO irq callback path (not needed yet). The kernel
  copy's request fn also references dev->dma_ops (+24/+28 =
  sync_single_for_cpu/device) - the sg cache sync, not a request hook.
- **Channel request mystery (parked, not blocking the model):** neither
  the built-in msc driver nor soc_msc.ko imports any dmaengine API, and
  no __dma_request_channel/dma_get_slave_channel call sites exist in
  the kernel image; yet the trace shows a genuine ingenic_dma
  start_trans (the 3 writes above) at the first 512-byte transfer, and
  the msc driver stalls immediately after arming (no MSC writes, no
  timeout print, no bus error). Candidates: a vendor hook reached
  through dev->driver_data (+24/+28 in the module's request fn), or a
  driver in the Modules list (soc_aic/soc_pwm import
  __dma_request_channel). The model's descriptor engine is
  driver-agnostic: the descriptor content (fifo side of SADR/DTA)
  identifies the transfer; the first instrumented boot will name the
  owner via the descriptor dump.
- Model work (next entry): PDMA engine in hw/mips/x1600.c (channels,
  DDA/CTL, descriptor walk, +0x1004 pending / +0x100c enable, INTC
  line 3), MSC CMD53 generalization (fn-space byte reads/writes +
  the armed-channel handshake + IFLG bit15 data-done).
- Evidence: /tmp/kilo/pdma/run1/ (ttyS0.log = the console 41.7k lines,
  unimp.log 1 GB), /tmp/kilo/pdma/ingenic_dma.dis + ingenic_mmc.dis +
  kernel.dis (objdump -b binary), soc_msc_req.dis (module .ko with
  relocs), /tmp/kilo/dtb-tree.txt (the pdma node), tools/toolchain
  objdump for the .ko symbol tables.

## v0.71 (2026-10-14, pdma-dmac round, worktree qemu-pdma-dmac) - the DMAC
question answered: the wifi data path is the MSC's INTERNAL DMA, not the SoC
PDMA; both engines decoded and modeled; blocker remains si_doattach's
post-walk check (v0.69 blocker 1)

- **Premise correction (the task's "512-byte transfers go through the SoC
  DMAC" is wrong for the current state).** A full re-decode of the live
  drivers shows: (a) the msc host driver ("md_ingenic,mmc" = soc_msc.ko,
  loaded at 0xc017c000 per the trace PCs; the built-in copy in
  vmlinux.bin is the same source) never imports any dmaengine symbol and
  the kernel image has no __dma_request_channel/dma_get_slave_channel
  call sites outside the serial driver (which fails: no dmas in the
  DTB); (b) the SoC PDMA channel programming seen in the traces
  (DDA/enable/CTL) happens at ~250 s guest time and its descriptor is
  {cmd=0xc90706, sadr=0x1800020 (PCM/TCSM fifo, dreq 0x20 =
  X1000_DMA_PCM0_TX), dadr=0x26bb800 (an audio buffer), dln=960} - it is
  the AIC/audio path, not the wifi; (c) the wifi's 512-byte transfers
  use the **MSC controller's internal DMA**: ingenic_mmc_request stages
  the sg into the module's uncached descriptor ring (the probe allocates
  a zeroed page, devm_ioremap_nocache's it, links 128 x 16-byte
  descriptors at host[828+12i] virt / host[832+12i] phys), writes
  MSC_DMADA (regs 0x48) = the first descriptor's physical address and
  MSC_DMAC (regs 0x44) = 9 or 25 (bit0 = DMA enable, bits [4:3] = the
  burst encoding from the sg alignment) right after MSC_CTRL = 4
  (START_OP). The sdio core's io_rw_ext_helper issues one sg entry per
  CMD53, so one descriptor carries the whole phase; the descriptor is
  {dcmd(0), dat(phys), dln, flags} with flags bit0 = end-of-chain (the
  driver writes 1). Completion = the MSC's own data-done source (IFLG
  bit15 -> thread wake flag bit4 -> state 4 -> ingenic_mmc_data_done);
  IMASK is unmasked for the DMA case (regs 0x24 = CMDAT mirror &
  ~0x8908). The walk phase keeps IMASK = 0xffffffff (fully polled).
- **SoC PDMA decode (vmlinux.bin 0x80400600-0x80402550, ingenic_dma_*
  symbols + the run1 trace) - see v0.70 for the full register map.**
  Channels at 0x13420000 + ch*0x40 (DTC +0x08 RO, CTL +0x10 bit0 start,
  DDA +0x18 descriptor base), IRQ block at +0x1000 (pending +0x04 w1c,
  enable +0x0c, one bit per channel, INTC line 3 per the DTB "pdma";
  line 4 "pdmad" reads +0x1010/+0x1014, line 5 = the MCU node's pdmam,
  a stub). Descriptors = 16-byte {cmd, sadr, dadr, dln} chains, cmd
  bit0 = IRQ-enable, bit1 = last; the dreq arrives via
  ingenic_dma_filter_fn (param [15:8] = dreq, bit16 = reserved-chs
  check, [20:19] = engine type); dreq numbers = x1000-dma.h (MSC0_RX
  0x1b, MSC0_TX 0x1a, MSC1 0x1c/0x1d, PCM0_TX 0x20). Completion frees
  the descriptor block (dma pool, ctrl[152] -= n against the ctrl[156]
  quota) and completes a completion embedded in the channel struct.
- **Model work (tools/patches/qemu-x1600/0010, commit e897c22 in the
  vendored qemu; gate boot-baseline-v0.70 PASS, boot window unchanged).**
  1. X1600 PDMA device at 0x13420000 (replaces the stub): the register
     map above; a channel arms on the CTL bit0 write (the driver's
     issue_pending precedes the peripheral command) and logs the DDA.
     Non-MSC targets (the audio PCM fifo) stay armed - the audio
     completion is future work, the boot runs with it idle exactly as
     before.
  2. MSC internal DMA: the CMD53 handler stages the data phase (wr,
     len, fn, addr, inc; multi-block phases > 512 stage without the
     fifo); the MSC_DMAC write with bit0 kicks it: the model reads the
     descriptor at MSC_DMADA, moves dln bytes between the fn space and
     guest memory in 512-byte chunks (the byte reader/writer shared
     with the CMD52 semantics), raises STAT XFER_DONE + IFLG bit15 +
     the msc IRQ.
  3. CMD53 fn-space generalization: x1600_msc_fn_read/fn_write cover
     fn0 (CCCR 0x00-0xfff, CIS at 0x1000-0x13ff) and fn1 (the SBADDR
     window regs, the ChipClkCSR ALP/HT mirrors, the 32K window bank
     chunks with the [0x80000,0x18000000) unmapped 0xff rule). The walk
     (fn1 window CMD53s) reads identical bytes through the new reader;
     the PIO path (blksz < 64, the request-fn STAT poll + the RXFIFO
     drain) is unchanged.
- **Current blocker, pinned precisely (v0.69's "next blocker 1", still
  standing): si_doattach fails immediately after the RAM-size walk.**
  Evidence (run5, 300 s, /tmp/kilo/pdma/run5/ + run7): the F1 badge
  read at 16.5 s, the walk's linear SRAM scan [0, 0x80000) (~5.2 s, 16
  windows x 8192 word reads, breaks at the first unmapped word =
  0x80000 with patch 0009), then "dhdsdio_probe_attach: si_attach
  failed!" with ZERO further SDIO traffic before it - no SOCSRAM core
  register reads, no CIS reads. The DHD's CIS reads are NOT 512-byte
  CMD53s: sdioh_cis_read (cywdhd.ko 0x88120) loops
  sdioh_sdmmc_card_regread(sd, fn=0, func_cis_ptr[fn]+i, 1, &b) - 512
  CMD52 byte reads per function into fn0's CIS space, which the model
  already serves; in run7's trace the fn0 0x1000 area gets only ~2
  CMD52 reads before the flow stalls, i.e. the probe never reaches the
  CIS loop at all - the walk itself (or the check on its result, in
  si_doattach.isra.10, the walk loop reads through the si_t/sb_t
  curmap indirection at +4/+44/+172/+1540 and the SOCSRAM bank loop at
  0x2dd4c-0x2de60 reads/writes curmap+184 with bit0 |= 1) rejects the
  state. Candidate next probes: dump the SRAM contents the walk saw
  (all zeros in the model - if the DHD expects the SROM/OTP shadow or
  a bank-valid bit set somewhere in [0,0x80000), the walk's break at
  0x80000 is "no RAM found"); decode si_doattach's post-walk branches
  (0x2d780-0x2e150) against the walk's result; or stop the VM mid-walk
  and resolve the interrupted stack (the pt_regs on the exception
  stack) against cywdhd.ko symbols - the module base for a boot can be
  recovered from an oops print (bcmsdh_sdmmc_probe+0x12c @ c03c5a54 =>
  base 0xc033d000 for run6).
- Note: the /tmp quota was exhausted during this round by two foreign
  qemu processes holding ~7.2 GB of deleted qemu.out (announced on the
  board; untouched per the no-pkill rule). If a future round sees
  "Disk quota exceeded" from compilers or the boot test, use
  --out on the main fs and TMPDIR there.
- Evidence: /tmp/kilo/pdma/run5 (console, timeline), run7 (mid-walk RAM
  dump + registers via the monitor: the walk task registers t3=0xffffffff
  = the unmapped read, sp 0x82005fc8), cywdhd_full.dis (module-wide
  objdump with relocs), syms.txt, si_doattach.dis, ingenic_dma.dis,
  soc_msc_req.dis; the gate pass with .cctmp/bt.

## v0.72 (2026-10-14, srom round, worktree qemu-wifi-srom) - the "RAM walk" decoded:
it is the AI EROM (enumeration ROM) walk, and the EROM lives at backplane
0x00000000

- **Premise correction (the brief's "SROM/OTP shadow in SRAM" is wrong).**
  The stalled walk is not a RAM-size scan of chip SRAM. Re-decode from
  cywdhd.ko (si_doattach.isra.10 0x2d3d0-0x2e150 has NO walk; it is clock
  handshake + chipid parse 0xa9a6/rev0/AI + ai_scan + core enum + CC
  workaround, returns sih):
  1. si_doattach reads the F1 badge at 0x18000000 through fn1 0x8000
     (CMD53 arg 0x15000004, count 4) = 0x1000a9a6 (chipid low16 = 0xa9a6
     = 43430, bits[31:28] = 1 = socitype AI), then ai_scan.
  2. dhdsdio_probe_attach (0x954d0): si_corerev, then si_setcore(0x83e
     ARM_CR4) -> not found on 43430 -> si_socram_size (0x308d4).
  3. THE WALK = ai_scan (0x212b4) COLD path: reads core0 (chipcommon)
     base+0xfc = 0x180000fc (bcmsdh_reg_read, ai_scan 0x214a0/0x214d8)
     = the EROM POINTER; eromlim = eromptr0 + 0xe00 (0x2158c addiu 3584);
     loop while eromptr < eromlim (0x215a4-0x215b0): get_erom_ent
     (0x20b30-0x20c28).
  4. get_erom_ent: reads 32-bit entries at *eromptr through the fn1 32K
     window (SBADDR updated per 32 KB), eromptr += 4 each read; with
     mask != 0 it skips entries with bit0 (ER_VALID) clear and LOOPS
     WITH NO BOUND on that skip path (0x20bd8 beqz v1,0x20b70) - the
     bound (s8 < 4096) only applies to valid entries that fail the
     mask/match. With the model's all-zero backplane every entry is
     invalid -> the skip loop reads [0, 0x80000) until the first
     0xffffffff (the patch-0009 unmapped rule), then 4096 more 0xffffffff
     words, then returns 0xffffffff. That is EXACTLY the observed
     16x8192-word walk to 0x80000 (v0.71 blocker). ai_scan then exits
     with zero usable cores -> "dhdsdio_probe_attach: si_attach failed!"
  5. run7 trace re-decode (/tmp/kilo/srom/run7.msc.txt, mscdec on
     run7/unimp.log): SBADDR 0x1000a/b/c = 00/00/18 -> badge reads at
     0x18000000 x2 (dhd + si_doattach), one read at 0x180000fc (the
     ai_scan EROM-pointer read), then SBADDR 00/00/00 and word reads
     stepping +4 from 0x00000000 (5981 captured, truncated mid-walk).
     The walk reads backplane [0,0x80000), NOT [0x18000000,0x18080000).
- **ai_scan WARM path = static 43430 tables (the ground truth for the
  EROM contents).** ai_scan 0x212b4: if global alive == 0x15151515 AND
  card_dev == 0xa9a6: numcores = 6, sih+148 (common/second wrap base) =
  0x18107000, and 6 memcpys from module .data tables (ELF syms, .data
  file off 0x0c7540): bcm43430_coreid@0x2a38, coresba@0x2a20,
  coresba_size@0x2a50, wrapba@0x29f0, cia@0x29d8, cib@0x29c0
  (bcm43436_cib@0x29c0 alt used when card_rev==2). Values:
    idx coreid coresba      wrapba      cia        cib
    0   0x800  0x18000000   0x18100000  0x4bf80001 0x31004211
    1   0x812  0x18001000   0x18101000  0x4bf81201 0x27004211
    2   0x829  0x18002000   0x18102000  0x4bf82901 0x15004211
    3   0x82a  0x18003000   0x18103000  0x4bf82a01 0x09004211
    4   0x80e  0x18004000   0x18104000  0x4bf80e01 0x16080401
    5   0x240  0x19000000   0x18106000  0x43b24001 0x080201
  coresba_size all 0x0. coreid 0x240 = the SDIO DEVICE core (0x19000000,
  outside the 0x180xxxxx range); 0x80e = SOCSRAM; 0x82a = ARM CM3; 0x829
  = MIPS74K; 0x812 = 802.11. cia>>8 & 0xfff == coreid for all 6
  (cia IS the EROM core-descriptor entry: bit0 = ER_VALID, bits[3:1]
  = 0 so get_erom_ent(mask 14, match 0) accepts it, (cia>>20) = 0x4bf
  except core 5's 0x43b = the special path ai_scan takes for the SDIO
  core, 0x215f8 li 1083).
- **EROM entry format decoded from get_erom_ent/get_asd/ai_scan:**
  get_erom_ent(sih, &eromptr, mask, match): ent = backplane[eromptr],
  eromptr += 4; if mask == 0 return ent raw; skip while (ent & 1) == 0;
  return when ent == 15 or (ent & mask) == match; bound 4096 skipped
  bytes on the valid-but-unmatched path only.
  Core sequence per core in the ai_scan main loop (0x215a4):
    cia = get_erom_ent(mask 14, match 0)  # (ent&0xe) must be 0
    cib = get_erom_ent(mask 0, match 0)   # raw next word
    fail if (cib & 0xe) != 0 (0x215f0)
    if (cia >> 20) == 0x43b and ((cia >> 8) & 0xfff) == 0xfff: skip core
    nwrap = (cib >> 9) & 0x1f; skip core if 0 (0x21608/0x21618)
    nmasters = (cib >> 14) & 0x1f (56(sp)); naddr?? = (cib >> 19) & 0x1f
      (68(sp)); if nmasters + naddr != 0 OR coreid in {0x367, 0x50b,
      0x827, 0x840}: process core (0x21638/0x21690)
    store: cia -> s0+1408+4n, cib -> s0+1536+4n, coreid=(cia>>8)&0xfff
      -> s0+128+4n (0x216c4-0x216cc)
    port loop: nwin = (cib >> 4) & 0x1f times: get_asd(sih, &eromptr,
      req 1, qual 1, idx t0, tag 2) (0x216dc-0x216ec); each returned ent
      must have (ent & 0xe) == 2 else fail (0x216f8)
    master-wrapper scan (0x21750-0x21798): get_asd(req 0, qual 0x40)
      repeatedly; fail if out2/out4 nonzero; loop continues while the
      returned size == 4096; s6=1 = found (0x21794)
    first asd addr -> coresba[n] = s0+256+4n (0x217cc), its size ->
      coresba_size[n] = s0+640+4n (0x217d0)
    second asd (req 1, qual 0x40??): 4096 -> s0+768+4n, addr -> s0+512+4n
      (0x2183c-0x21840) [wrapba at s0+1024 filled later in the loop]
    get_asd.isra.1 (0x21154): ent = get_erom_ent(mask 1, match 1) (VALID
      required); if (ent & 6) != 4 or ((ent >> 8) & 0xf) != req or
      (ent & 0xc0) != qual: eromptr -= 4 (undo), return 0; on match:
      addr = ent & 0xfffff000 -> arg5 out; if (ent & 8): size-ent =
      get_erom_ent(0,0) -> arg6 out; size = 4K << ((ent >> 4) & 3) when
      (ent & 0x30) != 0x30, else explicit size entries follow (arg7 out
      = ent & ~0xfff of the next, arg8 out = one more raw ent).

## v0.73 (2026-10-14, srom round, worktree qemu-wifi-srom) - THE WIFI DHD
ATTACHES: cywdhd insmod returns 0, all six module-cascade oopses gone, rcS
completes into the product app

- **The three model changes that did it (0011 patch, this round):**
  1. **AI EROM image at backplane [0x00000000, 0xa4)** (bp chunk key 0):
     the 40-entry enumeration ROM reproducing the six 43430 cores from
     the DHD's own warm-resume tables (bcm43430_coreid/coresba/wrapba/
     cia/cib, cywdhd.ko .data 0x29c0-0x2a68; entry format decoded from
     get_erom_ent/get_asd/ai_scan, v0.72). The EROM pointer is
     chipcommon+0xfc (0x180000fc) = 0. The walk now consumes all
     entries and exits cleanly at the ER_END marker (0x0000000f) in
     ~40 reads instead of 131k (run1 trace).
  2. **CCCR 0x03 (IO Ready) fn2 bit sticky**: the 0x02->0x03 mirror
     writes data|0x04. The DHD's bcmsdh_sdmmc_probe arms its
     static-core-table workaround at exactly "ready == 6" (alive =
     0x15151515 + card_dev, cywdhd 0x88cb8; the print "sdioh_probe,
     147, ready = %06x" shows it). Structural fact: the cold ai_scan
     EROM walk in this DHD build CANNOT count cores - the master-
     wrapper asd match (get_asd us 0, ms 1) sets s6 = 1 and ai_scan
     0x21a78 (bnez s6) skips the numcores++ for every wrapper-matched
     core; the only s6 == 0 exits are an unbounded scan or
     numcores = 0 (ai_scan 0x21a90). The warm-table path is how the
     real card attaches; with ready = 0x02 both probes failed
     (v0.72 run1), with 0x06 the first probe takes the tables.
  3. **AI wrapper responder** (0x18100000-0x18107fff, all six core
     wrappers in one 32 KB chunk): ioctrl (wrap+0x408) = 1 and
     resetstatus (wrap+0x804) = 1, everything else 0, so ai_iscoreup
     ((ioctrl & 3) == 1 && !(resetctrl & 1)) is true and _ai_core_reset
     never spins (v0.72 run2 looped there). Plus SOCSRAM core
     registers: coreinfo (0x18004000) = 0x20 (bits[7:4] = 2 banks),
     bankinfo (0x18004040) = 0x1f ((31+1) << 13 = 256 KB/bank = 512 KB
     total; socram_banksize asserts idx < 3 so 2 banks, not 4). Result:
     "DHD: dongle ram size is set to 524288(orig 524288) at 0x0".
  4. **ChipClkCSR ALP request bit**: the 0x1000e mirror also sets
     ALP_AVAIL (0x40) on the request bit 0x08 (sbsdio.h
     ALP_AVAIL_REQ = 0x08; dhdsdio_htclk wrote 0x08 and polled for
     0x40, run3 "HT Avail timeout (1000000): clkctl 0x08"). The 0x20
     and 0x10 rules stay (the probe's 0x28/0x21 self-checks pass).
- **Boot evidence (run4, /tmp/kilo/srom/run4):**
  [18.76] F1 signature OK, socitype:0x1 chip:0xa9a6 rev:0x0 pkg:0x3
  [18.99] DHD: dongle ram size is set to 524288(orig 524288) at 0x0
  [19.03] firmware path not found (one candidate path; harmless)
  [19.04] Register interface [wlan0] MAC: 00:90:4c:11:22:33
  [19.20] dhd_bus_devreset: WLAN OFF DONE (interface parks OFF)
  [19.38] WLAN placed in NOMAL OFF; the DHD retries its probe (fn1 +
          fn2, "ready = 00000006" both times now)
  [20.78] initcall dhd_module_init [cywdhd] returned 0 after 2.70 s
  [20.88-22.85] keyboard_adc_multifunc, leds_pwm_add, sa_config_module,
          sa_earpods_adc, tcs1421_add, x1600_hiby_r1_sound_card all
          "initcall ... returned 0" - THE SIX CASCADE OOPSES ARE GONE
          (0 "Oops[" lines in the whole 300 s log)
  [31+]  rcS continues: system message bus, network OK, sys_server,
          S80_bt_init (BT firmware BCM4343A1_...hcd selected), music
          player app: ot_device headset + 101-step gains, fb ready,
          hyn_ts ready - the product UI stack is alive.
- **Remaining noise (cosmetic, does not stop the boot):** the MSC host
  driver still warns per 4-byte PIO CMD53 write: "polling status
  (0x00000800) error, op=53, status=0x00001802" + "PIO mode: command
  response error" (msc.c:1017, ingenic_mmc_request+0xc8). The reads
  return correct data (the F1 signature + ram size prove it); the DHD
  parks the interface OFF at init exactly like the driver's flow wants.
  The wlan0 ifup/firmware-download flow (devreset ON) is future work if
  the trace demands it.

## v0.74 (2026-10-14, srom round, worktree qemu-wifi-srom) - the MSC PIO TX
path + clean attach; the round is gated

- **MSC CMD53 TX fix (the last "polling status(0x800/0x2000) error, op=53"
  spam, gone: run5 has ZERO host-driver warnings):** the host starts a TX
  CMD53 with NO fifo or DMA writes before it (run4 trace: arg 0x9500b004
  = W fn1 0x80b0 x4 with MSC_CTRL = START_OP immediately after CMDAT;
  MSC_TXFIFO (0x3c) and MSC_DMAC writes come only after the response for
  multi-block/DMA cases). The model timed out every small TX
  ("the driver never drives TX from the PIO fifo" was wrong for these).
  Now the CMD53 TX branch stages the phase (fifo_len/fifo_pos/dma_wr,
  res = 0) like the read branch, and the MSC_TXFIFO write handler
  appends the 4 pushed bytes little-endian, delivers them through
  x1600_msc_fn_write when the staged length is reached, sets STAT bit13
  (XFER_DONE_WR, the "polling status(0x00002000)" poll) and IFLG bit15.
  The host driver's warning trio ("polling status(0x00000800) error" /
  "PIO mode: command response error" / "operate in non-idle state",
  msc.c:1017) disappears entirely.
- **run5 evidence (/tmp/kilo/srom/run5, 300 s):**
  [18.17] F1 signature OK chip:0xa9a6; [18.20] dongle ram size 524288;
  [18.24] wlan0 registered MAC 00:90:4c:11:22:33; [18.26] WLAN OFF DONE
  (the driver parks the interface OFF at init, the app brings it up);
  [18.89] dhd_module_init returned 0 after 1.10 s (vs 2.70 s in run4);
  [18.94-20.15] keyboard_adc_multifunc, leds_pwm_add, sa_config_module,
  sa_earpods_adc, tcs1421_add, x1600_hiby_r1_sound_card all return 0;
  0 "Oops[" lines in the whole log; "Starting network: OK",
  "lg_system_main in", "product name: r1" - rcS completes into the
  product UI stack.
- **Gate:** baseline re-recorded as docs/traces/boot-baseline-v0.74.txt
  (the dmesg window changed materially: the wifi attach messages replaced
  the six oopses); tools/x1600-boot-test.sh PASSes against it.
