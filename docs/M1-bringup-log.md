# M1 machine-skeleton bring-up log (QEMU X1600E)

Working tree: `tools/vendors/qemu` (built in-tree, `build/qemu-system-mipsel`).
New machine source: `hw/mips/x1600.c` (wired via `CONFIG_X1600` in
`hw/mips/meson.build` + `hw/mips/Kconfig`; FRESH `./configure` is required
after Kconfig edits — plain `ninja` does not re-evaluate Kconfig).

Status: **kernel boots through the head into the early firmware-args path and
stops at a reproducible kernel-side BUG_ON.** This file is the bring-up log.

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
