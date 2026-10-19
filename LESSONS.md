# LESSONS

The loop's memory across context loss. One row per lesson:
`cue / lesson / evidence / confidence`. No evidence, no entry.
Appended by the goalmill driver; do not hand-edit past entries.

| cue | lesson | evidence | confidence |
|-----|--------|----------|------------|
| Goal worker dispatched into a fresh .goalmill worktree whose task region or inputs are gitignored artifacts (unpacked/, tools/vendors/) | Fresh git worktrees contain no gitignored artifacts, so the 'worktree is already prepared' setup note is false for such tasks; the fix that worked was running the task and gate from the main repo root (make_nand_image.py derives all paths from its own script location and ignores argv, always writing the checkout-that-owns-the-script-tree's unpacked/1.6/nand-r1.bin — from a worktree it would hit FileNotFoundError). Encode this as an always-hold rule so T2-T4 workers (which need unpacked/1.6/ inputs and the prebuilt tools/vendors/qemu/build/qemu-system-mipsel) run from the main repo root or pre-copy the artifact trees instead of rediscovering the gap. | .goalmill/logs/R1-worker-T1-1792385113256.log tool[0] in .goalmill/worktrees/T1: 'ls: cannot access 'unpacked/1.6/': No such file or directory'; same log tool[6] after switching to /home/matt/dev/hiby-r1-sdk: 'wrote /home/matt/dev/hiby-r1-sdk/unpacked/1.6/nand-r1.bin (138412032 bytes...) ... PRISTINE-OK' (GATE_EXIT=0); independent main-side re-run .goalmill/logs/R1-gate-T1-1792385122473.log: ok=True, exit=0, 'PRISTINE-OK'; .gitignore lists unpacked/, tools/vendors/, .cctmp/, .goalmill/ | high |
