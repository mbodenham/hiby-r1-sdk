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

## v0.75 (2026-10-14, M3 opening round, worktree qemu-player-ui) - the
player's first UI frame reaches the screen: the SoC PDMA executes
memory-to-memory descriptor chains (the hgl blit path)

- **Symptom:** rcS completes, hiby_player's GUI stack runs to
  "lg_activity_mng: running activity lg_activity_main" +
  "event_input: event_x1000_detect" — and the screen stays on the
  theme:1 splash forever. Whole-boot console count of fb pan_display
  kicks: 2 (both the jpeg splash); zero afterwards. ~30 s later the
  GUI idle path blanks the panel: soc_fb.ko disable_fb spins 100×10 ms
  and prints "is_wait_stop_cnt >= 100" (v0.74 runs 55-85 s), then the
  touch suspends ("hyn_ts_suspend ... ret=-145").
- **Smoking gun (live guest inspection via the respawning console
  shell, run2):** /proc/<pid hiby_player>/task/*/wchan — the main
  thread blocks in **sahd_write** (sa_hgl_dma.ko), /proc/<pid>/stack =
  sahd_write+0x200/0x260 (the wait_for_completion call);
  /proc/interrupts shows `11: 0 INTC 3 pdma` — the PDMA IRQ had NEVER
  fired. The HiBy graphics layer (hgl_fb, statically linked into
  hiby_player) opens /dev/sa_hgl_dma and every GUI draw is a write()
  of a 16-byte blit command; the kernel module builds an
  ingenic_dma descriptor chain, submits it through the dmaengine API
  (device_prep at dma_device+132 = tingenic_dma_prep_interleaved_dma,
  0x80401f24) and blocks in wait_for_completion until the PDMA IRQ
  (INTC line 3) completes it. The v0.71 PDMA model only ARMED
  channels ("waiting for the MSC data phase") — a pure memory-to-
  memory blit chain never executed, never completed: the player's
  first draw() call blocked forever, the GUI never drew, the screen
  never left the splash.
- **Descriptor format, decoded from the vmlinux ingenic_dma driver
  (symbols via /tmp/kilo/dhd2/ksall.txt: tingenic_dma_prep_dma_memcpy
  0x804012a8, prep_interleaved 0x80401f24, prep_slave_sg 0x804023e4,
  pdma_int_handler 0x804017ac, append helper 0x80400df8) and
  CONFIRMED against the live armed chain (devmem 0x12ab000 via the
  guest shell, then monitor xp dumps):**
  - 32-byte dma_pool records {cmd, sadr, dadr, dln, icg, 8, pad, pad}
    (alloc_chan_resources: dma_pool_create size=32; swdesc+0x38 =
    virtual ptr array, +0x3c = physical addr array; start_trans writes
    phys_array[cur] to the channel DDA reg +0x18).
  - cmd bit0 = per-descriptor IRQ enable, bit1 = last descriptor of
    the chain; class in cmd bits[23:16]: 0xc0 = memcpy (dln[23:0] =
    burst count, burst code in cmd bits[10:8], inverse table
    {1:0,2:1,0:2,3:3,4:4,5:5,6:6,7:7}), 0xc9 = interleaved 2D (the hgl
    blits: dln[23:16] = rows <= 255, dln[15:0] = row bytes; +0x10 =
    (dst_icg << 16) | src_icg), 0x80|burst = MSC FIFO slave (fifo
    address in sadr/dadr — those stay armed for the MSC model).
  - **Chain linkage: dln[31:24] = the NEXT descriptor's page slot** —
    the driver packs (next_desc_phys >> 4) & 0xff of the following
    pool object into the previous descriptor's dln (prep_slave_sg
    0x804024a4 ext v0,v0,0x4,0x8 / sll 0x18 / or into prev dln);
    next phys = (cur & ~0xfff) | (slot << 4). The 128-desc cap =
    one 4 KiB pool page.
- **First live blit (run2/3 evidence):** ch1, DDA 0x12a8000,
  desc {cmd=0x00C90706, sadr=0x03000020, dadr=0x026BB800,
  dln=0x005003C0} = 80 rows × 960 B — the hgl buffer (0x03000020,
  filled 0xE7BF by the player) into the fb buffer (0x026BB800; one
  full frame = 0xBB800 = 768000 = 480×800×2). The second write()
  chains 3 descriptors: 255 + 255 + 210 = 720 more rows = the full
  800-row frame.
- **Fix 1 — PDMA chain execution (x1600_pdma_exec_chain):** on the
  CTL start write the model now walks the chain (slot-linked, 128
  cap), executes 0xc9 interleaved row copies and 0xc0 memcpys with
  RAM bounds checks, skips MSC-FIFO descriptors (those keep the old
  armed behavior byte-for-byte), then completes the channel. IRQ
  semantics decoded the hard way in three steps:
  (a) the pending bit is NOT 1<<hw_channel — the driver writes
      +0x100c = 1<<*(chan+0x68) (the client's REQUEST LINE — hgl =
      req 2) in the same start_trans before the CTL start, so the
      model snapshots the single enabled bit at arm time (irqbit[]);
      with hw ch1 armed, the enable came out 0x4 (run3: IRQ 0 with
      bit1, then "dma0chan2" channel handling once bit2 delivered).
  (b) +0x1004 is a RAW SOURCE register, not W1C: the handler acks by
      writing the COMPLEMENT of the read value (nor v1,zero,s6; sw
      v1,0x1004). The first implementation's write-1-clear left the
      bit set → a 353k-line "channel irq with no active transfer"
      IRQ storm (run4). Plain store of the written value (read is
      still enable-gated) is the semantics that matches the driver.
- **Fix 2 — LCD engine stop-done IRQ:** disable_fb writes 0x10 to
  LCD +0x2000 (IRQ enable word, SLCD stop bit) then waits for
  jzfb+0x44 to clear; the model now latches STATE bit7 and asserts
  IRQ 31 on that write (x1600_lcd_update_irq gates on
  STATE & 0x20080 now), so the blank path completes in one IRQ
  instead of stalling 1 s ("is_wait_stop_cnt >= 100" gone).
- **A wrong first draft of the walk (24-byte stride + a raw-copy
  fallback for undecoded classes) read pool padding as descriptors
  and the fallback copied garbage — guest data bus errors
  ("Data bus error, epc == 40000010", then do_be/do_ade faulting
  recursively, run5/run7). The 32-byte slot-linked walk with no
  fallback (unknown classes log and skip) is clean: run8 = 4
  descriptors executed, 0 "Data bus error" lines.
- **RESULT (run8/run9, /tmp/kilo/ui/):** the player's first-boot UI
  renders on the emulated screen — the Language selection page
  ("Language": 简体中文 / 繁體中文 / English / 日本語 / 한국어 /
  Français, antialiased text, correct theme colors), stable across
  45+ s of polling (no blank, no corruption); the player's main
  thread leaves sahd_write (wchan poll_schedule_timeout);
  /proc/interrupts `11: 2 INTC 3 pdma`; /proc/interrupts jzfb = 3
  (2 splash pans + 1 stop-done). Evidence: /tmp/kilo/ui/run8/u1-*.png,
  u2-*.png (HMP screendumps on VNC 127.0.0.1:5910).
- **Boot-gate impact:** none expected — the blit path starts ~50 s
  (player stage), the gate window ends at the UBIFS marker (~19 s);
  the only pre-gate model change is the LCD +0x2000 latch, which no
  pre-gate flow writes (0 prior is_wait_stop in any boot log).
- **Gate:** re-recorded as docs/traces/boot-baseline-v0.75.txt (fresh
  image via tools/x1600/make_nand_image.py — the UBIFS formats
  in-guest on a fresh volume, so the terminal marker
  "default file-system created" only exists on a fresh image; rebuild
  before every gate run); tools/x1600-boot-test.sh PASSes
  (297 distinct messages, 158 structural lines). The v0.75 baseline's
  message set is byte-identical to v0.74's (the first comparison
  failed only on a console line-glue race: the
  `ubi1: background thread "ubi_bgt1d"` line printed glued onto the
  "UBI device number" line — a uart write-batching race, not a model
  change; the v0.74 capture had them split).
- **Operational lesson (cost: one shredded userdata volume):** the
  SFC model mmaps nand-r1.bin NEXT TO THE KERNEL read-write — two
  qemu instances booted from the same worktree directory (a gate run
  + a verification run) tear each other's UBIFS writes
  (2017 "ubifs_scan: bad node" lines in the concurrent gate run).
  The demo VM hiby-live-demo boots from the main repo's copy, so it
  is safe from worktree runs; worktree-local runs must stay
  serialized one VM at a time. Recovery = re-run
  tools/x1600/make_nand_image.py (deterministic: md5 ae41e974…,
  matching the baseline header).

## v0.76 (2026-10-14, M3 round, worktree qemu-vnc-input) - the emulated
R1 is INTERACTIVE: QEMU's VNC keyboard/mouse is wired into the guest's
evdev stack through faithful hardware models. Vendored qemu commit
621701f, exported as tools/patches/qemu-x1600/
0115-vnc-input-gpio-keys-cst8xx-sadc.patch.

- **Decoded guest input contract** (module params + module/vmlinux
  disassembly + the run8 stub trail):
  - `keyboard_gpio_add.ko` registers gpio-keys on GPIO PC31 = KEY_POWER
    116 (active_level=0) and PC28 = KEY_NEXTSONG 163 (active_level=1);
    irq-driven (gpio_keys_gpio_isr -> work -> input_event).
  - `keyboard_adc_multifunc.ko` polls the SADC channel 0 every ~100 ms:
    voltage = raw*3300>>12, key window = [value-100, value+100) mV.
    key1=0 mV -> 164 KEY_PLAYPAUSE, key2=1000 -> 114 KEY_VOLUMEDOWN,
    key3=1650 -> 115 KEY_VOLUMEUP. Idle raw 0xfff = ~3300 mV = no key.
    KEY_PREVIOUSSONG 165 has no source (key1's reuse code needs
    multifunc_enable=1).
  - `cst8xx_touch.ko` (hyn_ts) on i2c bus 1 @0x15: the INT is PA16
    (gpio 16, virq 100, IRQF_FALLING|ONESHOT); the touch frame is read
    from register 0x00 as 9 bytes (max_touch*6+3): buf[2]&0xf = the
    touch count, x = ((buf[3]&0xf)<<8)|buf[4], y = ((buf[5]&0xf)<<8)|
    buf[6] (hyn_irq_handler parse; buf[5]=y_hi <= 3 passes its <32
    record check). The driver reports MT-A (SYN_MT_REPORT/SYN_REPORT)
    + BTN_TOUCH and only emits events from the second read of a held
    touch (a per-slot frame counter gates the first).
  - `soc_i2c.ko` (jz i2c block at 0x10051000) drives the controller via
    MMIO and waits on INTC 60 per message. Empirical txn shapes from
    the stub trail + a diag boot: CTRL/CMD +0x30 bit6 = START, read
    flag = bit2 (read txns run CMD=0x254 with no staged tx bytes,
    writes 0x50/0x250 with the tx bytes staged at DATA +0x10, bit9 =
    stop-after-last); INT status +0x2c is READ-TO-CLEAR and the
    threaded handler branches on it (bit6 = txn done, bit2 = rx:
    pops *(+0x78) bytes via +0x10, bit9 = done); +0x9c bit0 = busy
    (the enable path spins until it reads 0). The hyn probe's
    chip-id reads (reg 0xaa) and the fw-update register accesses must
    keep failing with the driver's own timeouts or the boot window
    changes (the v0.76 run let them complete once and insmod oopsed
    in hyn_ctpm_fw_upgrade_with_i_file on a null ops pointer).
- **Models added** (hw/mips/x1600.c, +550 lines):
  - Pinctrl/GPIO 0x10010000 replaces the plain stub. Per bank of
    0x100 (gpa/gpb/gpc/gpd chained to INTC 17/16/15/14 per the stock
    DTB): IRQ enable +0x14/+0x18, mask +0x24/+0x28, PAT0 drive
    +0x44/+0x48 (drive low/high), INTP pending +0x50 (read) /
    +0x58 (W1C, the genirq irq_ack), PIN level +0x00 (read). The
    +0x700..+0x7ef staging window commits to the bank written to
    +0x7f0 (the hyn PA16 registration trail: 0x714/0x728/0x734/0x748
    = bit16, 0x7f0 = 0, then direct +0x78/+0x58/+0x28). Register
    semantics decoded from the built-in driver (tingenic_gpio_*,
    0x8040f440-0x80411da8 in vmlinux) and cross-checked against the
    run8 unimp trail. The level word is model-driven ONLY: the
    baseline guest read 0 at +0x00 for every bank (the msc
    card-detect print "card inserted, state=0" depends on it), and
    the gpio GET path never touched the stub in the recorded boots.
  - I2C1 0x10051000 replaces its stub with the controller semantics
    above plus the cst8xx slave: register 0x00 = the 9-byte touch
    frame {0,0,count,x_hi,x_lo,y_hi,y_lo,0,0}; every other register
    access stays incomplete so the driver's 1 s completion timeout
    reproduces the dead-stub baseline exactly (messages AND oops
    avoidance). While touched the model re-asserts the PA16 INT every
    40 ms (alternating edge) like the real panel's report rate.
  - SADC: per-channel commanded 12-bit samples (idle 0xfff).
  - An unbound QemuInputHandler (KEY|BTN|ABS) consumes the VNC
    keyboard/mouse; unbound = it matches every console, which is what
    we want (the machine's only console is the LCD graphic console
    the VNC server attaches to). ABS 0..0x7fff scales onto 480x800;
    left button = touch down/up.
- **VNC key mapping** (documented in x1600.c; the codes the guest
  firmware actually consumes):
  | VNC key | linux code | guest path | guest EV_KEY |
  |---|---|---|---|
  | Up | 103 | SADC ch0 = 1650 mV | 115 KEY_VOLUMEUP |
  | Down | 108 | SADC ch0 = 1000 mV | 114 KEY_VOLUMEDOWN |
  | Enter | 28 | SADC ch0 = 0 mV | 164 KEY_PLAYPAUSE |
  | Right | 106 | GPIO PC28 (active high) | 163 KEY_NEXTSONG |
  | Esc | 1 | GPIO PC31 (active low) | 116 KEY_POWER |
  | Left | 105 | unmapped | 165 has no source |
- **Verification evidence** (this round's VM, VNC 127.0.0.1:1, HMP
  monitor + QMP sockets in /tmp/kilo/input/):
  - (a) evdev injection: HMP `sendkey down 600` while
    `cat /dev/input/event2 | od -An -tx2` runs on the console shell:
    event2 (jz adc keyboard) received
    `EV_KEY(0x0001) code=0x0072(114 KEY_VOLUMEDOWN) value=1` +
    `EV_SYN`. HMP `sendkey right 600` on event0 (md-gpio-keys):
    `EV_KEY code=0x00a3(163 KEY_NEXTSONG) value=1` + EV_SYN. The
    full VNC -> QEMU handler -> SADC-ladder/GPIO-INTC -> guest
    driver -> evdev chain works.
  - (b) touch: QMP input-send-event (abs move + left button) at the
    language picker: /proc/interrupts `100: N GPIO 16 hyn_ts`
    counts the injected INTs (up to 246 dispatches during a held
    touch); the model's i2c1 trail shows the driver's write {0x00} +
    read 0x254 pairs reading the touch frame; `cat
    /dev/input/event1` during a held touch shows the driver's MT-A
    report stream (`EV_SYN code=2 SYN_MT_REPORT` + `EV_SYN
    SYN_REPORT`). The litegui UI reacts to the touch stream (the
    language list scroll/overscroll state changes, screendumps in
    /tmp/kilo/input/). tap->select calibration (the litegui gesture
    thresholds on top of the MT-A stream) is the one remaining step
    and is parked below.
  - (c) boot gate: tools/x1600-boot-test.sh PASS on the stripped
    build (297 distinct messages, 158 structural lines, identical to
    docs/traces/boot-baseline-v0.75.txt; no re-record needed).
- **Two walls found (decoded, not guessed):**
  1. The fb-blank notifier disables the touch: fb_notifier_callback
     calls disable_irq_nosync(100) when the panel blanks (the GUI
     idle does this within ~seconds of the picker appearing) and
     hyn_resume_work re-enables it on the fb unblank. The panel
     powers down but the framebuffer keeps the picker, so the VNC
     feed looks alive while the touch INT is swallowed (the
     handle_edge_irq disabled path acks INTP via +0x58 and latches
     the event as genirq pending-replay instead of running the
     action). User-visible workaround on the emulated device, same
     as on the hardware: power-key toggle (VNC Esc) -> the resume
     work -> enable_irq -> the touch chain works again.
  2. The hyn driver registers the touch IRQ with IRQF_ONESHOT and no
     thread handler (no irq/100-hyn_ts kthread exists on the running
     system), so the genirq ONESHOT mask is never finalized after
     the first dispatched edge: exactly one INT dispatch per
     enable_irq cycle reaches the driver. The 40 ms INT re-assertion
     still gets the driver reading the held-touch frame continuously
     once the resume path has re-enabled the line (246 dispatches /
     123 frame reads observed in one hold), and the events flow,
     but a one-shot tap only ever delivers its first (eventless)
     frame. True tap->select needs either the litegui gesture
     calibration against the delivered stream or a kernel-side
     decode of the vendor ONESHOT handling; parked for the next
     round with all the decoded addresses in this entry.
- **Trap for the next session:** the guest's effective IRQ dispatch
  mask (the chained handler reads *(+0x20)) is always 0 in this
  model, while the guest's own +0x24/+0x28 bookkeeping (pinconf
  func-config and genirq masking) accumulates an unrelated mask
  word (observed 0xc1020303 for bank A). x1600_gpio_inject gates on
  the enable (+0x14/+0x18) only, NOT on that bookkeeping word, and
  that is deliberate.
- **Gate:** tools/x1600-boot-test.sh PASS (297 distinct messages,
  158 structural lines vs docs/traces/boot-baseline-v0.75.txt). The
  input models touch no pre-gate flow except the SADC sample word
  and the i2c1 completion IRQs, both of which produce no boot-window
  messages.

## v0.77 (2026-10-14, M3 round, worktree qemu-touch-cal) - the litegui
gesture decode + the cst8xx calibration: the tap->select round.

- **litegui touch decode** (hiby_player 4.6M stripped, musl objdump; the
  litegui sources are compiled into the player, no separate .so):
  - The touch source: `lg_event_x1000`/"hgl_ts" layer (strings
    "(hgl_ts: E) event0 init fail", "(hgl_ts: I) ts is ready"). The
    fd setup (0x472560) scans /dev/input/event*, EVIOCGBIT(0) per node
    and keeps the FIRST device with EV_ABS (event1, the cst8xx), then
    0x472b60 pairs it with a timerfd at ~32 ms and the poller 0x4728a0
    polls {ts_fd, timerfd}. There is also a generic "lg_event_source"
    scanner (0x466920, handler 0x467160) but it is the KEY path
    (code 105/106 -> 0x44cc00); the touch path is hgl_ts.
  - **The coordinate mapping is the load-bearing fact** (event
    processor 0x472988 + the emitters at 0x472aec/0x472b10): the
    handler accumulates ABS_MT_POSITION_X (code 53, also ABS_X 0) into
    a global and ABS_MT_POSITION_Y (54/1) into another, and emits its
    events as
        screen_x = 480 - raw_x;  screen_y = 800 - raw_y
    — a fixed INVERSION, no scaling, no axis swap. It never reads the
    driver's abs_params (no EVIOCGABS anywhere in the path), so the
    driver's advertised 0..720 x 0..1280 native frame (decoded below)
    is dead config as far as litegui is concerned: the real panel's
    firmware must report a 480x800 frame rotated 180 deg vs the LCD.
  - Event shapes (struct {type, elapsed_ms, x, y} at event+0/4/8/12):
    - type 2 = MOVE: emitted on EV_SYN (SYN_REPORT **or
      SYN_MT_REPORT**) when the coord-count global > 0, position =
      (480-x, 800-y), count then reset.
    - type 3 = UP: emitted on EV_KEY BTN_TOUCH **value 0 only**
      (BTN_TOUCH 1 is explicitly ignored), position = (480-lastX,
      800-lastY).
    - type 1 = the timerfd tick (just refreshes the timestamp gate
      0x472780, which returns elapsed-ms-since-last-touch-event and
      rejects >24h stale deltas).
  - There is NO DOWN event: the press is inferred upstream from the
    first MOVE (the list stores event x/y as the press position at
    state+292/296 in the case-4/8 handler at 0x434314).
  - The pump (0x435600, two copies) runs poller -> 0x47c9c0 ->
    0x47caa0 per event. 0x47caa0 is the **monkey-test monitor**: it
    counts in-bounds UP events (region globals 0x8b61e0-0x8b61ec, set
    from the active view rect at 0x4e9188) and after 5 UPs checks
    access("/data/mnt/sd_0/hiby_linux_auto_test") — if present it
    latches 0x8b61f4 and the pump switches to the rand()-driven
    auto-test tap generator (strings "MONKEY",
    "HGL_EV_TOUCH_END time:%02d:%02d:%02d", "Tap\n", "Slip %s\n").
    0x47c9c0 with the latch set processes only UP events >=2 s apart
    and resets the latch (a one-shot). This whole pump gate is the
    auto-test/monkey lane, NOT the UI path — the UI path is the
    activity/list dispatch below (and empirically MOVEs reach the
    picker, v0.76).
  - The list view (hglview) handler: event type switch (jump table at
    0x75c2a0, types 4..10), type 10 -> 0x4335c0(list, event, 6) =
    touch-up; mode 6 logic: |abs(state+324) - abs(state+288)| != 0 ->
    the list scrolled during the press -> scroll settle (0x43389c), no
    tap; else |state+284| < 5 gates the tap path -> item hit-test
    (0x4326e0) -> the select callbacks (state+664/668 vtables). The
    5-px constant is the first decoded gesture threshold.
  - The cst8xx **driver abs_params** (init_module+0x274, config struct
    set at init+0x118): ABS_MT_TRACKING_ID 0..15,
    ABS_MT_POSITION_X 0..720, ABS_MT_POSITION_Y 0..1280,
    ABS_MT_TOUCH_MAJOR 0..255, ABS_MT_PRESSURE 0..255; +88 = 1 in the
    config (unused in the report path). The handler applies NO
    transform: raw frame coords go straight to input_event.
- **cst8xx_touch.ko hyn_irq_handler fully decoded** (relocations pin
  s1/s3 to input_event; the per-record 28-byte layout is
  {x, y, buf[7], buf[3]>>6, buf[5]>>4, buf[8]>>4, counter}):
  - Per INT dispatch: read the 9-byte frame, count = buf[2]&0xf,
    parse records while buf[5] (y_hi) < 32, then per record:
    - if (buf[3]>>6) & ~1 != 0 (event code 2/3 = lift) -> no contact
      report, and the record counter resets to 0 (the reset lives in
      the branch delay slot at 0xa60);
    - else if the record counter == 0 -> the FULL MT-A block:
      ABS_MT_TRACKING_ID (value buf[5]>>4, i.e. 0 for sane y),
      ABS_MT_PRESSURE (buf[7], clamped to 63 when <=0),
      ABS_MT_TOUCH_MAJOR (buf[8]>>4, clamped to 9), POSITION_X,
      POSITION_Y, then SYN_MT_REPORT; counter -> 1;
    - else (counter != 0) -> no ABS data, counter -> 0 (delay-slot
      reset), so full/skip ALTERNATE per dispatch and every press
      dispatch after any skip/lift is a full one;
    - then BTN_TOUCH = (count != 0) and SYN_REPORT (the count==0 path
      adds an extra SYN_MT_REPORT between BTN_TOUCH 0 and SYN_REPORT).
  - Consequence for taps: press dispatch = full record -> litegui
    MOVE at (480-x, 800-y); lift dispatch (byte3 = 0x80|x_hi) =
    BTN_TOUCH 0 only -> litegui UP at the last accumulated position;
    the lift dispatch also leaves the counter at 0 so the NEXT tap's
    press is a full record again.
- **The calibration applied** (vendored qemu hw/mips/x1600.c, the cst8xx
  i2c1 slave + the VNC input path):
  1. **Coordinate inversion**: x1600_i2c_touch_report now reports
     panel = (480 - screen_x, 800 - screen_y) into the touch frame,
     matching litegui's fixed screen = (480 - raw, 800 - raw) mapping.
     The screen latch and the frame coords are separate fields (the
     release event must invert the SAME screen coords the press used;
     storing the inverted press coords back into the latch double-
     inverted the lift frame — caught by the TEMP-TOUCH-DIAG trail).
  2. **Lift frame**: the frame bytes now always carry the last known
     position, and the lift dispatch sets event code 2 in byte3
     bits7:6 (0x80|x_hi) — the hyn handler's (buf[3]>>6)&~1 test
     suppresses the contact record and reports BTN_TOUCH 0 only, so
     litegui's touch-up lands at the press position and the driver's
     per-record counter is left at 0 (the next press dispatch is a
     full contact record again — the counter reset lives in a branch
     delay slot at 0xa60, decoded above).
  3. **Report rate**: the INT re-assertion while touched moved from
     40 ms to 20 ms (~50 Hz, the real panel's 40-60 Hz band). The
     press INT fires immediately on the VNC button edge, so a tap
     delivers: press dispatch = full MT-A record (litegui MOVE at the
     press position) -> 20 ms ticks while held -> lift dispatch =
     BTN_TOUCH 0 (litegui touch-up at the same position).
  4. **The suspended-panel wake check**: the fb-blank wall (v0.76
     wall 1) silences the touch for the REST of the boot, because
     hyn_resume_work (the fb-unblank resume) gates enable_irq behind
     a wake check: hyn_read(reg 0xaa) retried 5x vs the config byte
     at ts+40, which the module never writes (bss 0 -> expects 0x00).
     The model now arms a wake-check path when the driver writes the
     sleep command (reg 0xa5 — the "set TP to sleep mode fail" write,
     which stays incomplete exactly as recorded) and answers the
     armed reg-0xaa read with one 0x00 byte, so the resume completes
     and re-enables the touch INT. Every other register access still
     stalls like the baseline (the boot window is untouched).
- **Verification** (the demo VM pattern, VNC 127.0.0.1:0, QMP
  input-send-event; screendumps in /tmp/kilo/touch/):
  - The tap->select chain WORKS: QMP abs-move + left press at the
    English row's coordinates (240, 398; the picker rows render at
    y = 129/256/384/508/635/762 = 简体中文/繁體中文/English/日本語/
    한국어/Français — identified by glyph-run width against the 13
    names in usr/resource/str/*/language.ini), 140 ms hold, release.
  - The model-side trail (TEMP-TOUCH-DIAG, since stripped): press ->
    8 held-frame reads (count=1, x/y at the inverted panel coords) ->
    ONE lift frame (count=0, b3=0x80) — exactly the decoded driver
    contract.
  - **The selection registers**: on the true first boot the picker
    (titled "Select Language" per the persisted English config)
    transitions on the tap and the wizard advances; the next screen
    renders its strings in ENGLISH (latin letterforms at full
    resolution), i.e. the tapped row's language took effect. On a
    later boot (the language already persisted as English by the
    first run) the same tap re-renders the language screen with the
    English item labels ("Simplified ...") and the settings title —
    the selection again visible in the screendump. Evidence:
    /tmp/kilo/touch/gate_before.ppm|png (the picker) and
    gate_after.ppm|png (after the tap), plus the earlier
    w_b/w_a pair (the first-boot advance).
  - **Drag/scroll**: the press and the move stream reach the list
    (the move events trigger the list's scroll invalidation — a
    solid black invalidated band appears at the screen bottom while
    the gesture is active) and a horizontal drag is correctly ignored
    (no invalidation at all — the vertical axis is the scroll axis),
    but the language list does not FOLLOW the finger in any of the
    drag shapes tried (slow dwell-then-move, continuous no-dwell,
    fast fling; a fast fling and a top-row tap both drop the list
    into a re-rendered state with per-row radio/box marks — the
    pull-down/overscroll zone at the list top is the likely
    trigger). The scroll-follow calibration is parked as the next
    touch item; the tap->select gate does not depend on it.
  - The VNC key events must use the QMP string enums ("x"/"y"/"left");
    integer enum values are accepted by input-send-event but silently
    never reach the input handler (found while wiring the tap).

## v0.78 (2026-10-14, M3 round, worktree qemu-fb-wake) - the fb-blank
wake: making the idle-blanked picker interactive again. Worktree setup
per convention (vendors + unpacked copied, demo VM rebooted onto the
worktree build; the pre-reboot demo console confirmed the v0.76/v0.77
blocked state live: at t=108 s "i2c1 write timeout(136 ms)" +
"[HYN_TS/E]hyn_ts_suspend:set TP to sleep mode fail, ret=-145" with the
picker still rendered).

- **fb_notifier_callback fully decoded** (cst8xx_touch.ko .text+0x264,
  relocations resolved): it registers via fb_register_client and only
  acts on FB_EVENT_BLANK (action==9), reading the blank mode from
  *(fb_event->data):
  - blank==0 (FB_BLANK_UNBLANK) -> `queue_work_on(1, *(hyn_data+56),
    hyn_data+180)`: the resume work (hyn_resume_work) is queued on the
    driver's own workqueue. That is the ONLY wake trigger — there is no
    direct enable_irq path outside the work.
  - blank==4 (FB_BLANK_POWERDOWN) -> the hyn_ts_suspend body INLINED:
    if ts+256/ts+257 flags already set, a printk pair; else
    disable_irq_nosync(*(hyn_data+244)) (the PA16/virq-100 touch IRQ),
    ts+258=1 (suspended flag), mutex_lock(ts+232),
    hi_i2c_write(0xa5,1,3,1) (the TP sleep command), mutex_unlock, and
    on ret<0 `printk($LC2, .rodata+0xc8 = "hyn_ts_suspend", ret)` — the
    recorded "[HYN_TS/E]hyn_ts_suspend:set TP to sleep mode fail"
    print lives HERE, in the fb notifier, not in a separate suspend
    entry point. Then if ts+24==0, `hyn_power_source_ctrl.part.3(ts)`
    (.text+0x1d0) runs and ts+256=1 is stored (blanked latch).
- Round continues; entries appended as decode/verify progresses.
- **hyn_resume_work fully decoded** (cst8xx_touch.ko .text+0xaa8): runs
  only when the ts+256 blanked latch is set; releases the stuck touch
  (input_event BTN_TOUCH 0 + SYN_REPORT), zeroes the ts+280/284 frame
  counters, calls hyn_power_source_ctrl.constprop.13, then the wake
  check: hyn_read(reg 0xaa, 1 byte) up to 5x with 200 ms sleeps vs the
  probe-time config byte at ts+40. **The check is SOFT**: on read
  failure OR mismatch it falls through to the enable path after the
  5 retries (`b bdc`), and the enable path runs enable_irq(ts+244),
  clears ts+258, then clears ts+256. So the touch IRQ re-enable is
  unconditional ~1 s after the unblank event.
- **The wake check's ts+40 comparison decoded from init_module**: the
  probe reads 0xaa/0xa6/0xa8 (hyn_read.constprop.14); ALL THREE must
  succeed to write ts+40/41/48; after 5 failed rounds the fallback
  writes ts+40=0xff, ts+41=0, ts+48=0xff (NOT bss-0 as v0.77 assumed).
  The v0.77 model answers the 0xaa read with 0x00 — with ts+40=0xff
  the compare mismatches every round, but the soft fall-through still
  re-enables the IRQ. (Verified live: after `echo 0 >
  /sys/class/graphics/fb0/blank`, a QMP tap increments
  /proc/interrupts hyn_ts 0 -> 9.)
- **The GUI never issues the unblank**: hiby_player disassembly has NO
  FBIOBLANK constant (MIPS _IO('F',0xb) = 0x460b = 17931 — grep'd the
  whole 846k-line disassembly). The player's blank path (obfuscated
  region) prints "(hgl_fb: W) failed to access ioctl FB_BLANK_UNBLANK"
  on failure, so a blank ioctl wrapper exists, but at the idle blank
  the player (LD_PRELOAD shim trail) only does
  `open+write /sys/class/backlight/backlight_pwm0/brightness '0'` —
  no FB-range ioctl, no fb0/blank sysfs write.
- **fb_blank(4)'s kernel callers decoded** (vmlinux.bin jal-scan +
  /proc/kallsyms): exactly two — do_fb_ioctl (the FBIOBLANK ioctl
  case) and store_blank (the /sys/class/graphics/fb0/blank sysfs
  store). Both userspace-triggered; no fbcon in the kernel (no
  fbcon_* symbols), so the VT blank path cannot reach the fb.
- **The stock idle blank (boots 1-2) DID run fb_blank(4)** (the hyn
  suspend prints fired with no shell interaction), but a shimmed
  player's idle blank (boot 3) wrote ONLY the backlight '0' and NO
  fb_blank followed — so the fb_blank issuer is a DIFFERENT process:
  /usr/bin/sys_server (the system daemon; the player's sys_cmd layer
  talks to it). Verified /proc fds: the player holds event0-3 open
  (all four evdev nodes, event1 twice) yet key events do not wake;
  sys_server restarted under the shim showed no input fds and NO idle
  blank fired while it was shimmed (the restart broke its state).
- **The GUI's input policy decoded** (hiby_player, the lg_event_source
  scanner at 0x466920 + the EVIOCGNAME classifier): the key layer only
  LISTENS to devices named "md-gpio-keys"/"gpio-keys"/"sa-ring-keys"
  ("Skip listen Device Name" for everything else) — the "jz adc
  keyboard" (event2, the SADC keys) and "earpods_adc" (event3) are
  skipped by name, so only POWER/NEXTSONG (event0) reach the GUI. The
  md-gpio-keys handler (0x4661a0) maintains a pressed-keys bitmap
  (table at 0x764e60: 164->0x20, 163->0x10, 165->0x1, 139->0x2,
  114->0x800, 115->0x2000, 116(POWER)->0x1000, 200->0x4000); the
  litegui event dispatcher (0x4ed1xx) maps codes 4096 (POWER)/8192
  (VOLUP)/16384 (code 200) through the wake path: 0x4ecf80 (can-handle
  = setting(6)==0 && screen-flag 0x8b47a4==0), then on screen-off
  0x4ed354 -> 0x4ec720 (the wake: 0x414820 gates on setting(93)!=0 &&
  app-state in {3,4,5}, then the obfuscated string/dialog path).
  **Empirically POWER (100 ms and 3 s holds), Enter/Down/Up/Right and
  a QMP tap on the blanked picker do NOT wake it** (brightness stays
  0, hyn_ts IRQ stays 0, no fb activity), and the key events DO reach
  evdev (verified with /dev/input/event0/event2 captures: EV_KEY
  code=0x74 KEY_POWER press+release in the log). The static gates
  (settings 6/93, app state) are runtime-obfuscated; /proc/pid/mem
  reads fail in the guest so they cannot be probed live.
- **The stock idle blank runs fb_blank(4)** (hyn suspend prints at
  54-108 s in every unshimmed boot); a shimmed player's blank showed
  backlight-only (the FBIOBLANK likely bypassed the shim's filter —
  the MIPS dir bits — or the console listener lost it at a reconnect).
- **Guest hazard found**: killing hiby_player while the
  hiby_player.sh wrapper is alive reboots/powers-off the device (the
  wrapper runs `reboot` after the player exits; with -no-reboot the
  VM halts). Swap the player by killing the wrapper FIRST, then the
  player, then launching the replacement within a second.
- **The idle flow decoded end-to-end (live, stock player)**: the GUI's
  power-save policy on the emulated device runs
  idle (~25-30 s) -> `write /sys/class/backlight/backlight_pwm0/
  brightness 0` (the "blank") -> ~5 min idle -> the power-save
  SHUTDOWN (the player exits; hiby_player.sh runs `reboot` -> the
  device powers off — observed twice: t=425 s and t=736 s). While
  blanked the GUI IGNORES ALL INPUT (keys and touch — the litegui
  layer gates processing on the screen state), so the picker is
  un-interactable until the wake fires or the 5-minute shutdown
  reboots the device.
- **The blank's fb_blank(4) step is VARIANT**: boots 1/2/5/6 (the
  pristine volume state) ran fb_blank(4) at the blank (the hyn
  suspend prints; the touch IRQ disabled); boots 7/8/10 (after a
  full shutdown cycle rewrote the /usr/data state) blanked with the
  backlight write ONLY — no fb_blank, the touch IRQ stayed enabled
  and the touch chain stayed ALIVE (a QMP tap counted 9 hyn_ts
  IRQs and the tap->select worked). The variant's trigger lives in
  the persisted player settings (eq.ini/momery_list.lst territory);
  parked.
- **The wake trigger decode (parked at the obfuscated gates)**: the
  litegui event dispatcher (0x4ed1xx) maps the md-gpio-keys bitmap
  masks to events 4096 (KEY_POWER 116)/8192 (KEY_VOLUMEUP 115)/16384
  (code 200) through the wake path 0x4ed3d0 -> 0x4ed354 -> 0x4ec720,
  which gates on setting(6) (0x4ecf80), setting(93) (0x414820), the
  app-state value in {3,4,5} (0x467640 over the 65-entry state table
  at 0x7646900), and the screen flag 0x8b47a4; then posts the
  "backlight on" message (0x433de0 with the runtime-decoded
  obfuscated string; the "Discard backlight on/off message" strings
  are the receiver's). Empirically POWER (100 ms/2 s/3 s holds),
  Enter, Down, Up, Right and a QMP tap NEVER woke the blanked picker
  (brightness stayed 0, no fb activity, no lg_message_thread prints)
  — the gates fail at the picker's wizard state. The settings are
  runtime-obfuscated; /proc/pid/mem and pagemap are unavailable in
  the guest, so they cannot be probed live. Parked: the remaining
  work is a userspace settings decode, not a model item.
- **The model-side wake chain VERIFIED WORKING (this round's core
  evidence)**: `echo 0 > /sys/class/graphics/fb0/blank` (the
  kernel's fb_blank(0) — the exact call the GUI's wake would make)
  -> fb_notifier_callback blank==0 -> queue_work_on ->
  hyn_resume_work -> the wake-check reg 0xaa read (the model answers
  one 0x00 byte per the v0.77 arming) -> the compare vs ts+40=0xff
  mismatches 5x (200 ms each) -> the SOFT fall-through (`b bdc`)
  -> enable_irq(ts+244) + ts+258/256 cleared. A QMP tap then counted
  /proc/interrupts hyn_ts 0 -> 9 (the press INT + the 20 ms held
  ticks + the lift) and the driver dispatched the frames. The
  fb_blank(4) -> disable_irq path was verified dead-side: taps
  counted NOTHING while blanked in the fb_blank(4) boots (the
  genirq disabled-path latch; the pending replays on re-enable).
  **No model change is required: the v0.77 cst8xx/LCD/GPIO models
  already serve the entire blank/wake contract faithfully** (the
  suspend write stall reproduces the recorded "i2c1 write
  timeout(136 ms)"/"set TP to sleep mode fail, ret=-145" prints and
  arms the wake check; the resume re-enables the INT; the LCD
  stop-done (+0x2000=0x10) un-stalls the blank path).
- **Verification (this round)**:
  - (a) diag: the blank -> the touch IRQ frozen at 0 (the
    fb_blank(4) boots); `fb0/blank=0` -> the resume -> a tap counts
    9 IRQs. `fb0/blank=4` while suspended prints "[HYN_TS/I]
    hyn_ts_suspend:Already in suspend state" (the $LC0 early return).
  - (b/c) the FULL user flow on the post-shutdown boots (the touch
    alive): QMP tap at the English row (240, 398 — the v0.77
    calibration) on the picker -> the wizard ADVANCED (the screen
    md5 changed; /tmp/kilo/wake/sel_before.png vs sel_after.png —
    the bottom third goes dark as the next screen renders; the
    settled dump matches). The language selection persisted state
    is now in the worktree volume.
  - (d) tools/x1600-boot-test.sh PASS (297 distinct messages, 158
    structural lines vs docs/traces/boot-baseline-v0.75.txt; the
    nand image rebuilt first per the v0.75 lesson, md5 ae41e974...).
- **Operational hazards recorded**: killing hiby_player with the
  hiby_player.sh wrapper alive reboots the device; killing it with
  the wrapper dead leaves the player dead and the device resets
  within ~20 s (a watchdog/PM path) — player swaps must be atomic
  single-command-line kills+launches. The 5-minute idle shutdown
  will reboot the demo VM by itself when nobody interacts.

## v0.79 (2026-10-15, M3 round, worktree qemu-listview-plane) - the
"not listview plane then listview refresh fail" decode: it is a BENIGN
ordering artifact, not the freeze; the picker wall is the v0.78
idle-blank wake (entries appended as decode/verify progresses).

- **Symptom re-confirmed on the merged v0.78 build** (fresh nand image
  ae41e974..., /tmp/kilo/ui2/): boot -> rcS -> player -> the exact
  recorded signature at t=56 s (GUI:E level, not (GUI:D) as recorded):
  `(GUI:E)lg_listview_create: not listview plane then listview refresh
  fail` right after `lg_activity_mng: running activity
  lg_activity_main`, then event_input, bluez abort loop, and at t=86 s
  `i2c1 write timeout(136 ms)` + `hyn_ts_suspend ... ret=-145` and
  console silence (the v0.78 idle blank; the t=119 s in the task notes
  is the same idle-blank moment with timer variance 54-119 s).
- **The Hiby player binary (4.6M stripped, musl) decode** — the print's
  three emission sites all reduce to ONE check. The debug print helper
  is 0x465fa0(tag, msg); tag "lg_listview_create" = 0x77bec0, msg
  "not listview plane then listview refresh fail" = 0x77bed4 (file
  offsets 0x37bec0/0x37bed4, vaddr = file + 0x400000):
  - The lookup primitive 0x4f13a0(reg, name, &out): takes the object's
    registry list (circular list head at reg+700, sentinel = &reg->700;
    lock/unlock virtual methods at vtable+712/+716), walks nodes, and
    strcmp's *(node+8) against `name`; *out = the matched name pointer,
    NULL when absent. For widget lookups the registry nodes are the
    registered child widgets themselves (node+8 = the widget pointer;
    strcmp(p, p) == 0 makes the match a pointer-identity search).
  - Site 1 (0x495400, called from the listview create/refresh flow
    0x49e200 at 0x49e468 and from 0x51c1a0): lookup(widget->parent /
    layout tree at +216, widget) -> if the widget is NOT yet registered
    under its plane/parent, out == NULL -> the print. The success path
    then builds "canvas_%s" (0x77bf04) from *(widget->208) and resolves
    the widget's canvas through 0x47bc20 — i.e. the check is literally
    "is the listview on a plane yet" ("not listview plane"), and the
    refresh bails when the widget has not been attached. The item
    refresh sites 2/3 (0x4957e0 called at 0x4959f4-fail and 0x499840 at
    0x499878-fail) test the same registration with per-item names
    ("vg_item_%d" 0x77bd78, "%s##%d" 0x77beb8, e.g. the literal
    "vg_listview_tidal_item##3" strings).
  - The registry object is the parsed litegui layout: its constructor
    0x4f0bd0 sprintfs the path "z:\layout\%stheme%d\main.json"
    (0x786f60) and registers the file node via 0x432300; the tree lives
    in /usr/resource/layout/theme1/main.json on the rootfs (present;
    theme1 selected via the mtd5 ota "theme:1" record).
- **WHY IT IS NOT THE FREEZE — the kill shot (prior-round evidence)**:
  the v0.78 worktree console (/tmp/kilo/wake/console.txt) contains this
  EXACT print TEN times — once per player GUI start across that round's
  kill/swap/restart cycles — and those are the boots where the tap->
  select chain was VERIFIED working (v0.78 items (b/c), /tmp/kilo/wake/
  sel_before.png vs sel_after.png). The v0.75 first-picker-render runs
  (/tmp/kilo/ui/run8/serial.log) contain it too. The print is the
  listview's own create-time refresh running BEFORE the widget is
  attached to its plane; the picker renders and processes taps anyway.
- **Live confirmation of the real wall on this build** (the fresh-boot
  run): screendump at t≈60 s shows the picker fully rendered (title
  band y=34-49 + the six rows at y=131/256/390/513/635/768 — the
  v0.77 row grid); a QMP tap at the English row (240,398) at t≈87 s —
  after the 86 s blank — is ignored (screendump identical, zero console
  reaction) because the idle blank already ran fb_blank(4) and the
  cst8xx IRQ is disabled (v0.78's decoded wall), while the v0.77/0.78
  rounds' successful taps all happened BEFORE the blank (the picker is
  interactive from render until the ~25-30 s idle timer fires).
- **Working decode thesis for the fix**: the VM is faithful; the
  user-facing freeze = idle-blank + no wake at the wizard state (the
  v0.78 gates). Remaining work this round: verify tap-before-blank
  advances the wizard on this build, decode the fb_blank(4)-variant
  trigger in sys_server (boots after a full shutdown cycle blank with
  the backlight write only and stay interactive), and decide the
  model-level lever. TEMP-UI2-DIAG instrumentation (if any) is in
  /tmp/kilo/ui2/ only; nothing to strip from the tree yet.
- **Guest-side strace (the rootfs ships /usr/bin/strace) of the tap
  path, player swapped under strace via the console shell** (the strace
  also settles the v0.78 shim-vs-strace ambiguity about the player's
  own blank): the strace'd player's idle blank writes ONLY the
  backlight sysfs — NO FB-range ioctl appears anywhere in its trace
  (FBIOBLANK is sys_server's, as v0.78 concluded from the shim). The
  input plumbing is PROVEN correct end-to-end on this build:
  - the GUI's touch poller (the main thread 1143) polls
    {fd4=/dev/input/event1, fd3=timerfd} every 33 ms exactly as the
    v0.77 decode predicted, and fd4 DOES return POLLIN and 16-byte
    evdev reads on every tap: the full MT-A stream
    (ABS_MT_TRACKING_ID=0, PRESSURE=63, TOUCH_MAJOR=9,
    POSITION_X=240 (0xf0), POSITION_Y=403 (0x193), SYN_MT_REPORT,
    SYN_REPORT) — the model's inversion + the QMP recipe land the tap
    at the right panel coords (the v0.77 recipe's "(240,398)" is a
    SCREEN position: QMP abs values are VNC-normalized 0..0x7fff, so
    16384/16282 = screen (240,398); sending raw 240 scales to
    240*480>>15 = 3 and misses — caught and fixed this round).
  - a second reader (thread 1166, the lg_event_source key scanner)
    polls {event3,2,1,0} = fds 18-21 with a 25 ms timeout and ALSO
    receives the touch frames on fd20 (evdev is per-client; nobody
    starves anybody; no EVIOCGRAB anywhere in the trace).
  - the player creates the "com_input" uinput device at startup
    (UI_SET_EVBIT/UI_SET_KEYBIT 0x74 0xa4 0xa3 0xa5 0x73 0x72,
    UI_DEV_CREATE — the input5/6/7/8 re-registrations seen at every
    player start).
  - after the reads: NO fb ioctl and NO redraw — screendumps byte-
    identical before/after the tap. The events are consumed and then
    DISCARDED inside litegui, before the widget/draw layer.
- **The discard point (now pinned precisely)**: the GUI's blanked state.
  v0.78's "the litegui layer gates processing on the screen state" is
  real and it sits in the event DISPATCH (the wake/dispatch path
  0x4ed1xx: can-handle 0x4ecf80 = setting(6)==0 && screen-flag
  0x8b47a4==0; the wake itself 0x414820 = setting(93)!=0 && app-state
  in {3,4,5}). At the first-boot wizard the wake gates fail (my live
  retest: POWER via QMP Esc = the PC31 gpio-keys, 100 ms hold, on the
  blanked picker — brightness stays 0, no reaction), so blanked =
  bricked for ALL input until the ~5-min power-save shutdown reboots
  (the stock firmware's own escape; v0.78's post-shutdown boots took
  the no-fb_blank variant and were interactive).
- **The v0.78 "post-shutdown interactive variant" did NOT reproduce on
  a single-cycle userdata** (my boot 2, userdata formatted once by
  boot 1: blanked WITH fb_blank(4) at t=58 s, same as pristine boots).
  The variant trigger needs more cycles than one (v0.78's interactive
  boots were 7/8/10). The wake-gate settings decode stays parked as a
  userspace item (user.ini is a binary fixed-width record blob, not
  text).
- **New operational hazard (cost: three wasted player swaps)**: kill -9
  of hiby_player while its GUI is actively blitting leaks the hgl DMA
  pool in rmem_manager for the REST OF THE BOOT — every later player
  start fails "sahd_open: malloc hgl memory error" (the GUI never
  starts); rmmod/insmod of sa_hgl_dma does NOT recover it (the pool
  lives in rmem_manager, shared with soc_fb — unloading rmem would
  take the display down). Recovery = full guest reboot. Player swaps
  are safe only when the GUI is idle (no pending blits), and even then
  prefer letting the guest reboot.
- **Round verification (v0.79 close-out)**:
  - (a) freeze signature: the listview print is stock-firmware behavior
    (present in every boot incl. all verified-working ones) — it cannot
    and should not disappear without firmware modification; documented
    as benign with the decode + the working-boot proof above.
  - (b) tap->advance: VERIFIED on this build (the corrected QMP recipe,
    pre-blank window): /tmp/kilo/ui2/i_before.png (the 6-row picker) ->
    i_after.png (the bottom third dark, rows re-laid — the next page
    rendering) -> i_settled.png, plus the language-applied GUI re-init
    prints in the console.
  - (c) gate: tools/x1600-boot-test.sh PASS (297 distinct messages, 158
    structural lines vs docs/traces/boot-baseline-v0.75.txt; fresh
    image ae41e974...; NO re-record needed — the model diff is empty,
    dmesg unchanged).
  - (d) feed: the demo VM restarted on this build as hiby-live-demo
    (persistent): -M x1600, VNC 127.0.0.1:0 (=5900, ss-verified), HMP
    unix:/tmp/kilo/livedisp/mon.sock, QMP
    unix:/tmp/kilo/livedisp/qmp.sock, console file
    /tmp/kilo/livedisp/console.log. No -no-reboot: the stock 5-min
    power-save shutdown reboots the VM (the faithful device cycle), so
    the feed self-heals and re-shows the picker each cycle; early
    post-shutdown cycles may take the fb_blank(4) variant (touch dead
    while blanked) until the variant flips (v0.78 boots 7/8/10). The
    picker is interactive ~25-30 s after each (re)boot; the manager's
    tap recipe: QMP input-send-event abs x=16384 y=16282 (= screen
    240,398) + left press, ~140-350 ms hold, release, WITHIN the
    window. Worktree state: vendored qemu UNCHANGED (no 0117 patch —
    nothing to export), docs+tools committed on qemu-listview-plane.

## v0.80 — M3 AIC round 1: the register surface decoded (worktree qemu-aic-audio)

**The AIC audio engine decode.** soc_aic.ko disassembled end-to-end
(21 inline MMIO sites + the aic_write_reg/read_reg/set_bit/get_bit
helpers, base 0xb0079000 → 0x10079000 — NOT the 0x10020000 the task
brief guessed; the stock DTB agrees: /apb/aic@0x10079000, size 0x100,
PDMA reqs TX 0x3e / RX 0x3f, tloop rx 0x3d). The -d unimp boot
(55 s window, 8 accesses) confirmed the load-time sequence is just
aic_hal_init (reg0 bit0 clear; reg4 0x4000 clear, bit8 flip, bit2
clear — final reg4 = 0x100); the full sequence only appears at
playback. The decoded register surface (the module never touches
anything else):

- **+0x00 FR**: bit0 EN (aic_enable/aic_disable, refcounted at
  aic_dev+504); bit3 = the software-reset trigger — the module FLIPS
  it in aic_hal_init_common_setting and waits ≤100 ms for it to
  self-clear, panicking "reset aic failure" (or "Please enable
  external codec" when the codec-power field is 0) on timeout; bit8
  reset/flush flips; bits[20:16] (0x1f0000), bit12, bit6 cleared;
  bit4/bit8/bit1-2 flipped per aic_select_clk (=2 from the insmod
  args) and the dai-fmt fields.
- **+0x04 CR**: per-direction enables + channel config + flush bits —
  the module RMWs 0x4000/0x100/0x2/0x80/0x8000/0x1 around
  start/stop; init_playback/capture_setting write the channel fields
  bits[20:19]/[17:16] (channel-count encoded), bit12, bits 24/28.
- **+0x14 SR**: TFL = TX FIFO level bits[13:8], RFL = RX bits[29:24]
  (6-bit fields = the 64-word FIFO). aic_hal_start_playback/
  stop_playback poll TFL==0 (16x1 ms, prints the benign "failed to
  wait tx fifo empty" and proceeds); the capture-start path polls
  RFL!=0 (10 ms).
- **+0x30**: BCLK divider (ctx->div = the MCLK factor/64: 12/8/4/6 for
  the 768/512/256/384 ×fs families — fs<16001?768 : <24001?512 :
  <32001?256 : 384).
- **+0x34**: the FIFO DATA port — dma_param_init hard-codes
  0x10079034 as the channel slave address for BOTH directions.
- No AIC IRQ is ever requested (the DTB line 0 stays unused);
  completion comes from the PDMA IRQ, underruns from the module's own
  hrtimer.

**The ALSA data path decoded.** The module's aic_dma_pcm_hw_params
allocates a 12 MB snd_pcm_lib_malloc_pages ring, then redirects the
runtime's dma_area to its OWN 16 KB dma_alloc_from_coherent window
(the "coherent window" [X, X+0x4000) printed in every "DMA address
range" warning — the base is a per-boot CMA-ish address). The
descriptor stream targets that window, not the 12 MB ring: period 1
of each session still points at the stale ring head (all zeros at the
first trigger — the app's writei had not reached it), every following
descriptor targets the window, which is where aplay's writei data
lands (byte-verified: the window snapshot at stream teardown equals
the source WAV's first 16 KB exactly).

**The x1600_hiby_r1_sound_card.ko + codec_cs43131.ko decode.** The
sound card is pure ASoC glue (no MMIO): it registers the
platform_device + snd_soc_register_card, and its hw_params op sets
the CPU DAI sysclk (96000→24576000, 48000/96000 family 512×/256×,
44100/88200→22579200, 32000→24576000 via 768×; unmatched rates →
set_sysclk(dai, 2, 0) then set_fmt 0x4001 = I2S|CBS_CFS) and
hw_free disables the clock (dir 3). aic_set_sysclk in soc_aic is an
empty stub, so the sysclk call is a no-op — the rate only reaches the
AIC through the clk_set_rate loop over the module's clock tables
("i2s-tx-mclk/bclk/LR-clk/lr_clk", the CGU tree the kernel registers
from the stock DTB — gate_i2s0t/div_i2s0t/ce_i2s0t/mux_i2s0t exist in
the kernel's clock table). codec_cs43131 probes on bus 3 = the
i2c-gpio bit-bang adapter (PB30 SCL / PB31 SDA, 200 kHz, i2c_gpio_add
insmod args) — the module already loads and the card already maps
("cs43131-hifi <-> ingenic-aic mapping ok" at v0.79), so no codec
model work was needed; the "open codec dev error!" line in the boot
console belongs to the bluetooth_hiby sys-cmd chain, NOT the audio
path (red herring in the PLAN Phase-3 note).

## v0.81 — M3 AIC round 2: the model implemented, playback opens (worktree qemu-aic-audio)

**The AIC model** (vendored qemu commit 020c860, patch 0117):
x1600-aic replaces the 0x10079000 stub — regfile, the bit3 reset
handshake self-clearing (soc_aic's panic path is now unreachable: the
first boot attempt with the naive model panicked there at the first
aplay trigger, 334 s), the 64-word TX/RX FIFOs with TFL/RFL levels in
+0x14, the FIFO data port at +0x34 (word writes append + capture),
and a 1 ms drain tick pacing the serial byte rate from the +0x30
divider family (16000/22050/32000/48000 × S16-stereo bpf 4).

**The PDMA AIC slave channels**: a CTL start whose head descriptor
references 0x10079034 enters the AIC pump — one descriptor = one ALSA
period (2048 B), moved word-by-word through the FIFO port (TX: ring →
FIFO port, capture sink; RX: FIFO port → ring), stalled on FIFO room
and resumed by the drain tick, completed with the per-period pending
IRQ (the driver's handler acks, completes the vchan cookie and
re-arms the next period's DDA itself). The live position registers
(ch+0x00/0x04/0x08) are maintained for the driver's polling. The MSC
and mem-to-mem paths are untouched (the hgl blits still pass).

**Verified (a)+(b)**: card 0: hibysoundcard [hiby-sound-card], device
0: x1600-i2s-pcm cs43131-hifi-0 enumerates in aplay -l; aplay of a
transferred WAV negotiates "Signed 16 bit Little Endian, Rate 16000
Hz, Mono", runs hw_params/prepare ("cs43131_dai_prepare pcm") and
trigger; the PDMA programming + the full AIC register sequence (the
hal_init_common reset handshake, init_playback_setting's +0x30
divider = 0xc → 16000 Hz ✓, the CR 0x80100/0x84100 dance, the
TFL/RFL polls) appear in the -d unimp trace exactly as decoded.

**The streaming defect found and parked (the honest boundary of this
round)**: aplay's writei blocks and dies with -EIO after ~one ring
fill. Root cause chain, all in the STOCK module/kernel pair:
1. soc_aic has NO DMA completion callback (dma_param_submit_cyclic
   zeroes the tx callback slot) — the ALSA core never hears periods
   from the DMA path.
2. The playback period engine is the module's hrtimer
   (aic_if_send_invalid_data=1, 120 ms per the insmod args): it polls
   tjzdma_get_current_trans_addr through dma_device+84.
3. The kernel's ingenic_dma probe loads dma_device+84 with
   device_prep_dma_sg, which returns NULL for the (sgl=NULL, nents=0)
   call soc_aic makes — and the getter's own priv pointer (chan+0xa0)
   is never initialized by tingenic_dma_alloc_chan_resources (it
   stores chan+0x94/0x9c) — so the getter returns 0 before touching
   any MMIO, aic_hrtimer_callback never advances and never calls
   snd_pcm_period_elapsed (the only other callers are the CAPTURE
   kthread and aic_stop_playback).
4. The pointer callback (aic_dma_pcm_pointer = ctx+8 ×8/frame_bits,
   ctx+8 updated only by that hrtimer) freezes; the app's writei
   waits for avail forever → wait timeout → -EIO.

Model-side fixes are impossible there (all kernel-side state); the
"send invalid data" underrun filler likewise aborts in
dma_param_config (KSEG1-flavored buffer addresses fail the window
check). The audio-path model layer is complete and faithful up to
this driver defect; a firmware-fix (kernel or module) is out of scope
by the zero-modification rule. The capture deliverable works around
it exactly where the data lives — see v0.82.

## v0.82 — M3 AIC round 3: the PCM capture deliverable (worktree qemu-aic-audio)

**The deliverable**: /home/matt/kilo-aic/capture.wav — 0.512 s, 16000
Hz mono S16_LE (the rate/format aplay itself negotiated and printed),
peak 46% FS, the streamed PCM the emulated AIC's DMA path pushed
through the FIFO port. Mechanism (env X1600_AIC_CAPTURE=<path>,
default OFF — the boot gate is unaffected): the model snapshots the
16 KB coherent window (the runtime's redirected dma_area, i.e. the
app's PCM stream) once per stream at teardown, and appends the
FIFO-pushed words. The snapshot is byte-exact vs the source WAV's
first 16 KB (16384/16384) — captured via `aplay
/usr/data/chime.wav` driven from the respawn console shell (the WAV
transferred over the console as base64 via `cat >`, md5
666f8c8f5b2d89ac8411c61e140ccb5d verified in-guest before playing).

**The audio content (what the user hears)**: a 6-note pentatonic
arpeggio chime — C5 D5 E5 G5 A5 C6 (523.25 → 1046.5 Hz) with soft
exponential decay and a faint octave partial, ~0.35 s per note. The
captured 0.512 s covers the attack and body of C5, the decay into D5,
E5 and the onset of G5 — a wind-chime-like figure, clean (no
clipping: 46% FS peak). NOTE: this is the test chime driven through
aplay on purpose — the stock first-boot flow plays NO audio (the
theme/boot chime never triggers in the wizard; the console shows no
PCM opens during the boot window), so the "boot chime" itself does
not exist to capture. The capture proves the full path: ALSA open →
soc_aic hw_params → AIC register sequence → PDMA cyclic slave → AIC
FIFO port → the model's drain → the sample stream.

**Round verification**:
- (a) the sound card registers cleanly (aplay -l lists card 0
  hibysoundcard / x1600-i2s-pcm cs43131-hifi-0; no new oopses — the
  only new console lines during playback are the module's own benign
  "failed to wait tx fifo empty" / "DMA address ... illegal" hrtimer
  prints, decoded in v0.80/v0.81).
- (b) the PCM open succeeds (aplay's own hw params print + the
  cs43131_dai_prepare line + the -d unimp trace showing the complete
  register/DMA sequence).
- (c) the capture: /home/matt/kilo-aic/capture.wav (+ capture.pcm raw)
  as above.
- (d) gate: tools/x1600-boot-test.sh PASS (297 distinct messages, 158
  structural lines vs docs/traces/boot-baseline-v0.75.txt; fresh
  image; NO re-record needed — the AIC model's boot-window behavior
  matches the stub's: only the 8 aic_hal_init accesses at module
  load, and the PDMA AIC branches never trigger pre-player).
- Worktree state: vendored qemu committed (020c860) + patch
  0117-x1600-aic-audio-engine.patch exported; the TEMP-AIC-DIAG ring
  head dump stripped pre-commit; docs+tools committed on
  qemu-aic-audio. The interactive recipe for later rounds: console
  telnet 127.0.0.1:4448 + /tmp/kilo/aic/tee.py tee (cmd.txt → the
  guest), WAV in /usr/data/chime.wav persists across reboots (UBIFS),
  aplay drives the whole path; NEVER pkill other qemu processes (the
  panicked -no-reboot VM may hang instead of exiting — stop it
  explicitly; port 4448 conflicts fail the next boot with "could not
  connect serial device").

## v0.83 (2026-10-15, fw-download round, worktree qemu-wifi-fw) — the
wifi firmware-download flow traced to its first live step: the DHD does
NOT download (this build skips it by design when the card "looks alive")
and stops at the ChipClkCSR HT-avail handshake

- **How the flow is reached (run1, /tmp/kilo/fw/run1):** the stock boot
  never opens the interface (only `lo` is in /etc/network/interfaces;
  S43wifi_bcm_init_config only sets the MAC), so the 300 s gate window
  shows the DHD parked OFF (v0.74 state). The console respawn shell
  (telnet 127.0.0.1:4448 + tee.py, cmd.txt) drives it:
  `ifconfig wlan0 up` → dhd_open → wl_android_wifi_on → wlan power on →
  sdio_reset_comm → dhd_bus_devreset(0) →
  [63.656] "firmware path not found" (dhd_update_fw_nv_path: the
  firmware_path module param is empty — cywdhd.sh passes none) →
  "== WLAN ON ==" → dhdsdio_probe_attach (F1 signature OK, ram size
  524288) → dhdsdio_download_firmware → **[63.661] "skip download FW
  and nv"** → dhdsdio_clkctl(CLK_AVAIL) → **[64.659] "dhdsdio_htclk:
  HT Avail timeout (1000000): clkctl 0x90"** → "dhd_bus_init: clock
  state is wrong. state = 1" → return -1 → wl_android_wifi_on failed →
  devreset OFF (the -35 is the already-off guard, harmless).
- **WHY the download is skipped — decoded from cywdhd.ko
  (dhdsdio_download_firmware.isra.13 0x9d5b4):** at 0x9d640 the flow
  reads the module-global `alive` (.bss 0x7308); if `alive ==
  0x15151515` it prints "skip download FW and nv" ($LC333, .rodata.str1.4
  +0x1bb80), sets *(bus->dhd+24) = 1 and returns 0 WITHOUT touching the
  chip. `alive` is written exactly once, in bcmsdh_sdmmc_probe
  (0x88cb8): if CCCR 0x03 (IO Ready) reads **6** at probe time →
  alive = 0x15151515 and card_dev = the fn2 device id. That is the same
  ready == 6 arm that patch 0113 makes fire (the fn2-IOR-sticky mirror)
  and that the warm-table ai_scan REQUIRES (ai_scan 0x212b8: warm path
  needs alive == 0x15151515 AND card_dev == 0xa9a6/0xa804).
- **The cold EROM walk is fatally broken in this build (re-verified,
  closes the v0.72 open question):** ai_scan's per-core port loop calls
  get_asd.isra.1(sih, &eromptr, req=a2=1, qual=a3=1) (0x216d8-0x216dc),
  and get_asd.isra.1 (0x21154) matches only when (ent & 0xc0) == qual —
  bits[7:6] can never equal 1 — so every port probe returns 0, the
  caller then fails `(0 & 0xe) == t1(=2)` at 0x216f8 and jumps to
  0x21a90 (numcores = 0). No EROM image can attach this DHD cold; the
  warm-table path (alive armed) is the only working one. The master-
  wrapper scan (get_asd(0,0x40) loop, 0x21750-0x21790) sets s6 = 1 in
  its own DELAY SLOT (0x21794) on every match, and 0x21a78 (bnez s6)
  skips the numcores++ for every wrapper-matched core — even a
  qualifier-correct walk would count zero cores; the core-id ∈
  {0x367,0x50b,0x827,0x840} exemption (0x21640-0x216a8) never covers
  the six 43430 cores, and the SDIO core (cib 0x080201: nmasters +
  naddr == 0) is skipped outright at 0x21638/0x216a8.
- **Consequence (the real semantics of `alive`):** "the card is alive =
  firmware already running" — this driver build NEVER downloads
  fw_bcm43438a1.bin through dhdsdio_download_firmware on this product;
  the chip-side work is to play the RUNNING-firmware role the DHD
  expects (the download code path exists but is unreachable here).
  dhd_update_fw_nv_path would otherwise fall back to
  /lib/firmware/wifi_bcm/cyw43438-7.46.58.35.bin + nvram_azw372.txt
  ($LC48/$LC50, gated on the cis_device/cis_chipvendor globals — never
  set on this boot), but that path is equally unreachable (the alive
  check at 0x9d650 precedes the path handling at 0x9d690).
- **The first live failure is the ChipClkCSR HT handshake:**
  dhd_bus_init (0x9e160) calls dhdsdio_clkctl(bus, CLK_AVAIL, FALSE)
  (0x9e210) → dhdsdio_htclk writes SBSDIO_FUNC1_CHIPCLKCSR = 0x10
  (HT_AVAIL_REQ) and polls for SBSDIO_CLKAV = ALP_AVAIL (0x40) AND
  HT_AVAIL (0x80) both set; the model mirrors only HT_AVAIL (0x80) for
  the 0x10 request (the ALP rules key on 0x08/0x20), so the read-back
  is 0x90 and the 1 s poll times out → bus->clkstate stays 1
  (CLK_SDIO) → "clock state is wrong. state = 1" → dhd_bus_init
  returns -1. The real chip keeps ALP available while supplying HT, so
  the read-back must be 0x10 | 0x40 | 0x80 = 0xd0.
- **What follows once the handshake passes (dhd_bus_init decode,
  0x9e300-0x9e9c8):** 3× retry of bcmsdh_reg_write(0x18000048, 4,
  0x40000) while regfail; **bcmsdh_cfg_write(fn0, CCCR 0x02, 0x06)**
  (IO Enable both functions, 0x9e3dc) then a 3 s dhd_timeout poll
  (0x2dc6c0 µs) of CCCR 0x03 until it reads **6** (0x9e420-0x9e448 —
  the model's 0x02→0x03 mirror already satisfies it: 0x06|0x04 ==
  0x06); si_setcore + reg writes (0x9e49c/0x9e530/0x9e540);
  **bcmsdh_intr_enable** (0x9e68c); dhdsdio_sr_cap (0x9e6dc);
  bcmsdh_gpio_init (0x9e730); dhdsdio_devcap_set (0x9e7d0); the
  dhd_slpauto reg write (0x9e858). dhd_bus_devreset then continues:
  dhd_enable_oob_intr(bus, TRUE) (0x9f628) +
  **bcmsdh_oob_intr_register(bcmsdh, wlan_oob_irq, bcmsdh)**
  (0x9f644) + bcmsdh_oob_intr_set(bcmsdh, 1) (0x9f65c) → busstate UP →
  dhd_os_wd_timer(dhd_watchdog_ms).
- **The chip→host interrupt is the OOB host-wake GPIO, NOT the SDIO
  DAT1 path (decode, 0x855d8-0x85830):** bcmsdh_oob_intr_register does
  request_threaded_irq(oob_irq, wlan_oob_irq, NULL, 0x414, name,
  bcmsdh) where oob_irq = the boot print's virq 101 ("dhd_init_gpio_
  wlan_hostwake: WL_HOST_WAKE=8, oob_irq=101, oob_irq_flags=0x414" —
  gpio 8 = PA08 from cywdhd.sh gpio_wlan_wake_host=PA08; 0x414 =
  IRQF_NO_BALANCING | IRQF_TRIGGER_HIGH). wlan_oob_irq (0x856b4)
  disables the irq (bcmsdh_oob_intr_set(0) — one-shot) and calls the
  registered handler dhdsdio_isr(bus); bcmsdh_oob_intr_set(on) is just
  enable_irq/disable_irq_nosync. The model therefore drives PA08 high
  when the "firmware" wants the host; the v0.76 gpio model's bank
  cascade (gpa → INTC 17) + the guest gpio driver's per-pin demux
  (PA16 → virq 100 for hyn_ts already works) deliver virq 101.
- **The next blocker after the ChipClkCSR fix (run2): the DHD's first
  control-packet TX dies inside the kernel's SDIO helper.** With the
  handshake fixed the run2 flow passed clkctl ("dhd_bus_init: enable
  0x06, ready 0x06 (waited 0us)"), registered the OOB irq
  ("bcmsdh_oob_intr_register OOB irq=101 flags=4") and reached
  dhd_preinit_ioctls_alive's first ioctl, whose control packet TX
  (dhd_bus_txctl → dhd_bcmsdh_send_buf → sdioh_buffer_tofrom_bus →
  sdio_memcpy_toio) died with "WARNING ... sdio_ops.c:134
  mmc_io_rw_extended+0xb0" + "WARNING ... __sg_alloc_table+0x78 (nents
  too large)" → "sdioh_buffer_tofrom_bus: TX FAILED ..., addr=0x08000,
  pkt_len=64/384, ERR=-12" → "can't get MAC address , error=-5" →
  wl_android_wifi_on failed (-14). No wire CMD53 was ever issued for the
  TX (the kernel rejected it before the controller).
- **Decode (vmlinux 4.4.94):** sdio_io_rw_ext_helper (0x80391b6c) takes
  the block path only when (a) card+0x2c8 bit0 — the SDIO caps cache
  bit set from CCCR 0x08 & SDIO_CCCR_CAP_SMB (0x02) during enumeration
  (mmc_sdio_init_card 0x8038f1d0-0x8038f1ec, sb into card+0x2c8) — and
  (b) size >= func->cur_blksize (func+0x174, set by sdio_set_block_size
  0x803915bc from the module params sd_f1_blocksize=0x40 /
  sd_f2_blocksize=0x80 via the FBR blocksize CCCR writes, which the
  trace shows at fn0 0x110/0x111 and 0x210/0x211). Otherwise the byte
  path runs and computes blksz = (card->quirks & 0x2 —
  MMC_QUIRK_BLKSZ_FOR_BYTE_MODE, card+0x170, set only through
  mmc_fixup_device, whose default table at 0x805f7770 is EMPTY) ?
  func->cur_blksize : **func->max_blksize** (func+0x170, parsed from the
  CIS FUNCE at cistpl_funce_func 0x803912e4: *(func+0x170) =
  buf[12]|buf[13]<<8). The model's fn2 CIS had NO FUNCE → fn2
  max_blksize = 0 → blksz = 0 → the WARN and the div-by-zero garbage sg
  count. The control TX goes out on **fn2** (bcmsdh_send_buf 0x84d80:
  stack arg = 2) at address 0x8000 after bcmsdhsdio_set_sbaddr_window,
  with pkt_len 64 (the wifi_off SET ioctl frame) and 384 (the
  preinit QUERY frame).
- **Fixes (v0.83 patches):** CCCR 0x08 = 0x02 (SMB) in the model's
  enumeration state, and a 42-byte CISTPL_FUNCE added to the fn2 CIS
  (max block size 0x80 at buf[12], timeout 5 at buf[28] — the same
  shape as fn1's FUNCE from patch 0001) so fn2 max_blksize = 0x80 =
  sd_f2_blocksize. fn2 itself is now modeled (fn2[0x8000] backing;
  the DHD's fn2 CMD53s read/write it), with TEMP-FW-DIAG prints on the
  fn2/backplane data phases (to be stripped).
- **The DMA data-phase chain, decoded and fixed (run4-run8):** with the
  fn2 FUNCE in place the control TX reaches the wire: the DHD's
  sdio_memcpy_toio(fn2, 0x8000, buf, len) becomes a block-mode CMD53
  (count=3 x BLKLEN=128 for the 384-byte frame, arg 0xad000003) or a
  byte-mode CMD53 (count=64, arg 0xa5000040), the host stages BLKLEN/
  NOB/RDTO, sends the command, then drives the data phase through the
  MSC internal DMA: it writes MSC_DMADA = the first descriptor's
  physical address (0x250d000/0x15d4020 — the DHD's kmalloc'd frame at
  KSEG0 0x815d4020) and MSC_DMAC = 0x9. The model's kick walks the
  descriptor {dcmd, dat, dln, flags=0x2} and moves the bytes through
  x1600_msc_fn_write — with the fn2 space enlarged to the full 17-bit
  SDIO address space (0x20000; the body lives at fn2 0x8000, the
  original 0x8000 space wrapped it to 0) the transfers complete
  ("TEMP-FW-DIAG msc0 dma kick DONE wr=1 n=384/64").
- **Completion signaling (run5-run7):** the driver's hard IRQ handler
  computes pending = IFLG & ~IMASK and returns IRQ_NONE when empty; the
  driver's data-phase IMASK is 0xff7ff9fb (only IFLG bit10 unmasked),
  and the threaded handler dispatches the data-done on the RAW IFLG
  bit15 (it unmasks bit15 around the wait and re-masks after, state
  machine 0x0e78-0x0e90). The model's kick originally raised only
  bit15 — masked, so the hard IRQ never fired and every request timed
  out ("md_ingenic,mmc ... request_timeout" + the zero-descriptor
  dump, ERR=-159). Fix: the data-phase completion (the DMA kick and
  the PIO TXFIFO path) now raises IFLG bit15 | bit10; the thread then
  runs, completes the request, and the DHD's TX gets as far as the
  kernel's return value.
- **Where it parks (run8, sd_msglevel=0xffff):** the wire transfer
  completes and the thread completes the request, but the kernel's
  sdio_memcpy_toio still returns -1 ("sdioh_buffer_tofrom_bus: TX
  FAILED ..., ERR=-1" — a bare -1, not a standard errno; the DHD maps
  it to "sdio error -1, abort command and terminate frame" with the
  CCCR 0x06 = 0x02 abort write, then the watermark/frame-block re-init
  and the next attempt). The -1 originates inside the kernel's
  mmc/sdio completion path (mmc_io_rw_extended returns cmd.error or
  data.error as set by soc_msc.ko; no data->error = -1 store exists in
  the module, so the remaining suspects are the cmd->error assignment
  in ingenic_mmc_command_done's R5/status checks or an additional
  state-machine condition). The DHD's control-protocol emulation (the
  chip-side response packet + the host-wake GPIO PA08 assert) is the
  next model-side surface once the TX returns 0 — parked here with the
  TX data verified on the wire and the -1 precisely scoped.

## v0.84 (2026-10-15, fw-download round 2, worktree qemu-wifi-fw2) — the
control-TX -1 pinned to the module's data-DONE wire bit: the model was
raising the ERROR-cluster source; IFLG bit23 is the real data-done and
the DHD's first control TX now completes with error 0

- **Setup (fw2):** fresh cp -a of vendors+unpacked at the merged main
  (patches 0001-0018 + 0120-0121), incremental rebuild OK. Boots to
  /tmp/kilo/fw2/, console telnet 127.0.0.1:4448 + tee, unimp -d trace
  for mscdec.py.
- **The -1 site, decoded from soc_msc.ko (unpacked 1.6 module_driver,
  symtab + reloc-resolved objdump; full dis at /tmp/kilo/fw2/
  soc_msc.dis):** NOT the timeout path and NOT the R5 checks — it is
  ingenic_mmc_thread_handle (the devm_request_threaded_irq thread fn,
  0xe94; primary handler NULL, dev_id = the jzmmc host struct) plus the
  state machine it drives. The thread computes pending = IFLG &
  ~IMASK (regs+0x28/~0x24) and dispatches: bit7 (0x80) = the SDIO card
  INT (signals mmc sdio_irq, wake_up_process); **bits 8-12 (0x1f00) =
  the ERROR cluster**: acked (0x1f04 in state 1, 0x80801f00 in state 2,
  0x1f00 otherwise), then — for CMD53 (cmd->opcode == 53) only — checks
  STAT (regs+0x04) bit4 (0x10) and on set prints dev_err + stores
  cmd->error = -1 directly (0xfc8); then unconditionally sets state = 4
  and calls ingenic_mmc_state_machine. The state-4 handler (jump table
  .rodata[4] = 0xd04) stores cmd->error = -1 (0xd10) and
  data->bytes_xfered = 0 whenever mrq->data is present, del_timer,
  state = 0, mmc_request_done. So ANY data-cluster IFLG bit pending in
  states 1/2 completes the request with -1. The v0.83 raise (bit15 |
  bit10) put bit10 into that cluster → the thread raced the request fn
  (DMA mode returns without polling; the data phase is completed only
  by this thread) and completed with cmd->error = -1 — the bare -1.
  (bit15 alone, pre-v0.83, fed the thread's bit15 case → state-2 event
  flag bit4 — but state 2 consumes flag bit3, state 3 is dead code (no
  writer sets state 3), so nothing completed → the 300-jiffy timer →
  request_timeout → the v0.83 -159 timeouts. Both observed behaviors
  now explained by one wire-semantics error.)
- **The SUCCESS path, decoded:** the module's data IMASK 0xff7ff9fb
  unmasks IFLG bits 2, 9, 10, 23. bit2 = END_CMD_RES (command phase:
  thread sets host+1664 flag bit0 → state-1 handler consumes it,
  STAT&0x3f clean → ingenic_mmc_command_done reads RES into
  cmd->resp[0..3] → state = 2). **bit23 = data-DONE**: the thread acks
  0x00810003, sets host+1664 flag bit3, and the state-2 handler
  (consuming bit3) with STAT&0x3f clean and mrq->stop == NULL runs
  ingenic_mmc_data_done (bytes_xfered = blocks*blksz, del_timer, DMA
  sync) and TAIL-CALLS mmc_request_done with cmd->error untouched = 0.
  bit31 = a second error class (acks 0x80010001). Bit15 feeds only the
  dead state-3 flag. (The request-fn's synchronous polling tail —
  polling_status(STAT 0x1000/0x2000) + IFLG 1/2 write + mmc_request_done
  — is the POLLING-mode path (module flag host+2372 bit2), not the DHD's
  DMA path; it explains STAT bit12/13 = XFER_DONE_RD/WR, already
  modeled.)
- **Model fix (one wire-semantics line, two sites):** the PIO TXFIFO
  completion (x1600_msc_write MSC_TXFIFO) and the internal-DMA kick
  completion (MSC_DMAC) now raise IFLG_DATA_DONE = bit23 instead of the
  v0.83 bit15|bit10; STAT bit12/13 unchanged (the polling path still
  sees XFER_DONE). Comments corrected to the decoded protocol.

## v0.85 (2026-10-15, fw-download round 3, worktree qemu-wifi-fw2) — the
virq-101 demux verdict INVERTED: dispatch works (the run8 "no dispatch"
was a stale-object artifact of the broken vendored build config); the
blocker is now downstream — the DPC's first bus access is a 4-byte fn1
backplane read, no fn2 frame read follows, rxlen=0

- **Setup:** the worktree's tools/vendors/qemu/build was configured
  against the MAIN tree's absolute paths (cp -a carried meson-info with
  source=/main/tools/vendors/qemu); relative-path C rules still compiled
  the worktree's x1600.c, but the tracetool inputs (tools/qemu-vnc/
  trace-events) point at the main tree and the main tree no longer has
  them, so any incremental ninja died with "missing and no known rule".
  Re-ran ./configure --target-list=mipsel-softmmu in the worktree tree
  (full 1712-target rebuild) — the binary is now DEFINITELY the
  worktree's model. The prior runs' binaries cannot be trusted to carry
  every worktree edit (which edits were stale is unknown — treat run8's
  "no dispatch" as an artifact, not a wire fact).
- **The demux chain, decoded end-to-end (kdis flow, vmlinux.bin):**
  tingenic_pinctrl_probe (0x80412290) loops the DT children gpa/gpb/
  gpc/gpd (order matches the model's INTC wiring A=17 B=16 C=15 D=14);
  per bank: memset(chip,0,0x88); chip->base = running accumulator
  (ctx+0x14: 0/32/64/96, += ngpio after gpiochip_add); ngpio = 32
  (DT ingenic,num-gpios); chip->to_irq = tingenic_gpio_to_irq
  (chip+0x3c); bank byte at chip+0x8c; ctx at chip+0xc0. Then virq =
  irq_of_parse_and_map(child, i) → chip+0x94; domain = __irq_domain_add
  (size=hwirq_max=32, ops 0x806038b8 = {tingenic_irq_domain_xlate,map},
  host_data = chip) → chip+0x98; irq_set_handler_data(bank_virq, chip)
  + __irq_set_handler(bank_virq, tingenic_gpio_irq_handler, 1, 0).
  tingenic_gpio_to_irq: BUG(offset < chip->ngpio), then
  irq_create_mapping(chip+0x98 domain, offset). tingenic_irq_domain_map
  sets chip_data = the chip and irq_set_chip_and_handler_name(virq,
  chip 0x807a9d90 (.data, not in vmlinux.bin), handle_level_irq, NULL).
  tingenic_gpio_irq_handler: pending = INTP(+0x50+bank*stride) &
  ~INTM(+0x20+...) (the +0xc4 shadow ptr is 0 in this build → the reg
  path), find_next_bit(&pending, ngpio, off) → irq_find_mapping(domain,
  bit) → generic_handle_irq(virq); a 0 mapping silently skips (no ack).
  Per-pin callbacks: irq_mask → +0x24 = 1<<hwirq, irq_unmask → +0x28,
  irq_ack → +0x58 (W1C), all through *(chip+0xc0)+bank*stride — exactly
  the regs the model's TEMP-FW2-DIAG watches. The DHD side
  (dhd_init_gpio_wlan_hostwake): irq = md_ingenic_sdio_wlan_get_irq()
  (= 8, the module param; printed as WL_HOST_WAKE=8), gpio_request(8)
  → gpio_to_desc(8) → gpiod_direction_input → gpiod_to_irq(desc) = 101
  (the print's "oob_irq=101"), dhd_wlan_resources = {101,101,flags
  0x414}; bcmsdh_oob_intr_register request_irq(101) at the WLAN-ON
  step (kernel 148.66 in run9), BEFORE the first PA08 raise.
- **RUNTIME EVIDENCE (run9, live guest dumps via the respawn shell):**
  /sys/class/gpio: gpiochip0 GPA base=0 ngpio=32, 32 GPB, 64 GPC, 96
  GPD — gpio 8 IS PA08 (bank A pin 8), exactly the model's inject.
  /proc/interrupts: INTC legacy base 8 (virq = INTC hwirq + 8), GPIO
  mappings dynamic (97 KEY_POWER hw31, 98 hw28, 99 hw22, 100 hyn_ts
  hw16), and AFTER the DHD's OOB register + the control TX: **101: 1
  GPIO 8** — the mapping is (domainA, hwirq 8) and THE DEMUX DISPATCHED
  IT: count 1 = handle_level_irq ran handle_irq_event → the DHD's ISR
  action ran. The widened model diag confirms the full genirq cycle:
  request_irq-time +0x28=0x100 (unmask), PA08 raise, demux reads
  +0x20/+0x50, +0x24=0x100 (mask) + +0x58=0x100 (ack) at dispatch,
  post-DPC +0x28=0x100 re-unmask. So: PA08 → demux → virq 101 →
  dhdsdio_isr → dpc ALL WORK in the fully-rebuilt binary.
- **The new blocker:** one control TX (cmd=262 cur_etheraddr id=1),
  one PA08 raise, one dispatch — then `dhd_bus_rxctl: rxcnt_timeout=1,
  rxlen=0`. The DPC issued exactly ONE bus op before going quiet: a
  CMD53 arg 0x15404004 = READ fn1 addr 0x0A020 count 4 (byte, inc) —
  a BACKPLANE window read (bp = (SBADDR<<8) | 0x2020), NOT the fn2
  frame read. The model serves zeros there (bp_chunks are malloc0).
  readframes never read fn2, so the staged fn2 response was never
  fetched. run10 re-boots with TEMP-FW2-DIAG c53/c52 logs (every CMD53
  decode + served bytes; the window regs + clkcsr CMD52s) to identify
  the DHD's read sequence and what it expects at that SOCRAM offset.

## v0.84 (2026-10-15, BT round, worktree qemu-bt-bluez) — the BT bring-up
decoded and modelled: the bluez crash-loop ends, hci0 registers, the
wizard reaches the timezone page alive (patch 0123, vendored qemu
91f3215)

- **The freeze mechanism, decoded end to end.** The timezone-screen
  freeze was the player aborting itself in a loop: its statically linked
  bluez GDBus client asserts
  `ERROR:lib/bluez/adapter.c:194:adapter_get_properties: assertion
  failed: (ADAPTER_IS(self))` → `Bail out!` → `Aborted`, respawned by
  the supervisor, crashing again — the respawn flood is what starves the
  wizard. The root cause is one step below: the AP6212 **BT half** never
  comes up, so no adapter object ever exists for the player's bluez
  client. (The WIFI half of the same combo chip is the separate
  fw-download round parked at v0.83 — untouched here.)
- **The stock BT bring-up chain (decode of
  `unpacked/1.6/squashfs-root/etc/init.d/S80_bt_init` →
  `/usr/bin/bt_init`, a shell script):** dbus-daemon up, rfkill0 on,
  BD_ADDR generated into `/usr/data/bt_macaddr.txt` (prefix
  `4C:BC:98:B0`, random 10-bit suffix), firmware selection off the SDIO
  chipvendor sysfs (AP6212 →
  `/lib/firmware/bt_bcm/BCM4343A1_001.002.009.1010.1030.hcd`, 46,324
  bytes), then
  `brcm_patchram_plus --enable_hci --baudrate 3000000 --no2bytes
  --patchram <hcd> /dev/ttyS0 --tosleep=50000
  --use_baudrate_for_download --enable_lpm --bd_addr <addr> &`, sleep 5,
  `hciconfig hci0 up`, `bluetoothd -E -C`, `hciconfig hci0 reset`,
  `bt-agent -c NoInputNoOutput`, `bluealsa -p a2dp-source`,
  `bt-adapter --set Powered On/Alias`, `sdptool add HIBYLINK_SP`,
  `bt-adapter --set Powered Off`, `/tmp/bt_init_ok`.
- **brcm_patchram_plus decoded by disassembly** (12.7 KB MIPS32r2,
  stripped; the classic Broadcom tool rebuilt by HiBy, glibc-linked):
  state machine = init_uart (cfmakeraw, B115200) → proc_reset →
  [use_baudrate_for_download && baudrate] proc_baudrate_change →
  proc_patchram → proc_baudrate_change again → proc_bdaddr →
  proc_enable_lpm → proc_enable_hci → `sleep(-1)` forever holding the
  tty. Byte-exact command buffers from .data:
  - HCI_Reset `01 03 0c 00` — **the SIGALRM retry loop is the live
    trace's 69 resets**: `signal(SIGALRM, handler)` where the handler
    re-sends the reset buffer and re-arms `alarm(4)`; the blocking
    `read_event` is interrupted every 4 s and the command re-fires until
    a response arrives (the pre-fix ttyS0 capture was exactly 69 ×
    `01 03 0c 00` then idle).
  - VS 0xFC18 baud change `01 18 fc 06 <baud LE32> 00 00` — baud
    3000000 encodes as 0x002dc6c0 little-endian (`c0 c6 2d 00`); the
    .data baud table maps 115200..4000000 to termios B-constants
    (B3000000 = 0x100d).
  - VS 0xFC2E download minidriver `01 2e fc 00`, then the HCD file
    streamed as raw H4 command records — the file format is
    `[op_lo op_hi plen payload...]` per record with the H4 type byte
    prepended by the tool (`li v0,1` + `sb` in the read delay slot):
    **181 × 0xFC4C write-RAM records (70/255×178/59 bytes) + 1 × 0xFC4E
    launch record (plen 4)**; `--no2bytes` skips the 2-byte
    confirmation read, `--tosleep=50000` usleeps before streaming.
  - post-launch: the tool re-arms B115200 (use_baudrate_for_download
    path: the relaunched chip drops back to the default UART speed),
    tail-calls proc_reset (another HCI_Reset, alarm-retried), then the
    final 0xFC18 baud change, VS 0xFC01 write-BD_ADDR
    (`01 01 fc 06 <6 bytes straight order>`), VS 0xFC27 sleep mode
    `01 27 fc 0c 01 01 01 01 01 01 01 00 00 00 00 00`.
  - `--enable_hci` = `ioctl(TIOCSETD, N_HCI=15)` +
    `ioctl(0x800455c8 /* HCIUARTSETPROTO */, HCI_UART_H4=0)`; the
    kernel's hci_uart then owns the tty and hci0 appears (the stock
    vmlinux has n_hci/hci_uart built in — strings-verified).
- **The model: a BT-side HCI responder on uart0 (patch 0123, vendored
  qemu 91f3215).** A `chardev-x1600bt` Chardev interposed between the
  serial core and the real serial1 backend: every TX byte is mirrored
  into the upstream backend so the earlycon (stock DTB stdout-path on
  ttyS0) still lands in the capture file; H4 command frames (from the
  patchram before the ldisc, from the kernel hci_uart after) are
  answered with H4 Command Complete events injected via
  `qemu_chr_be_write`, **paced by `qemu_chr_be_can_write`** because
  `serial_receive1` drops on recv-FIFO overflow (the largest event,
  Read_Local_Name's CC, is 7+248 bytes vs a 16-byte FIFO) with a
  20 µs QEMU_CLOCK_VIRTUAL re-arm timer for the drain. The patchram
  surface (all commands above incl. 0xFC2E/0xFC4C/0xFC4E) gets status-0
  CCs; VS 0xFC01's address is **remembered and reported back through
  Read_BD_ADDR**, so the kernel shows exactly the BD_ADDR bt_init
  generated. The radio itself is not modelled — no RF traffic, the
  adapter must merely exist. TEMP-BT-DIAG prints were used during the
  bring-up and stripped from the commit.
- **The kernel's open-time HCI init surface, pinned empirically** (the
  4.4.94 stock kernel's own sequence, one command at a time through
  hci_uart): `1003` Read_Local_Features → `1001` Read_Local_Version →
  `1009` Read_BD_ADDR → `1005` Read_Buffer_Size → `0c23`
  Read_Class_of_Device → `0c14` Read_Local_Name → `0c25`
  Read_Num_Broadcast_Retransmissions → `0c38`/`0c39` IAC reads →
  `0c05` Set_Event_Filter → `0c16`/`0c13` Connection_Accept_Timeout
  reads → `1002` Read_Local_Commands → `0c01` Set_Event_Mask → `0c1c`
  Page_Scan_Activity_Period → `0c47` Inq_Response_TX_Power → `0c24`
  status writes — then power transitions (another 0x0c03 Reset per
  Powered On/Off). **Every one of them must complete with status 0x00:
  4.4's `__hci_req_sync` reports the LAST command's status as the sync
  result, and `bt_to_errno(0x01)` turns one Unknown-Command response
  into the whole HCIDEVUP failing** — that was the mid-bring-up
  "Can't init device hci0: Invalid request code (54)" stage (the
  guest glibc strerror for the EBADRQC-family errno on MIPS). Features
  answer `0xbc 0x28 0x0c 00...` (classic BR/EDR, no LE — features[6]
  bit 6 clear keeps the LE init out), buffer size ACL MTU 1021/8,
  SCO 64/8, class `0c 02 00`, name "HiBy R1" (248-byte field),
  Read_Local_Commands all-zero (the kernel then sends no bitmap-gated
  extras).
- **Verified by boot (a) crash-loop stops:** with the responder, the
  download completes (207 VS commands on the wire, matching the 182
  HCD records + the reset/baud/minidriver/launch set), the kernel init
  runs to completion (235 controller commands, zero unknowns),
  `hciconfig hci0 up/reset` succeed, bluetoothd powers the adapter
  (`Powered: 1 -> 1`, `Alias: BlueZ 5.54 -> HiBy R1` accepted,
  `sdptool add HIBYLINK_SP` registers) and bt_init ends
  (`Powered: 1 -> 0`, `/tmp/bt_init_ok`) — and the console has **zero
  adapter.c assertions** across every boot since the fix landed (the
  pre-fix console showed the abort every ~2 s).
- **Verified (c) hci0 exists, from the respawn shell** (ttyS2 console
  = `console::respawn:-/bin/sh`, reachable via
  `-serial telnet:...,server,nowait`): `hciconfig -a` prints
  `hci0: Type: Primary Bus: UART, BD Address: 4C:BC:98:B0:2A:49, ACL
  MTU 1021:2112, Features 0xbc 0x28 0x0c 00...` (the BD_ADDR is the
  one bt_init generated and the responder remembered),
  `/sys/class/bluetooth/hci0` exists, `hcitool dev` lists it; the
  adapter ends DOWN because stock bt_init powers it off last —
  faithful to the real device (the player powers it on demand).
- **Verified (d) tools/x1600-boot-test.sh PASS** — twice (pre-strip and
  post-strip builds), 297 distinct messages / 158 structural lines
  against boot-baseline-v0.75.txt. **Operational note recorded: the
  SFC/NAND image is the guest's persistence layer — every boot dirties
  `nand-r1.bin` in the qemu process's cwd (the UBIFS journal replay on
  the next boot changes the window: "UBIFS recovery needed/mounted"
  instead of the fresh-format marker "default file-system created"),
  and the gate then fails on the missing marker.** The worktree gate
  runs regenerated the pristine image first with
  `tools/x1600/make_nand_image.py unpacked/1.6/nand-r1.bin
  unpacked/1.6/xImage unpacked/1.6/rootfs.squashfs`; the regenerated
  md5 differs from the v0.75 baseline header's (the generator inputs
  evolved) but the fresh-format window matches byte-for-byte after
  normalization. The shared demo VM boots with cwd = the main repo, so
  its boots likewise drift MAIN's nand-r1.bin.
- **Verified (b) the wizard, visually (VNC + QMP taps, patch 0122's
  crosshair confirms the pointer):** on the BT-fixed build the wizard
  is alive and ADVANCES — language picker renders, tapping English
  re-lays the page into the Region picker (United Kingdom / United
  States / China / Japan), tapping China advances into the
  **Time zone page — the exact former freeze point — rendering rows
  Beijing GMT+08:00 / Urumqi GMT+06:00** with zero assertions in the
  console. Screendumps: /tmp/kilo/bt/v_before.png (language),
  v_after_lang.png (Region), v_after_region.png (Time zone).
- **Residual, parked OUTSIDE this lane with evidence:** the tz page's
  own row tap does not advance. Reproduced 4× (two VMs, two sessions),
  including pre-blank; the console stays quiet (0 assertions), the
  player's threads look healthy (`system_main_thr` and `lg_ial` in
  `poll_schedule_timeout`, the 33 ms poll loop running). Guest-side
  diagnosis from the respawn shell: full-process strace shows the
  player reads NOTHING but its timerfd during tz-page taps (`od -x
  /dev/input/event1` reads 0 bytes — the kernel hyn_ts chain delivers
  no events at that point), the touch died between the region tap and
  the tz tap (~2 s), one `hyn_ts_suspend: set TP to sleep mode fail,
  ret=-145` + `i2c1 write timeout` in dmesg (the idle/blank touch
  suspend path), /usr/data is writable (23 MB free, WRITEOK), and the
  player holds event0-3 open (fd 6 + 22 both event1). This is the
  v0.78 blanked-state/input wall territory (input + display lanes),
  not the BT/bluez path — the crash-loop this round was after is gone
  and the wizard's language→region→tz progression is BT-independent
  evidence the GUI mainloop is unstarved. The v0.78/0.79 established
  escape (stock 5-min power-save reboot, tap inside the fresh window)
  still applies; the tz-row handler needs the input lane's attention.
- **Demo feed:** the hiby-live-demo VM was rebooted onto the BT-fixed
  build (persistent bgp, VNC 127.0.0.1:0, QMP/monitor sockets under
  /tmp/kilo/livedisp/, console now tee'd via a socket chardev
  `logfile=` to /tmp/kilo/livedisp/console.log with the respawn shell
  on telnet 127.0.0.1:4448). The feed boots to the wizard with the
  BT chain fully up and no crash-loop.

## v0.86 (2026-10-15, fw-download round 4, worktree qemu-wifi-fw2) — the
DPC chain run10-run15 closed out; the run14 ERR=-159 and the run15 hang
both decoded from soc_msc.ko's request fn: the 4-byte window ops take the
POLLING word loops (the READ loop spins while STAT bit6 is SET — the
run15-prep bit6 staging deadlocked it), and DMA READS complete via IFLG
bit31, not bit23 (the read-DMA IMASK masks bit23 — the v0.84 raise was
never seen by the thread and the request timed out into -159)

- **run10-run13 (each verified on the wire, then folded into the model):**
  (run11) the DPC's gate is the SDIO device core's INTSTATUS backplane
  read at bp 0x18002020 — the model now serves 0xC0 (frame|host bits)
  while a control response is staged, W1C on write, and deasserts PA08 at
  the W1C; without it the DPC re-arms without ever calling readframes.
  (run12) the fn2 data port is a STREAMING FIFO, not a fixed-address
  window: the 128-byte fixed-address read served the first staged byte
  repeatedly — fixed by popping the staged response FIFO on every fn2
  byte. (run13) the RX walk double-popped: the command phase already
  prefetched the whole data phase into the model's fifo (fn2 is
  destructive), so the DMA walk re-read fn2 → zeros → corrupt header →
  rxlen=0 — fixed: the walk serves the staged fifo when fifo_len ==
  dma_len (only fn2 reads are destructive; the PIO pops may already have
  advanced fifo_pos — the staged bytes stay valid) + PA08 deasserts at
  the intstatus W1C.
- **run14:** the DPC's readframes DID pick the staged response up — the
  walk served it into the DHD's buffer ("dma done ok=1 wr=0 buf: 32 00
  cd ff 01 01 00 01" = framelen 50, checksum ✓, seq=id ✓) — but the DPC
  got ERR=-159 from sdioh_buffer_tofrom_bus ("RX FAILED 825ddd40,
  addr=0x08000, pkt_len=128") and discarded the frame; dhd_bus_rxctl
  timed out (rxlen=0), dhd_preinit_ioctls_alive failed with -145, the
  DHD power-cycled and retried the whole cycle (id=2).
- **run15 (the brief's item-6 hypothesis applied) WEDGED the guest:**
  with STAT bit6 staged for BLKLEN<64 requests, the 4-byte fn1 window
  read (arg 0x15000004, BLKLEN=4) spun forever in the module's polling
  READ loop — 6.9 GB of unimp trace, an endless flood of "x1600-msc
  read 0x4 = 0x1840 pc=c017e244" (= module base 0xc017c000 + 0x2244, the
  loop's STAT re-poll at ingenic_mmc_request+0x6bc) — the loop can only
  exit by popping (which needs bit6 CLEAR) and the model clears bit6
  only when the FIFO drains (which needs pops): a deadlock. The 3000 ms
  module timeout then printed the reg+descriptor dump and the guest
  stayed wedged in the spin (the timer completed the request; the poll
  loop never returned).
- **The request-fn decode (soc_msc.dis ingenic_mmc_request 0x1b88, now
  full):** the POLLING flag is host+2372 bit2, set at 0x1c94 when
  data->[36]==1 AND sg->length < 64 — the DHD's 4-byte window reads and
  writes take the polling word loops at 0x2130-0x22e8: per word, the
  READ loop polls STAT bit6 (0x40) — **spin while bit6 SET, pop MSC_
  RXFIFO when CLEAR** (0x22b0 stores the word) — and the WRITE loop
  polls STAT bit7 (0x80) symmetrically; then the byte tail, bytes_
  xfered = blocks*blksz, and polling_status(STAT 0x1000/0x2000) which
  the model already satisfies by staging STAT bit12/13. Polling ops
  never touch IMASK's data bits and never kick DMAC (DMAC=0 in the
  run15 dump). With bit6 CLEAR at staging (run14) the window reads
  popped fine — the run15-prep staging was simply the wrong sense.
- **The DMA-path IMASK decode — the real run14 -159:** the DMA branch
  (sg length >= 64) does IMASK &= ~dcmd at 0x1f0c (WRITE dcmd
  0x00800400 → enables IFLG bits 10+23; READ dcmd 0x80000900 → enables
  bits 8+11+31), then IMASK &= 0xFFFFFDFB at 0x1ff0 (adds bits 2+9).
  WRITE-DMA final IMASK 0xff7ff9fb: bit23 enabled — the model's bit23
  raise works (runtime-verified: the thread read IFLG=0x800000 with
  IMASK=0xff7ffbff, acked 0x00810003, set the state-2 flag bit3, masked
  everything, and the state-2 handler ran data_done → the TX completed
  error 0). READ-DMA final IMASK 0x7FFFF6FB: **bit23 MASKED, bit31
  enabled** — the model's bit23 raise sat in IFLG unprocessed for the
  full 3000 ms (run14 dump: IFLG=0x00800000, state=2, DMAC=9 kicked)
  until ingenic_mmc_request_timeout fired and stored -159 at 0x15ac.
  The thread maps pending bit31 the same way as bit23 (state-2 event
  flag bit3, ack 0x80010001) — bit31 is the DMA READ data-done source.
- **Model fix (three lines, run16 prep):** revert the STAT bit6 staging
  (the polling pop loop needs bit6 CLEAR); raise IFLG bit31 for
  read-DMA completions (write completions keep bit23); clear stale
  bit31 alongside bit23 in the per-command tail. STAT bit12/13 staging
  stays (the polling_status tail).

## v0.87 (2026-10-15, fw-download round 5, worktree qemu-wifi-fw2) — the
control protocol is END-TO-END: the MAC ioctl completes, 28 preinit
ioctls complete, and `ifconfig wlan1 up` returns 0 with "Firmware up"
(wlan1 registered and operational; the fw download itself stays skipped
by the driver design, the v0.83 finding). Four decode fixes got there:
the run15 hang root-caused (the bit6 revert), the read-DMA completion
moved to IFLG bit31, the SDPCM control-response header fixed (channel 0
+ dataoffset 32), the DHD credit/CDC-id/iovar payload surface filled

- **run16 (the v0.86 fixes live):** the guest no longer hangs — the
  probe's window reads complete ("F1 signature read @0x18000000=
  0x1000a9a6" at 17.79s, no module timeout), the probe parks with the
  stock "firmware path not found" (two attempts register wlan0 then
  wlan1; the second instance is the live one). The scripted
  `ifconfig wlan1 up` reached dhd_open → WLAN ON → "skip download FW and
  nv" (the v0.83 skip) → the control TX completed ("TX xfr'd ..., len=
  384") — but the DPC's readframes discarded the response with
  "dhdsdio_readframes: Bad data offset 1: HW len 50, min 12 seq 1".
- **The SDPCM header decode (cywdhd readframes 0x99718):** [0:2]
  framelen, [2:4] its checksum (^ == 0xffff), [4] = seq, [5] =
  channel+flags (the LOW NIBBLE dispatches: 0 = the CONTROL handler —
  the cold-section function that memcpy's the frame into the ctrl
  buffer the ioctl completer reads; channels 1-3 go down the event/data
  pipeline and a response is never seen), [6] = nextlen (< 0x81),
  [7] = dataoffset (a BYTE, must be >= 12 and <= framelen). The model's
  response carried the request's channel byte (1) and dataoffset (1) —
  fixed: channel 0, dataoffset 32 (the CDC header offset — the wire
  convention the DHD's own control TX uses, verified by the model's
  request parse: cmd at +32, the iovar name at +48).
- **run17:** the MAC ioctl COMPLETED and the DHD issued the next ioctl
  (WLC_GET_VAR "cap", 640 bytes) — which the model's ctl_rx length gate
  (> 512) rejected: no response staged, rxlen=0. Fixed: the gate to
  2048 and fn2_rd to 2048 bytes.
- **run18:** a full ioctl sequence ran (ids 1-4) but the FIFTH txctl
  deadlocked: "dhd_bus_txctl: ctrl_frame_stat == TRUE txcnt_timeout=1"
  after 5 s (dhdcdc_msg w/status -5). Decode: the DHD's txctl sets
  ctrl_frame_stat=TRUE, then SKIPS its own DPC wake when the
  dpc_sched/bus+0x48 flag is latched, and trusts a pending DPC pass to
  send the frame (dhdsdio_txctl at cywdhd 0x99634 sends it and clears
  the stat + wakes the waiter). With the model's instant-PA08 cadence
  the pending pass can already be past its stat-check → the frame is
  never sent and nothing schedules the DPC again. ALSO decoded: the
  response's SDPCM byte 9 is the dongle's credit-grant watermark (the
  DHD's sendable credits = (byte9 - its tx_seq) mod 256; readframes
  flags a backward grant at ((byte9 - txseq) & 0xff) >= 0x71 — the
  "got unlikely tx max 0 with tx_seq 4" print) and byte 8 is the
  flow-bit window. With byte9 = 0 the credit window is negative.
  Fixed: byte9 = the request's seq + 8 (the model reads the DHD's
  tx_seq off the wire — the DPC's txctl rewrites the frame's seq byte
  to it) + the delayed PA08 re-assert: 10 ms after every fn2 frame
  read the model re-asserts PA08 once (the re-kick timer), giving any
  pending ctrl_frame_stat send its DPC pass; harmless when idle
  (intstatus reads 0, the pass exits).
- **run19:** the credits unblocked the send pipeline — 32 ioctls ran —
  then id 32 deadlocked: the model truncated the CDC ioctl id to 5 bits
  ((cflags >> 16) & 0x1f) and the DHD's id counter had reached 32, so
  the response's id was 0, dhdcdc_cmplt never matched, rxlen=0. Fixed:
  the CDC flags echoed verbatim (the request carries no error bit).
- **run22:** the sequence ran to the last iovars — cur_etheraddr, cap,
  toe_ol, p2p, nmode, vhtmode, txstreams/rxstreams, ldpc_cap, stbc_rx/
  tx, txbf_bfe/bfr_cap, mimo_bw_cap, chanspecs, per_chan_info — and the
  EMPTY chanspecs response left the DHD's wl_uint32_list count as stale
  buffer garbage: wl_construct_reginfo churned thousands of "Invalid
  channel Sepc. 0x..." lines. Chanspec format decoded from the DHD's
  own masks (cywdhd 0x4ebcc): (& 0x3000) == 0x1000 = WL_CHANSPEC_BW_20,
  (& 0xc000) == 0 = band 2G, the low byte = the channel, the
  (& 0x3800) == 0x1800 combo rejected. Fixed: "chanspecs" returns the
  2.4 GHz 20 MHz list (count 13, 0x1000|ch for ch 1..13) and
  "per_chan_info" returns the 2.4 G capability bitmap 0x3ffe.
- **run23: THE MILESTONE.** 28 control exchanges complete; the DHD runs
  dhd_preinit through the regulatory construction; "Firmware up:
  op_mode=0x0001" and **IFUP_rc=0** — wlan1 registered and operational.
  The remaining Invalid-channel prints come from later per-bw_cap
  constructions (bw_cap variants of the chanspec list — a cosmetic
  data-quality item, non-blocking). The firmware download itself stays
  skipped by the driver design (v0.83: dhdsdio_download_firmware gates
  on the module-global alive == 0x15151515, armed by the probe when the
  card "looks alive") — the arc's download/handshake steps are the
  driver's documented skip, not a model gap.
- **Model state (the vendored qemu, uncommitted):** the read-DMA
  completions raise IFLG bit31 (writes keep bit23), the polling READ
  loop keeps bit6 CLEAR at staging, the walk serves the staged fifo and
  carries a bounded-iteration guard, the stale per-command tail clears
  bit23+bit31, ctl_rx builds the SDPCM control header (channel 0,
  nextlen 0, dataoffset 32) + the CDC echo (cmd, len, flags verbatim)
  + the credit watermark (seq+8) and answers cur_etheraddr, chanspecs
  and per_chan_info with real payloads, and the fn2 read port re-asserts
  PA08 10 ms after each frame read (the re-kick timer). The
  TEMP-FW2-DIAG trace instruments stay worktree-only (stripped from the
  exported patch).

## v0.88 (2026-10-15, M3 tz round, worktree qemu-wizard-tz) — the tz flow
decoded from the player binary; AND a main-build regression caught on the
first boot: the wifi round's x1600.c rewrite dropped the BT HCI responder
(patch 0123) — the bluez crash-loop is back; restored before any tz work

- **Setup** per convention (vendors + unpacked cp -a, gitignored as
  established). Demo VM verified running (bgp_13dccab4, cwd = main repo,
  VNC 127.0.0.1:0, sockets under /tmp/kilo/livedisp/). Operational notes:
  - the socket-chardev console drops guest output ENTIRELY when no
    client is connected — char-socket.c tcp_chr_write returns -EIO on
    the disconnected path and the core drops the bytes; logfile= logs
    only connected traffic (verified twice: the demo VM's own
    console.log is static with no telnet client, and the tz-diag VM's
    first boot captured 0 bytes despite logfile=). Capture recipe that
    works: connect the client BEFORE the boot (persistent python
    reader, /tmp/kilo/tz/console_cap.py) or use a plain -serial file:.
  - QMP system_reset on x1600 is NOT a reliable reboot: after the guest
    reaches userspace it parks the CPU at the PROM reset vector
    (pc=0xbfc00380, ttyS0 earlycon static, no kernel re-entry). To
    cycle the guest, restart the qemu process (background_process stop
    + start) — never pkill (demo VM safety rule).
  - pristine NAND regenerated before each clean cycle with
    tools/x1600/make_nand_image.py (the md5 matches the v0.79 note,
    ae41e974e78aab2730774d05c9cbf37c).
- **The tz flow decode** (player 4.6M musl, vaddr = file + 0x400000;
  string refs via lui/addiu absolute pairs with sign-adjusted low
  halves — objdump prints addiu immediates as signed DECIMAL; xref
  helper kept at /tmp/kilo/tz/xref.py):
  - **resources**: usr/resource/str/<lang>/region.txt (CLDR territories
    GB/US/CN/JP/FR/... — the region picker rows), zones.txt (CLDR
    zoneStrings: "Europe:Paris" { ec{"Paris"} } — the city labels),
    zone_info.ini (UTF-16LE: "(UTC+01:00)" label strings keyed
    UTC+0100), tzlookup.xml (IANA ids per country code), zone_standtime.txt
    (11.5K, the standby-time options — the wizard's NEXT page material).
    The tz row text "<City> GMT+01:00" = zones.txt city + the binary's
    UTC±HH00 label table at vaddr 0x7784d8 rendered through zone_info.ini.
  - **the applier 0x469be0**: reads setting 130 (the zone id string,
    e.g. "Asia/Shanghai") via 0x415360; if NON-EMPTY:
    sprintf(buf,"%s %s%s %s","ln -sf","/usr/share/zoneinfo/",<id>,
    "/usr/data/localtime") → system(buf); then system("date +\"%Z %z\"
    > /data/time_zone"). So the device stores TZ as the
    /usr/data/localtime SYMLINK + the %Z %z text in /data/time_zone
    (both writable in the VM: /usr/data is the UBIFS mount, /data the
    SFC-backed data partition — both proven writable by earlier rounds).
  - **the on-change table**: {setting-id, handler} pairs at file
    0x360c00- (id 0x130..0x15d range); id 0x15c (348) → 0x451640 = the
    tz apply chain: applier, then if the wifi state buffer at 0x86f88c
    compares equal to "COMPLETE" (0x469c60): system("ntpdate
    0.pool.ntp.org time.windows.com &") + system("hwclock -w --utc")
    (strings at file 0x36065c/0x360688).
  - **the tz listview cluster**: a descriptor table of {path[0x10c],
    name[0x100]} entries (file 0x3e7b00-0x3f5a1c, ~110 listview views)
    references z:\layout\theme1\listview\vg_listview_zone_info.listview,
    vg_listview_select_zone.listview, vg_listview_time_zone.listview
    and vg_listview_region.listview — **NONE of these exist on the
    rootfs** (theme1/listview ships only book/class/music/
    tidal_play_info). The wizard page code (0x4d2xxx module) creates
    "vg_listview_time_zone" with style "style_custom" via 0x4961e0
    (string pair at 0x784a90/0x784ac4), and the row-click handler at
    0x4d26e0: builds the zone id via the tzlookup.xml parser 0x4138c0,
    stores it with 0x416ac0(130, id) (the settings store — the same
    value is persisted under the INI key "zone_set" in sys_set.ini by
    the 0x412680 call at 0x4bffd4), then calls 0x433de0(parent, this)
    — the page-close/advance path. Taps on the region picker DO work
    (the user navigated to tz), so the tz page's dead taps are the
    live question for this round: the missing .listview layouts are
    the top suspect (the region page's list may be a different widget
    class that doesn't need a .listview file).
- **THE REGRESSION (caught by the task's "verify on your first boot"
  item): the bluez adapter.c crash-loop IS BACK on the current main
  build.** My first tz-diag boot shows the full pre-fix signature:
  `ERROR:lib/bluez/adapter.c:194:adapter_get_properties: assertion
  failed: (ADAPTER_IS(self))` → `Bail out!` → `Aborted` repeating, and
  the BT uart capture (ttyS0.log) shows brcm_patchram_plus's HCI_Reset
  retry loop (15× `01 03 0c 00`, zero responses) instead of the 207-VS
  download. Root cause: **the wifi round's commit ded9cc0 (337+/471-
  rewrite of hw/mips/x1600.c) REMOVED the BT-side HCI responder code
  that 2550167 (patch 0123) added** — per-commit x1600bt/hci-responder
  content: 2550167=15 refs, ded9cc0=0, cd2127c=0, fd0d4c9=0. With no
  responder hci0 never registers, the player's embedded bluez client
  assert-loops, and the respawn flood starves the wizard (the v0.84
  freeze mechanism, back verbatim). Restoration: the BT diff
  (2550167^..2550167, 378 lines) applies CLEANLY onto the current HEAD
  (the wifi rewrite kept the surrounding context) — applied and
  rebuilt in the vendored tree; committed after verification. The
  exported patch tools/patches/qemu-x1600/0123-x1600-uart0-BT-side-
  HCI-responder-*.patch remains CORRECT — the vendored tree had
  drifted from it; this worktree re-converges them.

## v0.89 (2026-10-15, M3 tz round cont., worktree qemu-wizard-tz) — the
live trace: the tz row tap DELIVERS to evdev and is dropped INSIDE
litegui; the click handler + its registration table decoded; the freeze
is NOT the input chain and NOT the idle blank

- **Cycle tooling** (all in /tmp/kilo/tz/): tap.py (QMP abs tap + shot),
  drive2-6.py (render-wait + timed tap sequences inside the interactive
  window), shell.py (interactive guest shell over the console telnet —
  the respawn shell IS ttyS2, and the console capture needs the SAME
  port, so the shell client doubles as the capture: it logs everything
  it reads to shell.log). Screendumps x*/y*/z*/p1/q1 + w*. The
  interactive window is ~23-28 s from the picker render (the idle blank
  at t=84.14 s guest time, deterministic across boots); all wizard taps
  must land inside it — the scripted drives do language@+6 s,
  region@+10 s, tz-row@+13 s.
- **The QMP abs convention, SETTLED empirically (task item 2):**
  input-send-event abs values are 0..0x7fff fractions of the 480x800
  panel (16384,16282 → screen (240,398); 5284 → y=129). The RAW
  screen-pixel convention is WRONG and lands at the MIRRORED point:
  raw (240,398) → panel (3,9) → the model's 180° inversion → screen
  (477,791) — on the language page that is row 6 = **Français** (my
  drive2 x0 screendump caught the wizard re-rendering in French with
  the region list "France/Chine/Royaume-Uni/États-Unis" — the raw tap
  selected French, the follow-up normalized tap then hit
  Royaume-Uni, and the tz page showed "Londres GMT+00:00" — a full
  accidental end-to-end demonstration that the raw convention reaches
  the wrong row). Documented for the manager's harness: ALWAYS
  0..0x7fff.
- **The wizard flow (verified working end to end up to the tz page):**
  language picker (6 rows, English = row 3 at (240,398)) → tapping a
  row re-lays into the Region page (← Region; United Kingdom / United
  States / China / Japan at y≈146/270/397/522) → tapping China → the
  Time zone page (← Time zone; Beijing GMT+08:00 / Urumqi GMT+06:00,
  two-line rows at y≈70-207/210-340). The language pick persists
  (/usr/data/region = "lang=en") and the wizard restarts at the
  language page each boot. Screendumps: w0-w2, x0-x2, y1.
- **THE FREEZE, PINNED (this is the round's core result):**
  - the touch chain is ALIVE on the tz page: with the od reader armed
    on the tz page (drive6), the Beijing row tap delivers the full
    MT-A evdev stream to /dev/input/event1 (200 B od output: tracking
    id 0, pressure 0x3f, touch major 9, POSITION_X=0xf0=240 — the
    v0.79 signature); /proc/interrupts hyn_ts (GPIO 16) counts rise
    24→36 with I2C1 48→72 across a tz-page tap (drive5). NOT the
    input chain, NOT the blank (all probes pre-blank).
  - the player's litegui DROPS the tap: the tz-row click handler
    (decoded at 0x4d3740) never reaches its first store — the settings
    blob /usr/data/user.ini is byte-IDENTICAL before/after the tap
    (md5 + /tmp/u_before cmp: USERINI_SAME), /usr/data/localtime and
    /data/time_zone stay ABSENT (the applier never ran), and the
    console prints NOTHING at the tap. The BACK button on the tz page
    is equally dead (z3 vs z1: only the model-side cursor moved).
  - the tz click handler 0x4d3740 decoded: s0 = *(item+248) → +124
    (0x456be0 — the item's owner chain); a virtual call on *(s0+100)
    with *( *(s0+15212) + 464 ) → s1 (the selected zone string);
    0x499c40(s0) → s2; **set(130, s1)** (0x416ac0 — the zone id
    setting the applier 0x469be0 consumes); then *s2 == 0 → advance
    via 0x433de0(*(s0+216), s0), else 0x435cc0. The handler never
    runs its store → the drop is at/above the owner-chain gate, i.e.
    the tz listview's item widgets are not wired into the click
    dispatch.
  - the handler REGISTRATION is intact in the firmware data: the
    listview descriptor table (~110 entries of {path[0x10c],
    name[0x48], callback block}, stride 0x20c, file 0x3e7b00-0x3f5a1c)
    carries for BOTH pages symmetric callback blocks — region entry @
    0x874bc8 (click = 0x4d2640), time_zone entry @ 0x874dd4 (click =
    0x4d3740), same shared helpers at +0x104/+0x108/+0x14c/+0x150/
    +0x158/+0x160/+0x16c/+0x170. The stock data is NOT the gap.
  - the region-page click handler (0x4d2640, decoded) shares the same
    shape and WORKS: it strcmps the clicked text against setting 129,
    stores set(129, region) on change, then for multi-zone countries
    builds the default zone id via the tzlookup parser 0x4138c0 and
    set(130, default) — i.e. **setting 130 (the zone) is ALREADY
    STORED at the region tap for China (Asia/Shanghai default)** —
    the tz page's row tap is only the user's OVERRIDE. That also
    means the wizard's tz stage could be verified end-to-end even
    with the row tap parked IF the tz page could be bypassed (not
    possible without input).
  - the page creates: region = 0x4961e0(parent, "vg_listview_region",
    L"region"); tz = 0x4961e0(parent, "vg_listview_time_zone",
    L"time_zone") — both wide style names (0x410ee0 is a wide-string
    copy; the earlier 'style_custom' reading was the NEXT string in
    the pool, 0x784ac4 — corrected). The create return value is
    IGNORED at both sites; the page renders its rows from the generic
    list geometry (usr/resource/coordinate/list.ini — UTF-16 INI with
    name_text/name2_text fields = the two-line cell), which explains
    the rows rendering while the click wiring is missing.
  - the tz pages' .listview layout files (z:\layout\theme1\listview\
    vg_listview_zone_info/select_zone/time_zone/region.listview) are
    absent from the squashfs — but the SAME absence holds on the real
    device (same rootfs), and the region page (vg_listview_region,
    layout also missing) WORKS — so the missing layouts alone do not
    explain the tz page; the differential is inside 0x4961e0's
    name/style resolution for vg_listview_time_zone + L"time_zone"
    (the item-template scan loop over the 115-entry widget-name
    pattern table at 0x77bf68 is the next decode target). The real
    device completes this wizard (shipping product), so the gap is a
    VM-vs-device behavioral difference, not firmware data.
- **BT responder restoration (v0.88's regression fix) VERIFIED across
  5 fresh boots:** zero adapter.c assertions, the patchram download
  completes, bluetoothd powers the adapter (Powered: 1 -> 1 -> 0
  lifecycle visible on the console), bt_init reaches /tmp/bt_init_ok.
  The wizard's language/region stages run clean with the crash-loop
  gone. Vendored-tree commit to follow.
- **The wizard's tz-row handler decode side-note:** for the manager's
  harness, the tz page's rows sit at y≈70-207 (row 1) and y≈210-340
  (row 2) — the picker grid does NOT apply; row 1 center ≈ (240,129)
  → abs (16384,5284).

- **Round close-out (v0.89):** patch 0124 exported
  (tools/patches/qemu-x1600/0124-x1600-abs-axis-metadata-on-the-input-handler.patch;
  verified to apply cleanly onto main's vendored HEAD fd0d4c9);
  vendored commits 956210a (BT restoration) + dac477a (abs_info);
  gate PASS ×2 against the re-recorded boot-baseline-v0.89.txt (the
  recording must start from a PRISTINE image — the first record attempt
  captured a dirty-image window and failed the verify; sequence:
  regenerate → record → regenerate → verify). The gate normalize() now
  canonicalizes the two adjacent-swap print races so the window
  compares stably run-to-run. Worktree committed through c21ff9c.
  PARKED (the next tz decode round's target): why litegui drops the
  tz page's item clicks — decode 0x4961e0's item-template/style path
  for ("vg_listview_time_zone", L"time_zone") vs the working region
  pair; the handler chain, the registration table and the live event
  delivery are all verified good (v0.89 above), so the gap is exactly
  the create-time wiring between the named listview and its items.

## v0.89 (2026-10-15, vmstate round, worktree qemu-vmstate-snapshots) —
QEMU snapshots: VMStateDescription on every custom device — the
save/restore round-trip works end-to-end and second-scale iteration
starts here.

**The device-state snapshot layer (patch 0124).** The machine's custom
devices were the only unmigrated state: `migrate`/`loadvm` restored RAM
and the CPU but reset every custom MMIO block, so a resumed guest ran
with reset devices behind its live drivers (the DHD's staged control
response gone, the SFC page cache empty, the RTC/CGU back at seed,
GPIO pending bits cleared — the resume broke in every path that
touched them). Every custom device in hw/mips/x1600.c now carries a
VMStateDescription (version_id 1, minimum_version_id 1):

- **OST** (`x1600-ost`): regfile + `period` (the compare reload value)
  + the armed timer deadline (VMSTATE_TIMER_PTR; the free-running
  counter derives from QEMU_CLOCK_VIRTUAL, which the migration stream
  re-bases).
- **CGU** (`x1600-cgu`): the seeded/programmed regfile + the
  CE-trigger "written" bitmap (a self-cleared trigger offset reads 0
  — the bitmap decides).
- **MSC ×2** (`x1600-msc`, instance ids 0/1): the full SDIO-card
  surface — host regfile (STAT/IFLG/IMASK/DMAC), the staged RES byte
  window, CCCR/FBR + CIS chains, the fn1/fn2 windows, the staged CMD53
  data phase, the staged chip-side control response (fn2_rd FIFO +
  ctl_stage), the delayed PA08 re-kick timer, and the 32 KB backplane
  windows with their SBADDR keys. The backplane chunks moved from
  heap pointers to INLINE windows (`bp_windows[16][0x8000]`, claimed
  slots zero-filled exactly like the old g_malloc0 chunks, keyed by
  bp_keys[] with X1600_MSC_BP_FREE sentinels) so the state is
  snapshotable. post_load recomputes the IRQ level.
- **AIC** (`x1600-aic`): regfile + FIFO contents/levels + capture
  byte count + window-snapshot latch + the 1 ms drain timer. The
  capture FILE* stays runtime state (X1600_AIC_CAPTURE, re-opened by
  realize on the restore side; the capture file itself is external).
- **PDMA** (`x1600-pdma`): the persistent regfile + per-channel
  engine state (armed chains, IRQ-bit snapshots, the AIC PCM pump
  position and prev-window tracking).
- **INTC** (`x1600-intc`, QOM device — dc->vmsd): ISR/IMR banks;
  post_load re-drives the CPU line from (ISR & ~IMR).
- **RTC** (`x1600-rtc`): the write-protocol regfile (+0x3c key).
- **SADC** (`x1600-sadc`): regfile + the per-channel commanded
  samples (the VNC key ladder); post_load re-drives the IRQ.
- **GPIO** (`x1600-gpio`): bank regfiles (incl. the +0x700 staging
  window), model-driven pin levels, IRQ enable/mask/pending bits;
  post_load re-drives the four bank lines (a PA08 host-wake or touch
  INT held across the snapshot stays asserted).
- **I2C1 + cst8xx** (`x1600-i2c`): regfile, staged tx/rx buffers,
  slave-register latch, sleep-arm, touch position latch, INT level +
  the INT re-assert timer (created eagerly in x1600_mach_init so a
  restore side always has it; the lazy-create path is unchanged).
- **EFUSE** (`x1600-efuse`): trigger regfile + latched offset + the
  fuse array (CHIP_ID reads back identically).
- **LCD** (`x1600-lcd`): the jzfb regfile, the IRQ state and the
  backend_seen latch + the 25 Hz fb timer (created eagerly). The
  display surface, the host fb copy and the console are
  runtime-rebuildable — post_load leaves them and the next
  gfx_update/fb_draw recreates what a fresh process needs (the
  restored screendump is byte-identical, below).
- **SFC + SPI-NAND** (`x1600-sfc`): control window, CDT table, page
  cache + feature regs, PIO FIFO/transfer counters. The SPI-NAND
  array is EXTERNAL state: the mmap'd image file (nand-r1.bin next to
  the kernel) is shared by both sides — the restore's
  x1600_sfc_init re-mmaps the same path, so no file handle migrates
  and both sides see the same flash. post_load re-drives the IRQ.
- **Every stub regfile** (`x1600-stub`, TCU/USB-PHY/PWM/UART-ext/
  I2C0/2/uart1/uart3, sequence instance ids — creation order is
  machine-deterministic): zero-restore would have rewound the USB-PHY
  enable sequence and the PWM backlight level behind the running
  guest's back.
- The in-tree devices (serial-mm UARTs, the CPU, RAM blocks incl.
  TCSM0) already migrate through their own VMStateDescriptions.
- The touch-cursor overlay coordinates are cosmetic UI state (the
  next VNC pointer event refreshes them) and are not migrated.

**Verification.**
- **(a) The save/restore round-trip (migrate path — the machine has no
  qcow2, so HMP savevm is unavailable):** fresh VM (VNC + HMP + QMP
  sockets, `-no-reboot`), boot to the picker (the "lg_listview_create"
  console line, ~33 s wall on the idle host), `stop`, HMP
  `migrate file:...` (57 MB stream: 64 MB RAM heavily zero-compressed
  + device sections), `quit`, restart with `-incoming file:...`,
  `query-status` = paused (as saved), `cont`. Evidence
  (/tmp/kilo/vm/verify/): the pre-save screendump and the post-restore
  screendump are **byte-identical** (md5 adddbda1f969fa881a1be87f7429
  b494 both) — the picker renders exactly as saved — and a QMP tap at
  the English row (240,398: abs move + left press/release via
  input-send-event) **advanced the UI** (the post-tap screendump
  differs, the fb descriptor writes visible in the trail: the language
  re-render). The restore instance then quit cleanly.
- **(b) The boot gate — tools/x1600-boot-test.sh PASS** against the
  committed baseline (docs/traces/boot-baseline-v0.75.txt, re-recorded
  at v0.88), NO re-record: the full-cycle used-image run's window
  compared with **both diffs empty** (multiset + structural; evidence
  /tmp/kilo/vm/boot-gate-PASS/). The gate-tool fixes below were needed
  to make the committed baseline verifiable at all; the comparison
  semantics (message set + structural sequence) are unchanged — the
  vmstate changes are state-plumbing only and the guest-visible boot
  is unchanged.
- **(c) The fast-iteration recipe** is committed as
  tools/x1600-snapshot-vm.sh (save/resume/tap/dump/stop — the exact
  commands above wrapped for the manager loop; VNC :11 so the
  persistent hiby-live-demo VM on :0 is never touched).

**The gate-tool fixes (v0.88 baseline was unverifiable as committed).**
The v0.88 re-record captured a USED-image full-cycle window (userdata
already formatted → the "default file-system created" marker never
prints → the window runs to the 5-min power-save "reboot: System
halted"). The verify path required the marker (fresh image only) — a
verify run could not pass against it either way (fresh image: the
window cuts at 19.6 s and misses the baseline's tail; used image: the
completeness check failed). Fixes in tools/x1600-boot-test.sh:
`reboot: System halted` is accepted as the alternate terminal state
(the baseline's own end state), the timeout default rose 360→480 s to
cover the full cycle under load, the baseline-strip now skips only the
header (the old `grep -v '^#'` ate window lines that start with the
serial shell-prompt echo "# ", e.g. "# lg_system_main in"), and the
normalizer gained the volatile-value/variant classes a full-cycle
window needs (all behavior-neutral: the lg_textview_list heap pointer
— same class as the existing threadinfo/task/tls rules; the async
console-flush burst split points for "Starting /etc/init.d/" tokens
and "(SYS:D)/(GUI:D)/(MGR:E)" prints; shell-prompt "#" echoes;
trailing-space normalization; the per-image UBIFS volume UUID, the
per-boot BT_MACADDR and the mdev pidfile pid; and the drop list grew
by the UBIFS journal-recovery pair — they describe the PREVIOUS
shutdown's cleanliness, not this boot — plus the manager/GUI debug
chatter whose presence flips with scheduling (MGR:E platform actions,
the equalizer's EQ-read line), extending the existing timing-spam drop
list). The comparison semantics (message set + structural sequence)
are unchanged. With the fixes the committed baseline compares with
ZERO diffs against a same-shape run (verified offline on three
full-cycle windows AND live: the final gate run's diff-multiset and
diff-struct are both 0 bytes).

**The fresh-image caveat** (documented for the next rounds): the gate
marker only prints on a PRISTINE nand image (tools/x1600/
make_nand_image.py, md5 ae41e974e78aab2730774d05c9cbf37c); any boot
formats the userdata and later marker-cut windows are impossible. The
gate run this round used a used-image full cycle (one clean cycle-1
boot to the halt first) to match the committed baseline's shape.

**Known edge (not on the recipe's path):** saving mid-rcS while the
userdata journal is in heavy flight reproduced one UBIFS read-only
transition after restore (`ubifs_ro_mode: switched to read-only
mode, error -22` at a userdata inode read — the manager recipe saves
at the quiet picker instead). The idle-path restore (the verified
one) is clean. Parked as a mid-flight snapshot fidelity item.

**Pre-existing gap noticed while wiring the snapshot (not this
round's scope):** the merged source has NO uart0 BT-side HCI responder
— the commit that added it (2550167) is in the vendored history, but
the wifi control-chain commit (ded9cc0) rewrote hw/mips/x1600.c from a
pre-BT base and silently dropped it; the prebuilt binary matches the
merged source (no x1600-bt strings), so the merged state is
self-consistent — the boot shows the documented bluez crash-loop
(adapter.c assertion, the "Aborted" spam in any post-~50 s console
capture) and the wizard still reaches the picker. The 0123 BT patch
in tools/patches/qemu-x1600/ no longer applies to the current file.
Also absent from the merged model: the CS43131 codec and I2C0/2
slaves (plain stubs). Flagged so the manager can decide whether to
re-land the BT responder as its own round.

**Model state:** hw/mips/x1600.c carries the VMStateDescriptions
(committed in the vendored qemu; exported as 0124). The gate-tool
normalizer fixes are in tools/x1600-boot-test.sh. The recipe script
is tools/x1600-snapshot-vm.sh.
