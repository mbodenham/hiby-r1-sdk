# UBIFS mount bring-up log (HiBy R1 / Ingenic X1600E, QEMU model)

Round goal: `mount -t ubifs` must work end-to-end on the emulated SFC/NAND, then the
normal boot must mount `/usr/data` without `Invalid argument`, and the gate
(`tools/x1600-boot-test.sh`) must pass.

Scope: SFC/NAND/UBI-geometry only. Zero firmware modification. No speculative devices.
WiFi/MSC/SDIO regions belong to a sibling session — do not touch.

---

## v0.72 — 2026-10-14 (session continues an interrupted round; context restored from brief + diff)

### State inherited from the previous session (verified in the worktree diff, `git -C tools/vendors/qemu diff`)

Primary root cause + fix: the SFC model executed only the FIRST CDT entry per
START (`x1600_sfc_start`) and dropped the rest of the group. The X1600 SFC driver
fires CDT GROUP CHAINS: `WREN(0x06) -> PROGRAM LOAD(+desc data) -> PROGRAM EXECUTE(0x10)`
for programs and `WREN(0x06) -> BLOCK ERASE(0xd8)` for erases, walking the group with
the same row/col/descriptor setup. Every flash program/erase was therefore silently
lost — a fresh UBIFS could be created in RAM but never survive. The model now walks
the chain (guard-limited loop over CDT entries, chaining after 0x06/0x02/0x84/0x32/0x34;
0x13 PAGE READ carries its own descriptor data phase and standalone ops end the group).
Verified by the previous session: flash writes persist end-to-end.

Second fix: the DMA-out path (program load) read zeros for wbuf-path writes —
`sfc_get_paddr`/descriptor conversion fixed in `x1600_sfc_dma`.

Also in the diff:
- `x1600_sfc_exec`: ROW_ADDR (reg 0x84) now used for page read (0x13), block erase
  (0xd8, block-aligned), program execute (0x10); reg 0x88 is the GET/SET FEATURE
  feature-address operand. WREN (0x06) raises DONE (write latch not modelled; the
  chained load/erase follows).
- `x1600_sfc_dma` out-path: after copying program data into the page cache at `col`,
  the remainder of the cache is filled with 0xff (erased) so program writes don't
  bake in stale bytes from a previous page read.
- TEMPORARY diagnostic: bootargs contain `init=/bin/sh` (marked `/*TEMP-DIAG-UBIFS*/`,
  ~line 1919). The current prebuilt qemu binary boots to a guest shell because of it.
  MUST be reverted before the final commit.
- LEFTOVER TRACES (strip before commit): `SFC-T start`, `SFC-T exec`, `SFC-D walk`,
  `SFC-D out done` fprintf lines in `x1600_sfc_start` / `x1600_sfc_dma`.
- Untracked `build-old/` inside the qemu repo (stale build dir — keep out of commits).

### Current failure (unchanged, reproduced at 11:5x from /tmp/kilo/ubifs/console-last.txt + qemu-fix4.out)

Diag shell sequence: `ubiattach -m 6` (empty MTD, 260 PEBs, LEB 126976, VID @2048,
data @4096) -> `ubimkvol -N user_data -m` (236 LEBs) -> `mount -t ubifs ubi0_0 /tmp/data`:

    UBIFS (ubi0:0): default file-system created
    UBIFS error (ubi0:0 pid 541): check_lpt_type: invalid type (0) in LPT node type 2
    [<801ce6c4>] check_lpt_type.constprop.8+0x6c/0x84
    [<801d05ec>] ubifs_lpt_init+0x148/0x498
    [<801b8188>] ubifs_mount+0xd0c/0x18e4
    mount: mounting ubi0_0 on /tmp/data failed: Invalid argument

The FS creation (superblock/master/log/LPT write-out by `create_default_filesystem`)
succeeds — "ALMOST fully on flash" per the previous session — but LPT init reads a
node whose type byte is 0 (erased/stale) where type 2 is expected. Kernel 4.4.94.

### Instruments (reuse, do not recreate) — /tmp/kilo/ubifs/

- `ks.py` kallsyms decoder, `dis.py` disassembler, `xref.py`, `cdtparse.py`
- `flashdump2.py` flash-state decoder with the CORRECTED stride mapping:
  image = 1056 PEBs x 64 pages x 2112 B (data 2048 + OOB 64); PEB n page k data at
  `n*135168 + k*2112` (page 1 data is at image offset +2112, NOT +2048).
- `diag.py` guest-shell driver (bootargs `init=/bin/sh` + serial unix socket);
  traces `diag3/diag5/diag6` + `qemu-fix1..4.out` runs; `nand-r1.bin` snapshot
  (mtime 11:57:11) = flash state of the failed fix4 LPT mount.
- The model mmap's `nand-r1.bin` next to the qemu binary (x1600.c:1862) RW, so
  model-side writes land in the image file directly.

### Plan for this round

1. Decode what `ubifs_lpt_init`/`read_ltab`/`check_lpt_type` expect for the fresh-FS
   LPT area (kernel source if available in the SDK tree, else disassembly via ks.py).
2. Decode the LPT area from the nand-r1.bin snapshot; determine whether the type-2
   node is missing on flash (write path) or present but mis-served (read path).
3. Fix, then verify in order: (a) diag shell mount OK; (b) revert diag cmdline,
   full normal boot, /usr/data mounts, S21 completes; (c) /data/theme_id appears;
   (d) tools/x1600-boot-test.sh PASS (+ baseline re-record per v0.69 pattern if the
   dmesg window changed).
4. Commit: strip traces + revert diag cmdline, logical commits in the vendored qemu,
   export patches 0120(+0121), commit docs/tools on the branch. No push.

### v0.72 findings — flash/trace archaeology (before live rerun)

Run inventory (mtimes): diag1-5 = 11:23-11:35 (pre-fix model, no SFC-T traces).
fix1-4 = 11:49-11:57:51 (chain-fixed model + traces). `/tmp/kilo/ubifs/nand-r1.bin`
(last write 11:57:11) + `console-last.txt` (11:57:59) + `qemu-fix4.out` are ONE run:
boot -> ubiattach (EC 0/0 = virgin image) -> ubimkvol -> mount -> check_lpt_type fail.

Established facts:
- mtdparts: `2M(uboot),5M(kernel),40M(rootfs),5M(kernel2),40M(rootfs2),512K(ota),-(userdata)`
  -> userdata = image blocks 740..1023; chip = 1024 blocks; mtd6 PEB n = block 740+n
  (262 erases = attach sweep 740..999 linear + re-erase 740/741).
- Pristine image (`unpacked/1.6/nand-r1.bin`): userdata region all-0xff, no BBT, no UBI.
- Node type bytes in this guest kernel start at 1: SB=6 (len 4096), MST=7 (len 512),
  confirmed from flash. So LPT types are plausibly PN=1..LSAVE=6 (TBD from disasm);
  `check_lpt_type: invalid type (0) in LPT node type 2` reads a ZERO byte, i.e. data
  written as zeros or read from the wrong (virgin) place.
- The failing run's writes per trace: VTBL write = erase 740/741 + EC(p0, real, EC=2,
  persisted at 740/741) + VID(p1, real bytes) + 10/8 data pages whose DMA cache read
  as ZEROS (first=0000000000000000, descriptors mem=0x13ff000/0x13ff800 then
  0xa00000+ = wbuf/contiguous region). The SB write = EC+VID+node(p2)+padding(p3
  zeros, legit) at rows 0xCA00-03 = block 808 — but volume LEB 0 should be block 742.
  MST at 809/810, log/LPT at 811-813. So writes land at 740,741 (PEB 0/1, linear) and
  808+ (PEB>=2, +66 blocks). Reads at the tail hit rows 0xcac2 (blk 811), 0xc9c2
  (blk 807, cols 1209/1217 len 8+3), 0x554c/b, 0x556a/b.
- Final image: VIDs only at blocks 805-813; "user_data" VTBL (reserved_pebs=236, BE)
  at 805/806 p2 with VID lnum 0/1 at p1; EC=1 headers at 805-813; EC=2 at 740/741;
  VID/data at 740/741 p1+ MISSING (all 0xff); OOB areas all 0xff everywhere.
- VID field notes: version@4=1, then bytes 01 01 xx: user vols show vol_type=1
  (this kernel's UBI_VID_DYNAMIC is evidently 1, not 4), hdr_crc@56 = 0 and a small
  counter at @60-63 — VID layout of this UBI differs from upstream in tail fields;
  layout vol_id reads 0x7fffefff (not 0x7fffffff) on the 805/806 VIDs.
- flashdump2.py decodes with LEB-offset mapping (LEB off X -> page X/2048) which
  matched the observed layout (VID@p1 data area, node@p2).

## v0.72 round #3 — full trace/flash archaeology (BEFORE live rerun)

### The +65/+66 "BBT" theory is DEAD; the real mechanism is now mapped

Decoded from qemu-fix4.out (one run: pristine image → boot → diag shell → attach
→ mkvol → mount) + the final nand-r1.bin, correlated line-by-line:

- Probe: the ingenic driver's bad-block scan = 2 reads per block over ALL mtds
  (OOB 128B @ col 2048 + main 64B @ col 0). All 260 mtd6 blocks scanned, no gaps.
- `ubiattach`: EC-header reads (64B @ col 0) per PEB, then the whole flash was
  pristine → "empty MTD device detected", EC max/mean 0/0, **good PEBs: 260,
  bad PEBs: 0**. NO bad-block marking happened anywhere. The status polls
  (GET FEATURE 0xc0 after every erase/program, CDT idx 4) return the model's
  feature[0xc0] = 0x00 = OIP clear + no FAIL bits = what a real GD5F1GQ4 returns
  after a synchronous op — the "BBT from failed status polls" hypothesis is DEAD.
- Phase 1 (during attach): EC+VID+VTBL-data written to mtd6 PEB 0/1 (blocks
  740/741) — the attach's **empty-VTBL init**: record 0 = all zeros (empty
  volume table). The "VTBL data pages DMA as zeros" of round #2 was REAL DATA:
  an empty VTBL is mostly zero records. Not a DMA bug.
- Bgt EC-init sweep: erase + EC=1 header for PEB 2..259 (blocks 742..999),
  ascending, while PEB 0/1 are busy (layout volume).
- Phase 3 (mkvol + mount, interleaved with bgt):
  - mkvol `ubi_change_vtbl_record` rewrites the layout volume via leb_change to
    NEW PEBs: blocks 805/806 = UBI PEB 65/66, VID vol 0x7fffefff lnum 0/1, VTBL
    record 0 = user_data (reserved_pebs=236) + zero records. Old PEB 0/1 freed;
    bgt re-erases them → EC=2 (the erase+EC=2 interleave in the trace).
  - Then create_default_filesystem writes, in trace order: vol0 LEB6 (block 807,
    2048B from phys 0xa66000 = the "repeating 16-byte pattern"), vol0 LEB0 (block
    808, SB node sq1 from 0x81a000 + zero pad pg3), vol0 LEB1/2 (blocks 809/810,
    MST sq2 ×2), vol0 LEB10 (block 811, node sq4 type9 len48 + a second
    ch-header at off 48 sq0 type5 len28), vol0 LEB11 (block 812, node sq6
    **type 0** len160 + repeated 32-bit 0x2da45b5e), vol0 LEB3 (block 813, node
    sq7 type10 len32 + second ch sq0 type5 len28 with "c4070000").
- VID layout settled (this vendor UBI): magic@0-3 ("UBI!"), ver@4, vol_type@5,
  **vol_id = BE u32 @8, lnum = BE u32 @12**. All 260 PEBs EC=1 except 740/741
  (EC=2). LEB→PEB map at mount: LEB0→808, 1→809, 2→810, 3→813, 6→807, 10→811,
  11→812; layout 0/1→805/806. Allocation started at PEB 65 because PEBs 0-64
  were still held (layout + protection/pool) when the mount's first allocation
  happened; subsequent allocations ascend. **No bad-block skip anywhere.**
- Mount reads after last write: SB whole-LEB (808), MST whole-LEB (809, 810 —
  all 62 data pages each), then **LTAB read: block 811 (vol0 LEB10!) off 0 len
  0x30 (48) into 0x9a2200** → then 8B@col1209 + 3B@col1217 from block 807 pg2
  into 0x2114d000, then failure. check_lpt_type.constprop.8 (0x801ce658) unpacks
  4 bits (helper = ubifs_unpack_bits 0x801ce304) from **buf+2** (2-byte skip)
  and compares to a constprop'd **expected type 2**; got 0 → "invalid type (0)
  in LPT node type 2" → EINVAL. LSB-first nibble of byte 2 of the read buffer
  (0x10 from the IDX node's magic) = 0 ✓ matches the console error exactly.
- The failing read = the LTAB read (ubifs_lpt_init path A, a1!=0 branch:
  ubifs_leb_read(c, [c+0x8f8], buf, [c+0x8fc] len, chk) then check_lpt_type
  expected 2, then a loop unpacking 12B lprops into the [c+0x900] array — this
  is read_ltab). c+0x8f8 = ltab_lnum = **10**, c+0x8fc = ltab_sz = 48
  (= 24B ch + 2 × 12B lprops → lpt_lebs = 2 ✓ vendor LTAB is ch-wrapped).
- Path B (a1==0 branch) = read_lsave: expected type 3, unpacks 0x838(c)-bit
  lsave entries. ubifs_lpt_init+0x148 = the ltab check_lpt_type call site.
- ubifs_create_dflt_lpt (0x801cf0d8) does 5 ubifs_leb_change calls with
  lnum = $s5 incrementing; stores `sw $s5, 0x8f8(c)` (ltab_lnum) just before
  the LAST write and `sw $v0, 0x8fc(c)` (ltab_sz) before it.
- No fastmap in this kernel (no symbols). No MTD flash BBT ("Bbt0" absent from
  the entire image). bbt_* symbols are the standard MTD RAM-BBT machinery.

### Open contradiction to settle in the live run

The LTAB write per create_dflt_lpt went to lnum = s5 = 10 (the saved
ltab_lnum), but the ONLY 2048B LPT-looking write in the trace is the "repeating
pattern" at LEB6 (block 807) from phys 0xa66000 — and the node AT LEB10 (block
811) is an IDX-looking node (sq4 type9 len48, + a second ch-header at +48 with
sq0). Two candidates:
1. create_dflt_lpt's node→LEB assignment used wrong geometry (writes spilled to
   LEBs 10/11/3), or the ltab went to LEB6 while ltab_lnum was saved as 10.
2. The "repeating pattern" IS the bit-packed LPT data (decoded one 32-bit unit
   LSB-first as lprops {free=496 = leb_size/256, dirty, flags} — plausible!) but
   written to LEB6 while ltab_lnum = 10.
The 8B+3B reads at block 807 col 1209/1217 (the LAST 11 bytes of the pattern
region, nonzero span ends exactly at 1219) happen AFTER the failing ltab check,
from a different buffer (0x2114d000) — not yet attributed.

Live run plan: instrument the model to print the GET FEATURE status byte, the
first 32B of every program, and the first 16B served by every read; rerun the
diag sequence; correlate sqnums (1=SB, 2=MST, 4=?, 6=?, 7=?) and buffers with
the create_dflt_lpt disasm to pin which call wrote what where.

## v0.73 round #3 — LIVE DIAG + GUEST-RAM ARCHAEOLOGY (run4 series)

Setup: instrumented model build (SFC-P poll prints, 32B program dumps, SFC-R
read-serve dumps, guest-stack/c-struct probes), scratch moved to
/home/matt/kilo-ubifs/run4 (the /tmp tmpfs hit a per-user quota — sibling
sessions' scratch dirs pdma/dhd2/dhd/gci/livedisp fill it; do NOT delete those).
Boot is fast (~40 s to shell). Live diag = attach -m6, mkvol -m, mount ubi0_0:
**reproduces check_lpt_type EINVAL on the pristine image every run.**

### Instrumented-run results (the smoking guns)

1. **Status polls exonerated for real**: 2773 GET FEATURE polls, ALL return
   0x00 (one 0xb0 read). No bad-block marking anywhere; UBI: 260 good, 0 bad.
   The v0.72 status-poll theory is dead.
2. **The failing read is NOT the 48-byte one.** The 48B col-0 read at block 811
   (row 0xcac2) is served faithfully by the model ("31181006866d68ea..." = the
   sq4/IDX-ish node). The REAL failing read = the **8B@col 0x4b9 + 3B@col 0x4c1
   pair at block 807 pg2** (row 0xc9c2) = **an 11-byte read at LEB6 offset
   1209**. That is read_ltab: c→{+0x8f8: ltab_lnum=6, +0x8fc: ltab_offs=0x4b9,
   +0x844: ltab_sz=0xb} — confirmed by dumping the guest's ubifs_info through
   the model (stack-walk probes; c=0x813c1480-ish region, fields verified at
   BOTH the write and read moments: [5a4]=2 (lpt_lebs), [844]=0xb, [8f8]=6,
   [8fc]=0x4b9).
3. **ubifs_lpt_init+0x148 = check_lpt_type after that 11B read.** The check
   unpacks 4 bits MSB-first from buf+2 (2-byte skip). The model served the
   flash bytes exactly ("adf602809e6700007c0000"); s2[2]=0x02 → MSB nibble = 0
   → "invalid type (0) in LPT node type 2" — the console error, byte-exact.
4. **ubifs_pack_ltab (0x801cec8c) packs type=2 FIRST at pos 0** (upstream LPT
   format: [type 4b][lprops...][crc16 last]; pack_bits(c, buf, pos, value,
   nbits) = MSB-first; spc_bits at c+0x830). So a correct LTAB = 0x2X 0x80 0x00
   ... shape. **The written page contains NO such bytes anywhere** (scanned).
5. **The LEB6 write = ONE 2048-byte program from guest RAM 0xa66000** whose
   content = a repeating 16-byte unit of 32-bit lprops values with
   free=496=126976/256 (fresh full-LEB lprops) = **the packed PNODE data** —
   plus a 67-byte tail. The LTAB (11B) is nowhere in the page.
6. create_dflt_lpt's flow at the LTAB write (disasm): set_ltab(c,6,...);
   `sw s5,0x8f8(c)` (ltab_lnum=6); pack_ltab(c, s6, ltab) with **s6=s1**
   (reassigned `move s6, s1` right before); memset(s6+ltab_sz, 0xff, s7);
   ubifs_leb_change(c, 6, s1, s4) — i.e. the LTAB (11B) + 0xFF pad ARE packed
   into s1[0..] and a SECOND full write of LEB6 is called for. **That second
   write never reaches the SFC** — the complete run4 program list for the
   whole boot is: [740,741 sweep-EC] [742..999 sweep] [805,806 VTBL] [807 =
   the pnode-pattern page] [808 SB+pad] [809,810 MST] [811,812,813 one page
   each (the sq4/sq6/sq7 nodes = idx-area/log-area writes of the mount)].
   No second LEB6 program exists in the trace, and no EC/VID changes either.
7. The UBI VID at block 807 says (vol 0, lnum 6) — consistent with the FIRST
   (pnodes) write only.

### Where round #3 stops (handoff state)

The failure = the mount's LTAB read returns the stale pnode pattern instead of
the packed LTAB because **the second LEB6 write issued by create_dflt_lpt
(ubifs_leb_change(c, 6, s1, s4), the LTAB+pad page) is silently never issued
to the SFC** while the create still reports success. The skip happens between
the guest's ubifs_leb_change call and the driver — the prime suspect is the
vendor UBI's own write path (ubi_eba_leb_change 0x80310bdc and its callees
0x8030f814/0x8030fe74/0x8030f5c4/0x8030f798/0x8030f5f8, disassembled under
/home/matt/kilo-ubifs/dis/) — e.g. a wbuf-style "behind the flushed offset"
drop, since 0xa66000 looks like a page-sized UBI staging buffer that still
held the pnode pattern when the LTAB write should have re-staged it. Whether
that skip is model-triggered (vs. benign on real HW, where the userdata
volume is factory-formatted and this fresh-create path may never run) is THE
open question for round #4. Note the type@20=9/0/10 nodes at blocks 811/812/
813 are the mount's own post-create writes (idx-area/log-area), NOT the LPT.

Next concrete steps for round #4:
1. Disassemble 0x8030f5f8 (the UBI's mtd_write wrapper) and its wbuf/offset
   logic; find the condition under which a leb_change's data write is skipped
   or served from a stale page buffer (compare with 0x8030f798/0x8030f5c4).
2. Decide fix level: if the skip is a vendor UBI/kernel bug in the
   fresh-create path (plausible — real devices factory-format userdata and
   never run create_default_filesystem), the model-side options are (a) make
   the model tolerate/deliver whatever the guest's wbuf logic expects, or
   (b) revisit whether any earlier model behavior (erase timing? program
   result? read latency?) steers the guest into the skipping branch.
3. The diag instruments in x1600.c are marked TEMP-UBIFS-DIAG and must be
   stripped before any commit.

## v0.74 round #4 — decode: the round-3 pinned state was wrong on all three legs

Round-3's handoff said: (1) the LTAB is a SECOND write of LEB6 that never
reaches the SFC, (2) check_lpt_type unpacks 4 bits MSB-first from buf+2 so the
served byte 0x02 yields type 0, (3) the skip lives in the UBI lock/prep helpers.
All three fell on re-decode:

1. **No second write exists.** ubifs_create_dflt_lpt (0x801cf0d8, full decode
   in /tmp/kilo/ubifs/create_dflt_lpt.dis) packs pnodes, nnodes (and lsave,
   only when the 5th arg *orph_lebs != 0 — it is 0 here) into one bitstream at
   s1 with the running position s6; the LTAB is packed INTO THE SAME LEB
   buffer: set_ltab(c, s5, ...) → ltab_lnum=ltab_offs save (0x8f8/0x8fc) →
   pack_ltab(c, s6, ltab) (0x801cf91c) → memset(s6+ltab_sz, 0xff, pad) → ONE
   ubifs_leb_change(c, s5, s1, aligned_len) at 0x801cf944. The single observed
   LEB6 program (2048 B, guest RAM 0xa66000) IS that write.

2. **The LTAB is on flash.** run4/nand-r1.bin block 807 data page: non-ff span
   0..1219 = pnodes (0..1208) + an 11-byte blob at 1209..1219
   (ad f6 02 80 9e 67 00 00 7c 00 00) + 0xff pad. ltab_lnum=6, ltab_offs=0x4b9,
   ltab_sz=0xb match exactly.

3. **pack/unpack are consistent (upstream-identical).** Fetched upstream 4.4
   lpt.c (jsdelivr mirror): pack_bits merges (val & 0xff) << pos and shifts
   val right by (8-pos) per byte; unpack_bits assembles the window
   little-endian and keeps the low nrbits — both LSB-first-per-field, both
   byte-MSB-downward streams. ubifs_pack_ltab (0x801cec8c) = crc16 at
   buf[0..1] (LE bytes) + type=2 (4 bits at buf+2 low nibble!) + free/dirty
   x2 at 17 bits each ([0x830]) = 88 bits = 11 B. The served bytes decode
   type = 0x02 & 0xf = **2** — the check should PASS. Round 3's "MSB-first"
   reading was wrong.

4. **Therefore the guest's buffer did not contain the flash bytes** — the
   loss is in the READ path. The failing read = 11 bytes at LEB offset 1209 —
   the FIRST non-page-aligned, non-4-multiple-length read of the whole boot.
   ingenic_sfcnand_read (0x804094d8) splits it: chunk=11, col%4!=0 →
   s6 = round_up(chunk,4)-4 = 8 (the 4-aligned prefix, DMA) + a 3-byte tail
   read with the DMA bit (regs[0] & 0x40) CLEARED (PIO).

5. **The 8-byte DMA's descriptor mem is not a physical address.** Trace: desc
   mem = 0x2114d000 / 0x21176000 / 0x221d8000 (varies per boot) — all in the
   0x20000000 uncached window; guest RAM is 64 MB. The model wrote the served
   bytes there as raw phys → unmapped → dropped. Guest-side probes (SFC-C2/C3
   TEMP instruments, live through the model): the UBIFS-level LTAB buffer
   (read_ltab's vmalloc buf) = VA 0xc0136000, the guest's own TLB translation
   = phys 0xa7d000-0xa84000 (0-based; the platform has no +0x20000000 DDR
   bias — pack/unpack and the TLB agree). The driver's sfc_get_paddr
   (0x80408158) is the identity for everything below 0xBFFFD000 (its FAST
   path's delay slot adds the zeroed comparison result) and falls into
   vmalloc_to_pfn only for kseg2/3 — where the walk is broken for live
   mappings (swapper_pg_dir[0x30] = 0x808e1000 empty marker while the buffer
   is mapped; fold global [0x808fc314] = 0x808fc100). But the unaligned path
   never hits that: the MTD read buffer handed down is a **dma_alloc_coherent
   bounce buffer in the 0x20000000 uncached window**, and get_paddr passes it
   through verbatim. On the real board the SFC's DMA master resolves that
   window to DRAM (mem - 0x20000000) — the same property the descriptor-BASE
   register normalization (v0.72) already relies on. The model treated it as
   raw phys and dropped the write.

## v0.75 round #4 — fix + verification (mount works)

Two model-side fixes in hw/mips/x1600.c:

1. **Descriptor data-address window normalization** (x1600_sfc_dma): desc mem
   in [0x20000000, 0x40000000) → mem - 0x20000000, matching the descriptor
   base register rule. The 8-byte LTAB prefix now lands in the bounce buffer.
2. **PAGE READ PIO data phase** (x1600_sfc_exec, !DMA branch): load the RX
   FIFO with cache[col..col+len) (len = regs[0x2c], the same handshake as GET
   FEATURE: fifo_load raises SFC_ST_RX, the driver pops, done>=total raises
   DONE) instead of only raising DONE. This delivers the 3-byte unaligned
   tail the driver PIO-reads; without it check_lpt_crc fails after fix 1
   (the LTAB CRC *is* checked — check_lpt_crc+0x9c in ubifs_lpt_init+0x210).

Verification:
- (a) diag shell (init=/bin/sh): ubiattach -m 6, ubimkvol -m, mount
  ubi0_0 → **MOUNT-RC=0**, "UBIFS: mounted UBI device 0, volume 0, name
  user_data", full geometry, "small LPT model".
- (b) full boot with the diag cmdline reverted: ubi1 attached mtd6 (32 MiB),
  default file-system created, **mounted UBI device 1, volume 0 "user_data"**
  at 56.8 s — no check_lpt error, no Invalid argument, no flash_erase retry.
  The DHD/bt insmod oopses (Oops #1-#7, Comm insmod/bt_init) are the known
  module region (sibling's wifi round), unchanged.
- (c) second boot over the persisted FS: /data/ holds radio.db, radio.txt,
  **theme_id** ("theme:1"+pad), user.ini, usrlocal_media.db, dmr_streamer;
  the lg_dlna spam changed (lg_activity_mng running, airplay callbacks,
  event_input, INPUT ADD/REMOVE).
- (d) gate: pending — merged main (v0.71: two-serial gate, baseline renamed),
  re-recording the baseline as v0.74 next.

Round-3 corrections to carry forward: the LTAB CRC is checked
(check_lpt_crc); the fresh-create path runs on every empty-userdata boot and
is therefore REACHABLE on real devices (the factory image is all-0xff), so
the real chip demonstrably serves both the unaligned DMA descriptor window
and the PIO tail read.

## v0.76 round #4 — gate + commit state

- (d) gate: `tools/x1600-boot-test.sh` (main's v0.71 version, merged; default
  baseline now boot-baseline-v0.74.txt) → **PASS** ("boot window matches
  baseline (332 distinct messages, 154 structural lines; boot stopped at the
  rcS stall marker)"). Baseline re-recorded as docs/traces/
  boot-baseline-v0.74.txt. Known flake: the ttyS2 console backend can merge
  two printk bursts into one line (observed once: "create proc entry lcd_reg
  successFinish display..."); a gate re-run reproduces the baseline — this
  is a capture race, not a boot change.
- Vendored qemu: two logical commits on the worktree's nested repo —
  ca29cd6 (SFC CDT-group walk + program/erase row fix + descriptor
  diagnostics) and ad53dfb (SFC DMA descriptor window + PAGE READ PIO data
  phase); exported as tools/patches/qemu-x1600/0120-*.patch and 0121-*.patch
  (anchors verified against main's pristine x1600.c: the old
  `s->regs[0x84/4]`/`addr` row sources, no `case 0x06`, no SFC prints).
- TEMP-UBIFS-DIAG instruments stripped (the SFC-C2/C3 probe block, the
  SFC-D norm print, the SFC-FIFO pop print reverted to LOG_UNIMP); the diag
  `init=/bin/sh` bootargs reverted before the gate run.
