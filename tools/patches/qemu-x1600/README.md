# qemu-x1600 patch series

Durable copy of the X1600E machine model developed in-tree in
`tools/vendors/qemu` (gitignored — large tree, ~500MB). Five patches on
top of upstream QEMU rev `615ece3`
(<https://gitlab.com/qemu-project/qemu.git>, master as of 2026-09).

The live copy (full git history + working tree) is `tools/vendors/qemu`;
this series exists so the emulator work survives losing that checkout.
Final tree verified identical (`git am` on a clean `615ece3` worktree).

## Rebuild `tools/vendors/qemu` from scratch

```
git clone https://gitlab.com/qemu-project/qemu.git tools/vendors/qemu
cd tools/vendors/qemu
git checkout 615ece3
git am ../../patches/qemu-x1600/*.patch
./configure --target-list=mipsel-softmmu
make -j$(nproc)          # binary: build/qemu-system-mipsel
```

## Regenerate the series

After new commits in `tools/vendors/qemu` (run from the SDK root, or
with an absolute `-o` path — `-o` resolves relative to the QEMU repo):

```
git -C tools/vendors/qemu format-patch 615ece3..master \
    -o "$PWD/tools/patches/qemu-x1600"
```
