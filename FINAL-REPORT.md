# FINAL REPORT - boot the unmodified stock firmware to the first player UI frame

# Final Report — Boot the unmodified stock firmware to the first player UI frame

**Loop outcome:** `completed_early` at round 0 of 12 (stall streak 0/3). The final gate was executed immediately after goal definition and exited 0, so the loop terminated before any task round was dispatched. The goal had already been proven once by the prior goalmill loop, archived at `.goalmill/archive/20261019T055021Z/` (terminal at 2026-10-19T05:03:22Z after round 2); this loop re-proved it with a fresh gate run.

## Goal and verification

**Goal (state.json / GOAL.md):** boot the unmodified stock firmware to the first player UI frame. ("v0.93" from the archived loop names the QEMU model round, not a firmware version — the firmware booted is stock v1.6; confirmed in the archived loop interview q1.)

**Final gate command:**

```
tools/x1600-ui-gate.sh --out /tmp/kilo/ui-gate-final && test -s /tmp/kilo/ui-gate-final/console.log && test -s /tmp/kilo/ui-gate-final/first-frame.png && echo GOAL-EVIDENCE-OK
```

**Result:** exit 0, 84.0 s, log `.goalmill/logs/gate-final-1792395763935.log`. Verbatim output:

```
x1600-ui-gate: [boot-regen] regenerating pristine nand image
x1600-ui-gate: [boot-regen] pristine nand md5 OK (ae41e974e78aab2730774d05c9cbf37c)
x1600-ui-gate: [boot-window] running tools/x1600-boot-test.sh
x1600-ui-gate: [boot-window] PASS: boot window matches baseline (296 distinct messages, 158 structural lines; boot stopped at the rcS stall marker)
x1600-ui-gate: [ui-regen] regenerating pristine nand image
x1600-ui-gate: [ui-regen] pristine nand md5 OK (ae41e974e78aab2730774d05c9cbf37c)
x1600-ui-gate: [ui-boot] starting qemu (serial0 -> /tmp/kilo/ui-gate-final/console.log)
x1600-ui-gate: [ui-boot] marker "lg_guimain:" seen (~26s)
x1600-ui-gate: [ui-boot] marker "running activity" seen (~28s)
x1600-ui-gate: [ui-boot] markers OK; capturing after 15s grace
x1600-ui-gate: QMP screendump png refused ({"class": "GenericError", "desc": "Enable PNG support with libpng for screendump"}); capturing ppm and encoding png with stdlib
screendump: /tmp/kilo/ui-gate-final/first-frame.png (ppm 480x800 -> png, stdlib encode)
x1600-ui-gate: [screendump] /tmp/kilo/ui-gate-final/first-frame.png written
PIX: 480x800 8-bit RGB mean=243.81 std=19.13 dark=4698 title+6 rows stroked, 7 gaps flat
x1600-ui-gate: [pixel-check] OK
PASS: x1600-ui-gate — boot-window diff PASS (tools/x1600-boot-test.sh), serial capture OK (lg_guimain + running activity, 15s grace), first-frame.png pixel check OK (480x800 lit picker)
GOAL-EVIDENCE-OK
```

**Artifacts:** `/tmp/kilo/ui-gate-final/console.log` (30.1 KB captured ttyS2 boot log, ends with the player GUI activity running) and `first-frame.png` (12.7 KB, 480x800 8-bit RGB PNG of the lit first-boot frame). The boot itself is the unmodified stock image: pristine nand regenerated per run from stock inputs (xImage md5 `022410af2bb16150f9597d14098dfe42`, rootfs.squashfs md5 `9c8b3a941dc2324ed6a641760928959c`), no firmware files touched.

**Prior proof of the same gate:** the archived loop's final gate exited 0 at 2026-10-19T05:03:22Z (84.1 s); its verbatim tail is recorded in the assessment as `PASS: x1600-ui-gate — boot-window diff PASS … first-frame.png pixel check OK (480x800 lit picker)` + `GOAL-EVIDENCE-OK` (log `R2-gate-final-1792386202390.log`, pruned at archive time).

## Tasks — status and gate evidence

All 10 planned tasks are **pending, attempts 0**. The loop stopped at round 0; none of the task gates was executed. What evidence exists:

| Task | Status | Evidence |
|------|--------|----------|
| T1 repo-root preflight | pending, 0 attempts, gate never run | De-facto covered by the assessment and the passing final gate: `tools/x1600-ui-gate.sh` executable and sh -n clean, `tools/x1600-boot-test.sh` present, prebuilt `tools/vendors/qemu/build/qemu-system-mipsel` (61.7 MB) present, stock-input md5s match the documented values, `/tmp/kilo` in use |
| T2 pristine nand image | pending, 0 attempts, gate never run | The final gate performed the identical operation twice per run: `[boot-regen] pristine nand md5 OK (ae41e974e78aab2730774d05c9cbf37c)` and `[ui-regen] pristine nand md5 OK` (quoted above). The archived loop's T1 gate also PASSED with `PRISTINE-OK` |
| T3 evidence run into `/tmp/kilo/ui-gate` | pending, 0 attempts | Directory does not exist. Equivalent full-gate runs exist at `/tmp/kilo/ui-gate-t2-verify` (archived T2 development run) and `/tmp/kilo/ui-gate-final` (both loops' final gates) |
| T4 repro run into `/tmp/kilo/ui-gate-run2` | pending, 0 attempts | Directory does not exist. Reproducibility is evidenced indirectly: the identical gate PASSed independently at 05:03:22Z (archived loop) and 07:42:43Z (this loop), each from a fresh pristine regen |
| T5 tz-tap decode brief (`docs/briefs/wizard-tz-tap-decode.md`) | pending, 0 attempts | `docs/briefs/` does not exist. The underlying open problem (kernel delivers the full MT-A touch stream on the tz page while the player reads only its timerfd; drop is inside litegui event routing — docs/PLAN.md M3 round) is unaddressed |
| T6 wizard drive + QEMU model fix (`tools/x1600-wizard-drive.sh`, patch 0131) | pending, 0 attempts | `tools/x1600-wizard-drive.sh` does not exist; `tools/patches/qemu-x1600/` ends at patch 0130 (no 0131) |
| T7 rebuild-from-patches gate | pending, 0 attempts | `/tmp/kilo/qemu-repro` does not exist. The count precondition trivially holds (36 patch files ≥ 34), but the scratch rebuild + boot-test was never executed |
| T8 gate extension (wizard → idle player screen) | pending, 0 attempts | `tools/x1600-ui-gate.sh` at HEAD is still the archived T2 version (557 lines, picker capture; no wizard stages — grep confirms no wizard/tz logic beyond a comment) |
| T9 docs/PLAN.md evidence entry | pending, 0 attempts | `docs/PLAN.md` has 0 references to `x1600-ui-gate`, `x1600-wizard-drive`, `wizard-tz-tap-decode`, or `x1600-first-player-ui` (grep count 0) |
| T10 durable committed evidence pair | pending, 0 attempts | `docs/evidence/` does not exist; the evidence pair remains /tmp-only |

**Archived-loop tasks that did complete (their gate evidence):**

- **T1 (pristine image regen)** — gate PASS, exit 0, 9.2 s (`.goalmill/archive/20261019T055021Z` history, log `R1-gate-T1-1792385122473.log`):
  ```
    xImage               -> 0x00200000 (3731520 bytes)
    rootfs.squashfs      -> 0x00700000 (37507072 bytes)
    xImage               -> 0x02f00000 (3731520 bytes)
    rootfs.squashfs      -> 0x03400000 (37507072 bytes)
    partition table      -> 0x00005800 (7 entries)
  wrote /home/matt/dev/hiby-r1-sdk/unpacked/1.6/nand-r1.bin (138412032 bytes, 65536 pages x 2112 B)
  unpacked/1.6/nand-r1.bin: OK
  PRISTINE-OK
  ```
- **T2 (write `tools/x1600-ui-gate.sh`)** — gate PASS: `UI-GATE-SCRIPT-OK` (exit 0), plus a T1 regression re-run PASS (`PRISTINE-OK`, 9.5 s). The worker's functional verification run ended with `PASS: x1600-ui-gate — boot-window diff PASS (tools/x1600-boot-test.sh), serial capture OK (lg_guimain + running activity, 15s grace), first-frame.png pixel check OK (480x800 lit picker)` and negative-tested the embedded pixel checker (rejects a blanked mean-0.0 frame and a truncated PNG).
- **T3/T4/T5 of the archived loop** (named evidence dir, repro dir, PLAN.md entry) — pending at its terminal; carried into this loop's plan as T3/T4 and folded into T8/T9/T10.

## Work merged

**This loop:** one commit — `0b24e6e goalmill: goal defined - 10 gated tasks (round 0 baseline)` (GOAL.md rewrite only). No code changes; the loop merged nothing because it terminated before dispatch.

**Archived loop (the work that makes the final gate pass):**

- `5baa7f8` — `tools: x1600-ui-gate.sh`: 557-line standalone gate. Per run: pristine nand regen + md5 before each boot phase; `tools/x1600-boot-test.sh` boot-window diff required; UI boot with QMP unix socket + serial0 chardev capture; `lg_guimain`/`running-activity` markers + 15 s grace inside the lit pre-blank window; QMP screendump to `first-frame.png` (format png with ppm→png pure-stdlib fallback); pure-stdlib 480x800 lit-picker pixel check (title y34-49, rows y131/256/390/513/635/768, flat gaps) calibrated on live probe captures.
- Bookkeeping commits: `72b30e7` (baseline), `08cad55` (round 1), `11c71e0`/`a01183b` (T2 integrate/round 2), `47df07a` (terminal, committed the prior FINAL-REPORT.md, 98 lines).

**Pre-existing at HEAD (not produced by these loops):** the 36-file QEMU x1600 patch series in `tools/patches/qemu-x1600/` (newest `0130-x1600-wake-from-suspend-...`), `tools/x1600-boot-test.sh`, keepalive tooling, the prebuilt vendored qemu, and the docs corpus (`docs/PLAN.md`, M1-M3 logs).

## Lessons learned (refinement ledger `LESSONS.md`)

Four lessons, all from the archived loop; this loop ran no rounds (`lessons_seen: 0`), so it added none:

1. **Gitignored artifacts and fresh worktrees** (high) — fresh `git worktree`s contain no `unpacked/`/`tools/vendors/`; the working fix was running tasks and gates from the main repo root (`make_nand_image.py` derives all paths from its own script location and ignores argv). Encoded as always-hold rules in `AGENTS.md`.
2. **Vendored qemu rejects PNG screendumps** (high) — the binary lists `screendump` but answers `{"error":{"class":"GenericError","desc":"Enable PNG support with libpng for screendump"}}` to `format:"png"`; capture paths must fall back to ppm + a pure-stdlib PPM→PNG encoder (pattern shipped in the gate). Encoded in `docs/qemu-qmp-screendump.md`.
3. **Display surface timing** (high) — the QEMU surface is 640x480 until the guest LCD driver inits and settles at 480x800 only around the GUI-start serial markers; screendumps must be taken after the markers plus grace, or the dimension assertion fails on a healthy boot.
4. **QMP `quit` reply parsing** (low) — a QMP quit can deliver an event line before its reply; the client must skip `{"event":...}` lines rather than assume strict request→reply ordering.

## Caveats

1. **Frame-definition mismatch (the main one).** This loop's interview defined the goal frame as "idle player screen after completing the first-boot wizard via injected touches" (q2). The shipped gate instead captures the first lit GUI frame — the first-boot language picker — which is what its own output states (`480x800 lit picker`, pixel signature `title+6 rows stroked`). `state.json`'s `final_gate_note` describes the gate as T8-extended (wizard drive → idle player screen, calibrated idle-player signature); that is aspirational, not true of the script at HEAD. What `GOAL-EVIDENCE-OK` proves is the picker frame on a freshly regenerated pristine image — the same frame definition the archived loop used (its interview q3).
2. **Wizard completion remains unproven.** The tz-row tap dead-end is open at HEAD: per docs/PLAN.md M3, the kernel delivers the full MT-A touch stream on the tz page while litegui consumes nothing, so the wizard cannot yet be completed via injected touches (the real device completes it on the same rootfs). T5/T6/T8, which targeted this, never ran.
3. **Evidence is not durable.** `console.log` + `first-frame.png` live only in `/tmp/kilo/ui-gate-final`; the committed pair (T10) and the docs/evidence dir do not exist.
4. **No documentation of the gate round.** `docs/PLAN.md` contains no entry for `x1600-ui-gate.sh` (T9 unrun); the PASS semantics are documented only in the script header and `docs/qemu-qmp-screendump.md`.
5. **Dirty nand image on disk is expected.** Any gate boot dirties `unpacked/1.6/nand-r1.bin`; per AGENTS.md the gate regenerates and md5-verifies the pristine image (`ae41e974e78aab2730774d05c9cbf37c`) before every boot and never hand-patches a mismatch.
6. **Untracked harness artifacts.** `AGENTS.md` and `docs/qemu-qmp-screendump.md` (written by archived-loop refinement edits) are untracked at HEAD, as are stray `hiby-boot-chime.wav`, `hiby-r1-splash.png`, and `tools/x1600/__pycache__/`.
7. **Rebuild-from-source is untested at HEAD.** 36 patches are present, but no scratch rebuild (`/tmp/kilo/qemu-repro`) has ever been executed by these loops; the prebuilt vendored binary is the only proven emulator.
