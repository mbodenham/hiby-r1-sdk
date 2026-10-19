# AGENTS.md — hiby-r1-sdk

Rules that must always hold for any agent working in this repo.

## Gitignored artifacts do not exist in fresh worktrees

`unpacked/`, `tools/vendors/`, `.cctmp/`, `.goalmill/` are gitignored
(.gitignore), so a fresh `git worktree` (e.g. `.goalmill/worktrees/<task>`)
contains none of them even though the harness setup note says it is
"already prepared". If a task's inputs or deliverable are gitignored
artifacts (e.g. `unpacked/1.6/nand-r1.bin`, prebuilt
`tools/vendors/qemu/build/qemu-system-mipsel`):

- Run the task and its gate from the main repo root
  (`/home/matt/dev/hiby-r1-sdk`), or first copy the needed trees into the
  worktree: `cp -a /home/matt/dev/hiby-r1-sdk/unpacked unpacked` and
  `cp -a /home/matt/dev/hiby-r1-sdk/tools/vendors tools/vendors` (774 MB,
  includes the prebuilt qemu binary).
- `tools/x1600/make_nand_image.py` ignores argv: it derives every path from
  its own script location and always reads `unpacked/1.6/{xImage,
  rootfs.squashfs}` and writes `unpacked/1.6/nand-r1.bin` relative to the
  checkout containing the script tree. The CLI args are documentation only.
  Run from the main repo root it writes the main repo's image; run from a
  worktree copy it targets that worktree's missing `unpacked/1.6/`
  (FileNotFoundError) — so always run it from the main repo root.

## Pristine nand image

- Pristine `unpacked/1.6/nand-r1.bin` md5 is
  `ae41e974e78aab2730774d05c9cbf37c` (138412032 bytes), deterministic from
  the stock v1.6 inputs (xImage `022410af...`, rootfs.squashfs `9c8b3a94...`).
- Any QEMU boot dirties the image; a gate that needs the fresh-volume
  first-boot wizard state must regenerate the image immediately before that
  boot. If the md5 mismatches, never hand-patch: verify the inputs are
  unmodified stock artifacts and re-run once; if it still mismatches,
  report the actual md5 plus a cmp/size breakdown.
