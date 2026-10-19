# Vendored QEMU QMP screendump facts (x1600 machine)

Scope: QMP behavior of the prebuilt `tools/vendors/qemu/build/qemu-system-mipsel`
(-M x1600) relevant to screendump capture and the first-boot UI pixel check.
Verified 2026-10-19, goalmill round 2 (T2). Shipped implementation:
`tools/x1600-ui-gate.sh` (embedded stdlib QMP client + pixel checker) — reuse it
instead of hand-rolling capture paths.

## 1. screendump rejects `format: "png"` in this build

The binary lists `screendump` in `query-commands`, but
`{"execute":"screendump","arguments":{"filename":...,"format":"png"}}` replies:

```
{"error":{"class":"GenericError","desc":"Enable PNG support with libpng for screendump"}}
```

Recipe: request png, catch that GenericError, fall back to the default (ppm)
dump, and convert PPM→PNG with a pure-stdlib encoder so `<out>/first-frame.png`
is still a genuine PNG (signature + IHDR: 480x800, 8-bit, ctype 2). Verified
end-to-end by the T2 functional run (`screendump: /tmp/kilo/ui-gate-t2-verify/
first-frame.png (ppm 480x800 -> png, stdlib encode)` → `first-frame.png pixel
check OK (480x800 lit picker)`; gate `.goalmill/logs/R2-gate-T2-1792385949648.log`
`UI-GATE-SCRIPT-OK`). Evidence: `.goalmill/logs/R2-worker-T2-1792385949621.log`.

## 2. Surface is 640x480 until the guest LCD inits

The QEMU display surface starts at 640x480 and resizes to 480x800 when the
guest LCD driver initializes (probe dumps at t≈4 s were 640x480; by the GUI-start
serial marker +5 s every dump is 480x800). Screendumps for the first-boot
language-picker pixel check must be taken only after the `lg_guimain:` /
`running activity` serial markers with grace (the gate polls marker+grace);
an early dump fails the dimension assertion. Calibrated thresholds from the
round-2 probe: lit picker mean 243.81 / std 19.13, title 528 dark px, picker
rows 218–361 dark px, gaps flat (min luma 243, spread ≤7); late idle capture
blanked at mean 0.0 — clean separation.

## 3. QMP `quit` may deliver an event line before its reply

After `{"execute":"quit"}` the socket can carry a `{"event":...}` line ahead of
the `{"return":...}` reply; a reply parser must skip event lines instead of
assuming strict request→reply ordering (the gate's client does; negative-tested
blanked/truncated frames are rejected by the embedded checker).
