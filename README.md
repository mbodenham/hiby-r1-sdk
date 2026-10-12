# hiby-r1-sdk

Developer toolkit for building custom firmware for the **HiBy R1** portable
music player. The HiBy R1 is end-of-life upstream — this toolkit exists so
firmware work can continue without round-tripping every change onto a
physical device.

The toolkit is hardware-agnostic to the extent possible: firmware images are
unpacked, modified, and rebuilt on a Linux host; QEMU full-system emulation
of the Ingenic X1600E provides a near-hardware loop for iterating on the
stock kernel and rootfs.

## Status

Working firmware: **stock v1.6** (`1.6/r1.upt`). See
[`docs/RESEARCH_NOTES.md`](docs/RESEARCH_NOTES.md) for verified facts about
the image format and OS internals, and
[`docs/PLAN-TierC.md`](docs/PLAN-TierC.md) for the emulation bring-up.

The output firmware will live in a separate repo.

## Layout

```
1.6/                              stock v1.6 .upt (input only, reproducible)
specs.md                          device + chip specs (from hiby.com)
X1600_E+Data+Sheet.pdf            Ingenic X1600E datasheet
docs/
  RESEARCH_NOTES.md               RE notes on the firmware format and OS
  PLAN-TierC.md                   QEMU X1600 bring-up plan and status
  M1-bringup-log.md               M1 boot trace analysis
  x1600-regmap.md                 verified register map
  regmap/                         DTB sources
  traces/                         strace / boot traces
tools/
  unpack.sh                       .upt -> xImage + rootfs.squashfs + tree
  repack.sh                       tree -> .upt (hash-chained, ISO 9660)
  r1-sandbox.sh                   unprivileged userns + bind-mount sandbox
  proot-run.sh                    proot-based rootfs runner
  qrun.sh                         qemu-user runner for a single binary
  fb-viewer.py                    watch /dev/fb0 from the sandbox
  shim/                           MIPS32r2 LD_PRELOAD shim source
  tierc/                          cross-compile smoke test (hello.mipsel)
  vendors/                        cross toolchains (gitignored)
```

## Typical workflow

```
1.6/r1.upt  --[ tools/unpack.sh ]-->  unpacked/<version>/
                                       ├── xImage
                                       ├── rootfs.squashfs
                                       └── squashfs-root/

(modify squashfs-root/, kernel, or config in place)
                                       ↓
                tools/repack.sh  ────>  out.upt
                                       ↓
            (optionally) test in QEMU before flashing to a real R1
```

## Cross-compile toolchain

A static `mipsel-linux-musl-` toolchain is expected under
`tools/vendors/mipsel-linux-musl-cross/`. The smoke test in
[`tools/tierc/`](tools/tierc/) confirms the toolchain produces
`mips32r2` ELF binaries compatible with the runtime in `tools/shim/`.

## Emulation

QEMU support for the X1600 is being built **in-tree** here, not as an
upstream QEMU patch. See [`docs/PLAN-TierC.md`](docs/PLAN-TierC.md) for the
milestone breakdown and current status. Goal: boot the unmodified stock
firmware to the first player UI frame as the regression gate for firmware
changes.

## Reference

The [bidhata/Hiby-R1-Mod](https://github.com/bidhata/Hiby-R1-Mod) project
is a separate community mod; it is referenced here only for learning. This
repo is not a fork and shares no code with it.
