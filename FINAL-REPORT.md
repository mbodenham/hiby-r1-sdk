# FINAL REPORT - Boot the stock v0.93 firmware in QEMU until the first player UI frame appears; prove it with the captured boot log

# Final Report — Boot stock firmware in QEMU to the first player UI frame

**Date:** 2026-10-19 · **Repo:** `/home/matt/dev/hiby-r1-sdk` (HiBy R1 / Ingenic X1600E firmware toolkit) · **HEAD at close:** `a01183b` · **Termination:** final gate exited 0 on round 2 of max 12 (stall streak 0/3)

## Goal

> Boot the stock v0.93 firmware in QEMU until the first player UI frame appears; prove it with the captured boot log

Per the goal interview, "v0.93" is the internal M1-bringup-log round number for the QEMU machine-model state — no v0.93 firmware exists in the repo. The firmware actually booted is **stock v1.6** (`1.6/r1.upt` → `unpacked/1.6/`) on the vendored QEMU `x1600` model at the v0.93-round state (HEAD `38897b1` at goal definition = patch 0130 wake chain, BT responder `chardev-x1600bt` present). "The first player UI frame" = the **first-boot language-selection page** on a freshly regenerated pristine nand image (the fresh UBIFS volume carries the first-boot wizard state only on a pristine image). "Prove it with the captured boot log" = captured serial boot log + QMP screendump PNG of the lit frame.

## Verification — final gate

Command:

```
tools/x1600-ui-gate.sh --out /tmp/kilo/ui-gate-final && test -s /tmp/kilo/ui-gate-final/console.log && test -s /tmp/kilo/ui-gate-final/first-frame.png && echo GOAL-EVIDENCE-OK
```

Result: **exit 0, matched `GOAL-EVIDENCE-OK`** (duration 84.1 s; log `.goalmill/logs/R2-gate-final-1792386202390.log`). Full output:

```
x1600-ui-gate: [boot-regen] regenerating pristine nand image
x1600-ui-gate: [boot-regen] pristine nand md5 OK (ae41e974e78aab2730774d05c9cbf37c)
x1600-ui-gate: [boot-window] running tools/x1600-boot-test.sh
x1600-ui-gate: [boot-window] PASS: boot window matches baseline (296 distinct messages, 158 structural lines; boot stopped at the rcS stall marker)
x1600-ui-gate: [ui-regen] regenerating pristine nand image
x1600-ui-gate: [ui-regen] pristine nand md5 OK (ae41e974e78aab2730774d05c9cbf37c)
x1600-ui-gate: [ui-boot] starting qemu (serial0 -> /tmp/kilo/ui-gate-final/console.log)
x1600-ui-gate: [ui-boot] marker "lg_guimain:" seen (~26s)
x1600-ui-gate: [ui-boot] marker "running activity" seen (~26s)
x1600-ui-gate: [ui-boot] markers OK; capturing after 15s grace
x1600-ui-gate: QMP screendump png refused ({"class": "GenericError", "desc": "Enable PNG support with libpng for screendump"}); capturing ppm and encoding png with stdlib
screendump: /tmp/kilo/ui-gate-final/first-frame.png (ppm 480x800 -> png, stdlib encode)
x1600-ui-gate: [screendump] /tmp/kilo/ui-gate-final/first-frame.png written
PIX: 480x800 8-bit RGB mean=243.81 std=19.13 dark=4698 title+6 rows stroked, 7 gaps flat
x1600-ui-gate: [pixel-check] OK
PASS: x1600-ui-gate — boot-window diff PASS (tools/x1600-boot-test.sh), serial capture OK (lg_guimain + running activity, 15s grace), first-frame.png pixel check OK (480x800 lit picker)
GOAL-EVIDENCE-OK
```

Evidence pair on disk (verified after the run):
- `/tmp/kilo/ui-gate-final/console.log` — 30,868 bytes captured serial boot log; contains the GUI-start markers `(GUI:D)lg_guimain: lg_topbar_init` / `lg_activity_mng_init` / `lg_ial_init` and `(GUI:D)lg_activity_mng: running activity lg_activity_main`
- `/tmp/kilo/ui-gate-final/first-frame.png` — 12,961 bytes, verified 480x800 (independent `struct` header read), lit picker frame

## Tasks and gate evidence

**T1 — pristine nand image regeneration: DONE (1 attempt).** Regenerated `unpacked/1.6/nand-r1.bin` from `unpacked/1.6/xImage` + `unpacked/1.6/rootfs.squashfs`, replacing the dirty `f9a0a5df...` image. Gate:

```
python3 tools/x1600/make_nand_image.py unpacked/1.6/nand-r1.bin unpacked/1.6/xImage unpacked/1.6/rootfs.squashfs && printf 'ae41e974e78aab2730774d05c9cbf37c  unpacked/1.6/nand-r1.bin\n' | md5sum -c - && echo PRISTINE-OK
```

Passing output (gate notes): `... xImage -> 0x02f00000 (3731520 bytes) rootfs.squashfs -> 0x03400000 (37507072 bytes) partition table -> 0x00005800 (7 entries) wrote /home/matt/dev/hiby-r1-sdk/unpacked/1.6/nand-r1.bin (138412032 bytes, 65536 pages x 2112 B) unpacked/1.6/nand-r1.bin: OK PRISTINE-OK` — GATE_EXIT=0. Every subsequent gate boot re-proves this: the final gate's own `[boot-regen]`/`[ui-regen]` steps printed `pristine nand md5 OK (ae41e974e78aab2730774d05c9cbf37c)` twice.

**T2 — `tools/x1600-ui-gate.sh`: DONE (1 attempt).** Standalone executable (557 lines, `sh -n` clean, `--out DIR`, default `/tmp/kilo/ui-gate`), embedding the full run recipe: pristine regen → boot-window diff via `tools/x1600-boot-test.sh` → second pristine regen → QEMU `-M x1600` boot with QMP unix socket + serial chardev logfile → GUI-start marker wait + grace → QMP screendump (png with ppm fallback + pure-stdlib PNG encode) → pure-stdlib pixel check (struct+zlib, no PIL) of 480x800 / lit mean / nonzero variance / picker band structure. Gate:

```
sh -n tools/x1600-ui-gate.sh && test -x tools/x1600-ui-gate.sh && grep -q x1600-boot-test.sh tools/x1600-ui-gate.sh && grep -q screendump tools/x1600-ui-gate.sh && grep -q 480x800 tools/x1600-ui-gate.sh && echo UI-GATE-SCRIPT-OK
```

Passing output: `UI-GATE-SCRIPT-OK`. During T2 the script also passed a full functional run into `/tmp/kilo/ui-gate-t2-verify` (`screendump: /tmp/kilo/ui-gate-t2-verify/first-frame.png (ppm 480x800 -> png, stdlib encode)` + `first-frame.png pixel check OK (480x800 lit picker)`).

**T3 — first evidence run into `/tmp/kilo/ui-gate`: PENDING (0 attempts).** Not executed as scoped. The terminal final-gate run performed the identical flow into the distinct dir `/tmp/kilo/ui-gate-final` and left the same evidence pair (`console.log` + `first-frame.png`), but the `/tmp/kilo/ui-gate` directory does not exist and the `UI-GATE-PASS` gate was never run.

**T4 — reproducibility re-run into `/tmp/kilo/ui-gate-run2`: PENDING (0 attempts).** Not executed as scoped; `REPRO-PASS` gate never run. Two independent full end-to-end PASS runs do exist on distinct `--out` dirs (T2's `/tmp/kilo/ui-gate-t2-verify` verify run and the final gate's `/tmp/kilo/ui-gate-final` run, both with their own boot log + frame PNG pair), which de facto demonstrates repeatability — but the named repro artifact directory and its gate were not produced.

**T5 — `docs/PLAN.md` evidence entry: PENDING (0 attempts).** Not executed; `DOC-EVIDENCE-OK` gate never run. `docs/PLAN.md` contains no `x1600-ui-gate.sh` reference.

## Work merged

Commits added by this goal (on top of the v0.93-round baseline `38897b1`):

- `72b30e7` — `goalmill: goal defined - 5 gated tasks (round 0 baseline)`
- `08cad55` — `goalmill: round 1 - dispatched T1 -> T1 done (gate ok)`
- `5baa7f8` — `tools: x1600-ui-gate.sh — full first-boot UI gate; pristine nand regen + md5 before each boot phase, tools/x1...` (the T2 deliverable)
- `11c71e0` — `goalmill: integrate T2 (round 2)`
- `a01183b` — `goalmill: round 2 - dispatched T2 -> T2 done (gate ok)`

Diff over the last three commits: `GOAL.md | 8 +-`, `LESSONS.md | 12 ++`, `tools/x1600-ui-gate.sh | 557 ++++` — 3 files changed, 574 insertions(+), 3 deletions(-). No vendored-QEMU changes this goal; `tools/vendors/qemu/build/qemu-system-mipsel` is unchanged prebuilt. T1's deliverable is the gitignored binary `unpacked/1.6/nand-r1.bin` (138,412,032 bytes, pristine md5 `ae41e974e78aab2730774d05c9cbf37c`) — intentionally not committed, and regenerated from stock inputs by every gate run.

## Lessons learned (from `LESSONS.md`)

1. **Gitignored artifacts don't exist in fresh worktrees.** A fresh `.goalmill/worktrees/<task>` has no `unpacked/`, `tools/vendors/`, so the "worktree is already prepared" setup premise is false for these tasks; T1's worker first hit `ls: cannot access 'unpacked/1.6/': No such file or directory` and recovered by running from the main repo root. `tools/x1600/make_nand_image.py` derives every path from its own script location and ignores argv, so it always writes the checkout that owns the script tree. Encoded as an always-hold rule in `AGENTS.md`. (confidence: high)
2. **Vendored QEMU has no PNG screendump support.** `{"execute":"screendump","format":"png"}` is rejected with `GenericError 'Enable PNG support with libpng for screendump'`; the shipped gate tries png, catches the error, falls back to the default ppm dump and converts with a pure-stdlib PNG encoder. (confidence: high)
3. **Screendump timing is dimension-critical.** The QEMU display surface is 640x480 until the guest LCD driver inits; it settles at 480x800 around the GUI-start markers (stable 480x800 from marker+5 s). An early dump fails the 480x800 assertion on a healthy boot; the gate captures after the `lg_guimain`/`running activity` markers plus a grace window, inside the lit pre-blank window (picker renders ~t+20–25 s, idle blank ~30 s later). (confidence: high)
4. **QMP replies can be preceded by events.** After `{"execute":"quit"}` an event line can arrive before the reply; the stdlib QMP client must skip `{"event":...}` lines rather than assume strict request-reply ordering. (confidence: low)

## Caveats

- **Three of five tasks were pending at termination.** The loop stopped on the terminal condition (final gate exit 0), not on task completion. T3/T4's named evidence directories (`/tmp/kilo/ui-gate`, `/tmp/kilo/ui-gate-run2`) and T5's `docs/PLAN.md` entry were never produced; the repeatability and documentation intent is only partially covered (see task section).
- **"v0.93" is not a firmware version.** The booted firmware is stock v1.6; "v0.93" names the QEMU model state. Anyone reading the goal text literally should read this clarification first.
- **Evidence is /tmp-only and non-durable.** Per the interview decision, all evidence lives in `/tmp/kilo/ui-gate-final` (+ the T2 verify dir) referenced by path, with no committed artifacts; it will not survive a reboot.
- **The PNG is not a native QEMU PNG.** It is a QMP ppm screendump converted by an in-script stdlib encoder because the vendored QEMU lacks libpng screendump support.
- **The boot-window diff is a window, not a full boot.** `tools/x1600-boot-test.sh` PASS covers 296 distinct / 158 structural serial lines against `boot-baseline-v0.89.txt` and stops at the rcS stall marker; the GUI-start capture happens on the second boot of the gate run.
- **The captured frame is the idle-lit picker inside a finite window.** The stock GUI blanks the panel ~30 s after the last input (FBIOBLANK(4) path, modeled as the v0.92 blanked state); the gate's marker+15 s grace keeps the capture inside the lit window, but the frame is a snapshot of a ~5 s-stable surface, not a held state.
- **Untracked files remain in the working tree** (`AGENTS.md`, `docs/qemu-qmp-screendump.md`, `hiby-boot-chime.wav`, `hiby-r1-splash.png`, `tools/x1600/__pycache__/`) — not part of this goal's merged work and not committed.
