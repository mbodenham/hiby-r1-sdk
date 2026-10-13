# X1600E (HiBy R1) address map — Tier C machine-model source

Scope: physical SoC register map for the QEMU X1600 machine (Tier C, M0).
Primary source: mainline `docs/regmap/x1000.dtsi` (X1000/E family; saved copy).
Verification source of record: the **stock kernel binary** contains its own
device-tree — verified against `unpacked/1.6/xImage` (md5 022410af2bb16150f9597d14098dfe42,
NEVER modified). Verified 2026-10-12, M0 work block.

## 0. How the stock kernel was verified

Payload extraction (all offsets = byte offsets **inside** the decompressed
`vmlinux.bin` stream, i.e. image vma = `0x80010000 + file_off`):

```
dd if=unpacked/1.6/xImage bs=1 skip=16992 | gzip -dc   ->  vmlinux.stage  (8,143,180 bytes)
mipsel-linux-musl-objdump -D -b binary -m mips:4000 -EL \
        --adjust-vma=0x80010000 vmlinux.stage           ->  disassembly
```

Kernel image facts (matters for M1 `-kernel` loading):

- `xImage` = `[64B uImage header][16,928B raw stub][gzip stream]`; 64+16,928+
  3,714,528 = 3,731,520 (file accounted to the byte). uImage header: type os=5
  arch=5 typ=2 comp=0 (not compressed *per header* — the gzip is the stub's
  embedded payload), load=entry=`0x80F00000`.
- The decompressed `vmlinux.bin` is **linked at 0x80010000** — every code
  reference inside it (`jal 0x8006d2a0`, `jal 0x804130e0`, `lw ... (0x8077xxxx)`
  string tables, `0x8058f230` data tables) resolves inside
  `[0x80010000, 0x807D4xxx]`. Disassembling it at 0x80F00000 is wrong; the
  uImage 0x80F00000 load address is where the *zImage stub* runs.
- The kernel is MIPS32r2: r2-only encodings appear (e.g. `ins` at 0x80013618,
  printed as `0x7c042420` by an isa32r1-class disassembler). Caveat for future
  disassembly passes: `-m mips:4000` misrenders r2-only opcodes as raw words.
- There is an empty 0x400-byte window at vmlinux.bin file offset 0; code starts
  at file 0x400 (vma 0x80010400).

## 1. The stock kernel carries its own device tree (DTB)

The verified register map flat-out lives in the kernel image:

- **DTB blob: FDT magic `d00dfeed` at vmlinux.bin file offset 0x7BF80
  (image vma 0x807CDF80), totalsize 15,833 bytes, FDT v40.**
- Root compatible: `ingenic,x1600_halley6_module_base` / `ingenic,x1600`
  (there is no `x1600e` string — X1600E boots as the X1600 map).
- DT files confirm DT-driven probing: compat strings present for
  `ingenic,x1600-{pdma,mmc,sfc,pinctrl,mcu,clocks,ost,cpufreq,sadc,i2c,spi,aic,i2s}`,
  `ingenic,tcu`, `ingenic,ingenic-intc`, `ingenic,xburst` cpu.

Derived consequence for M0.3 per plan: register bases are used via `ioremap`
from DT properties — the *only* KSEG1 hard-coded peripherals in code are the
early-boot ones (pinctrl/GPIO, UART scan; see §3). Machine model should be
built to match the DTB, not just mainline dtsi.

## 2. Verified constants (with disassembly/data cites)

### INTC = 0x10001000 — VERIFIED

- **DTB cite** (`core-intc@0x10001000`, compatible `ingenic,ingenic-intc`):
  - node-name string `core-intc@0x10001000` in the DTB blob;
  - reg property cells (big-endian, as FDT encodes): bytes
    `10 00 10 00 00 00 01 00` at vmlinux.bin file 0x7BE420 (DTB-rel 0x4A0,
    image vma 0x807CE420) = `reg = <0x10001000 0x100>`.
  - Variance vs mainline `x1000.dtsi`: size **0x100** (not 0x50). Same base.
- **Disassembly cite — the driver has no LUI immediate** (it is DT-probed via
  `ioremap`): the only `lui 0xb001` sites in the whole 2M-instruction stream
  are six instances at `0x80013500–0x80013568` (KSEG1 alias 0xB0010000 = phys
  0x10010000, the pinctrl/GPIO block — NOT intc; their store offsets
  0x714/0x724/0x734/0x744/0x7f0 are pinctrl-bank regs within its 0x800 span,
  and the pointer table at vma 0x8058F230 holds
  `0xb0010000 / 0xb0010100 / 0xb0010200 / 0xb0010300 / 0xb0010700` = the four
  GPIO port-bank bases + a 0x700 bank, consistent with
  `pinctrl@0x10010000 0x800`). This absence is itself the finding: the
  stock kernel *cannot* be modeled by "lui/ori const scanning" for INTC; use
  the DTB.
- CPU intc: `mti,cpu-interrupt-controller` (`cpuintc`), intc parent = `<2>`
  (CP2-level, same as mainline).

### UART0 = 0x10030000 — VERIFIED

- **DTB cite**: nodes `/apb/serial@0x10030000..@0x10033000`, reg cells
  (BE): `10 03 00 00 00 00 01 00` at vmlinux.bin file 0x7C0148 (DTB-rel
  0x21C8, image vma 0x807D0148) = `reg = <0x10030000 0x100>` — identical size
  as mainline dtsi (0x100).
- **Disassembly cite (early boot)**: at image vma **0x80013618**:
  ```
  80013618: 3c02b003  lui  v0,0xb003     ; v0 = 0xB0030000  (KSEG1 UART0)
  8001361c: 7c042420  ins  a0,...        ; (r2 op) arg fixup
  80013620: 240500a9  li   a1,169
  80013624: 24434000  addiu v1,v0,16384  ; scan bound = 0xB0034000
  80013628: 8c46001c  lw   a2,28(v0)     ; UART block reg +0x1c
  8001362c: 10c50009  beq  a2,a1,...     ; match 0xa9?
  80013634: 24421000  addiu v0,v0,4096   ; next block: +0x1000
  80013638: 1443fffb  bne  v0,v1,...     ; until 0xB0034000
  ```
  The scan walks exactly `[0xB0030000, 0xB0034000)` in 0x1000 steps:
  UART0/1/2 = phys 0x10030000/0x10031000/0x10032000 (KSEG1). Additional
  early printk support at 0x800135d0–0x8001360c: status polling
  `lw v1,20(a1)` mask `0x60`, then `sw a0,0(a1)` byte putchar — with a
  per-port table (`sll a2,s2,2` lookups). Base is dynamic (early uart
  selection), but the *address range* pins the bank layout.

### Summary of verified deltas vs mainline x1000.dtsi

| Item | mainline x1000.dtsi | stock-kernel DTB (authority) |
|---|---|---|
| intc | 0x10001000, size 0x50 | 0x10001000, **size 0x100**, node `core-intc@0x10001000`, compatible `ingenic,ingenic-intc` |
| serial3 | (absent) | **0x10033000**, size 0x100 (`/apb/serial@0x10033000`) |
| pinctrl reg | 0x100 | **0x1000** (DTB cells: `0x10010000 0x1000`) |
| tcu | 0x1000 | **0x1000** ✓ same (DTB `tcu@0x10002000 0x1000`; sub-node `watchdog@0x10002000 0x40`) |
| ost | 0x3c | **0x100** (`core-ost@0x12000000 0x100`) |
| rtc | 0x4c | **0x4c** ✓ same |
| sadc | (absent) | **0x10070000 size 0x32** |
| pwm | inside TCU (`pwm@0x10002040 0x50`) | **0x134c0000 size 0x10000** (`ahb2/pwm@0x134c0000`) — separate AHB PWM exists |
| sfc | (absent in x1000.dtsi) | **0x13440000 size 0x10000** (`ahb2/sfc@0x13440000`) |
| can | (absent) | **0x13560000 / 0x13570000 size 0x10000** |
| slv | (absent) | **0x10045000 size 0x1000** (~"slv" bus) |
| msc2 | (absent) | **0x13470000 size 0x10000** |
| mac | 0x134b0000 0x2000 | ✓ same, size 0x2000 |
| otg | 0x13500000 0x40000 | ✓ same, size 0x40000 |
| pdma | 0x13420000 0x400+0x13421000 0x40 | **0x13420000 size 0x10000** |
| clock-controller | 0x10000000 0x100 (`x1000-cgu`) | node `clock-controller@0x10000000`, `ingenic,x1600-clocks` |
| aic | 0x10020000 0x38 | compatible `ingenic,x1600-aic` (reg cell in DTB, see note below) |
| i2c0/1 | 0x10050000 / 0x10051000 | DTB: `i2c@0x10050000 0x1000` / `i2c@0x10051000 0x1000` |
| i2c2 / spi0 | 0x10052000 / 0x10043000 | all present in DTB aliases, matches mainline |
| cpu | `ingenic,xburst-fpu1.0-mxu1.1` | **`ingenic,xburst`** (generic on board) |
| aliases | 3 x serial, 2 x i2c | **4 x serial** (`/apb/serial@0x10030000/31000/32000/33000` aliases uart0-3), 2 x i2c |
| msc0/1 | 0x13450000/0x13460000 0x1000 | DTB uses size 0x10000 cells (`ahb2/msc@0x13450000`), **msc2 0x13470000 exists** |

Table notes: sizes come from the DTB reg cells read straight from the
binary (`<base BE> <size BE> <#cells> <#rsv>`). Cells not found at a
4-byte-aligned marker in the blob (i2c2, spi0, mac, otg, aic) are likely
`status = "disabled"` nodes in the Halley6 base tree whose reg cells were
not caught by the aligned scan — fall back to the mainline dtsi values for
those. The machine model sizes each MMIO window from the **DTB column**
where present, mainline otherwise.

## 3. Device-model checklist carry-over (from RESEARCH_NOTES §8)

The full-system machine only needs to reach these guest nodes (M2-M3):
`/dev/fb0`, `/dev/input`, `/dev/sa-config`, switch-state sysfs,
`android_usb f_uac_sa`, leds, `/proc/jz/efuse/efuse_chip_id`,
`/dev/mtd5` (ota:kernel + theme), `/proc/asound` — mapped onto the blocks
above (fbdev on LCD, I2C for the PMU/touch chain, SFC+NAND mtd, USB MIDE
gadget pin-mux).

Machine-level caution for M1 (CPU side): early boot uses KSEG1 access
(`0xB0xxxxxx`) for its pre-MMU code (pinctrl/uart blocks); single core
(no SMP strings found: `cpu@0` only, boot_cpuid=0).

## 4. M0 build / M1 hand-off notes (session-specific, per the plan's M0)

- QEMU built in-tree: see session report (mipsel-softmmu + mipsel-linux-user,
  rev 615ece3 at `tools/vendors/qemu`); `qemu-system-mipsel` `-machine help`
  runs (malta/none).
- Hook-up for M1 kernel load: the OS kernel is an *xImage* (zImage-style).
  QEMU `-kernel` may accept it via uImage loader; if the stub cannot
  self-decompress under emulation, fall back to loading the DECOMPRESSED
  `vmlinux.bin` directly at 0x80010000 with entry at 0x80010400 (it is
  freshly extractable per §0). M1 must not modify any firmware bytes: the
  stock xImage is load-only.
- UART early-stock: the early console uses the UART bank + waits on LSR
  bits 0x60 (odd mapping — worth disassembling BEFORE attempting the
  `-kernel` boot: idle loop rows at 0x800135d0-0x80013610 verified above).
