#!/bin/sh
# x1600-boot-test.sh — M4 boot regression gate (docs/PLAN.md M4).
#
# Boots the UNMODIFIED stock v1.6 firmware in the vendored QEMU X1600E
# machine, captures the serial console window up to the known rcS end
# state (the documented DHD/wifi stall — the gate does NOT require the
# player UI), normalizes it and diffs it against the recorded per-version
# baseline in two tiers:
#   1. canonical message SET (distinct normalized lines, order- and
#      multiplicity-free — the slow ttyS2 console flushes printk bursts
#      asynchronously and the number of oops/warning stack-dump groups
#      varies with scheduling, so neither order nor dump counts are
#      reproducible under host load);
#   2. ordered SEQUENCE of init-thread structural lines (calling/initcall
#      chain, earlycon banner + handoff, root mount) — same-task FIFO on a
#      single vCPU, so order there is trustworthy.
# Exits nonzero with a printed diff on earlycon mismatch or any unexpected
# window change; exits 0 with a short PASS summary otherwise.
#
# Usage:
#   tools/x1600-boot-test.sh [--timeout SEC] [--baseline FILE]
#       [--update-baseline] [--qemu PATH] [--out DIR] [--kernel FILE]
#
#   --timeout SEC        max boot wall time in seconds (default 360)
#   --baseline FILE      baseline trace to diff against
#                        (default docs/traces/boot-baseline-v0.89.txt)
#   --update-baseline    (re)record the baseline from a fresh boot
#   --qemu PATH          qemu-system-mipsel binary
#                        (default tools/vendors/qemu/build/qemu-system-mipsel)
#   --out DIR            scratch output dir (default /tmp/kilo/boot-test;
#                        raw serial log + normalized window + diffs land here)
#   --kernel FILE        stock vmlinux.bin to boot; the SFC/NAND model loads
#                        nand-r1.bin from the same directory
#                        (default unpacked/1.6/vmlinux.bin)
#
# Exit codes: 0 PASS, 1 window mismatch, 2 incomplete/failed boot window
# (earlycon mismatch, terminal marker never reached, qemu died early),
# 3 usage or environment error.
#
# Only this script's own qemu child process is ever signalled; unrelated
# concurrent qemu runs (e.g. from sibling worktrees) are never touched.
# Needs coreutils + the qemu binary only.

set -u
LC_ALL=C
export LC_ALL

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

MARKER='UBIFS (ubi1:0): default file-system created'
EARLYCON_BANNER='Linux version 4.4.94+'
EARLYCON_HANDOFF='bootconsole [early0] enabled'
# The ttyS2 console (serial0) only carries output from its registration
# (the 8250 console does not replay the pre-handoff buffer in 4.4.94); the
# earlycon lives on ttyS0 (stock DTB stdout-path) = the discardable
# serial1, so the earlycon stage is checked there.
CONSOLE_HANDOFF='console [ttyS2] enabled'
CONSOLE_HANDOFF_DONE='bootconsole [early0] disabled'
# Init-thread messages whose relative order is deterministic (single vCPU,
# same task): the module/initcall chain, console handoff, root mount.
STRUCT_RE='^(calling |initcall |Linux version |bootconsole \[|console \[ttyS2\]|VFS: Mounted root|VFS: Cannot)'

TIMEOUT=360
BASELINE=
QEMU=
KERNEL=
OUT=/tmp/kilo/boot-test
UPDATE=0

usage() { sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//; s/^#$//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --timeout)          [ $# -ge 2 ] || { usage >&2; exit 3; }
                            TIMEOUT=$2; shift 2 ;;
        --baseline)         [ $# -ge 2 ] || { usage >&2; exit 3; }
                            BASELINE=$2; shift 2 ;;
        --update-baseline)  UPDATE=1; shift ;;
        --qemu)             [ $# -ge 2 ] || { usage >&2; exit 3; }
                            QEMU=$2; shift 2 ;;
        --out)              [ $# -ge 2 ] || { usage >&2; exit 3; }
                            OUT=$2; shift 2 ;;
        --kernel)           [ $# -ge 2 ] || { usage >&2; exit 3; }
                            KERNEL=$2; shift 2 ;;
        --help|-h)          usage; exit 0 ;;
        *)                  printf 'x1600-boot-test: unknown option: %s\n' "$1" >&2
                            usage >&2; exit 3 ;;
    esac
done

[ -n "$BASELINE" ] || BASELINE=$ROOT/docs/traces/boot-baseline-v0.89.txt
[ -n "$QEMU" ]     || QEMU=$ROOT/tools/vendors/qemu/build/qemu-system-mipsel
[ -n "$KERNEL" ]   || KERNEL=$ROOT/unpacked/1.6/vmlinux.bin

case "$TIMEOUT" in
    ''|*[!0-9]*) printf 'x1600-boot-test: --timeout wants a positive integer\n' >&2; exit 3 ;;
esac
[ "$TIMEOUT" -gt 0 ] || { printf 'x1600-boot-test: --timeout wants a positive integer\n' >&2; exit 3; }

die() { printf 'x1600-boot-test: %s\n' "$1" >&2; exit 3; }

[ -x "$QEMU" ] || die "qemu binary not found/executable: $QEMU"
[ -f "$KERNEL" ] || die "stock kernel not found: $KERNEL (run tools/unpack.sh)"
[ -f "$(dirname -- "$KERNEL")/nand-r1.bin" ] \
    || die "nand-r1.bin not found next to the kernel (build with tools/x1600/make_nand_image.py)"
[ "$UPDATE" -eq 1 ] || [ -f "$BASELINE" ] \
    || die "baseline not found: $BASELINE (record one with --update-baseline)"

mkdir -p -- "$OUT" || die "cannot create output dir: $OUT"
OUT=$(CDPATH='' cd -- "$OUT" && pwd) || die "cannot enter output dir"

# serial0 = ttyS2 console (captured, gated); serial1 = ttyS0 BT/earlycon
# uart — discardable (patchram writes binary there; never gated on it,
# but kept as a file so the earlycon stage and BT-stage debugging can
# look at it).
SERIAL_LOG=$OUT/serial-$$.log
BT_LOG=$OUT/bt-serial-$$.log
WINDOW=$OUT/window-$$.log

md5of() { md5sum "$1" | awk '{print $1}'; }

print_bounded_diff() {
    pbd_lines=$(wc -l < "$1")
    if [ "$pbd_lines" -gt 200 ]; then
        printf '(diff truncated: 200 of %s lines; full diff: %s)\n' "$pbd_lines" "$1" >&2
        head -n 200 "$1" >&2
    else
        cat "$1" >&2
    fi
}

# Canonical form of one boot window (line-level). Idempotent (applying it
# to an already-normalized baseline window is a no-op):
#  - strip guest timestamps;
#  - neutralize numbers known to vary between identical boots: initcall
#    durations, BogoMIPS/lpj, the UBIFS image sequence number (randomized
#    by the kernel per attach), oops trace IDs, PID/task/threadinfo/tls
#    fields (kworker creation races with host load), CP0 Status/Cause and
#    Hi/Lo live register values, register+stack dump contents (live values
#    at fault time), the Modules-linked-in / Tainted snapshots of an oops
#    (depend on how far the concurrent insmod chain got), and the Oops[#N]
#    counters (depend on how many dumps fired);
#  - drop the two documented timing-spam line classes (the SADC-stub
#    220 ms poller and the I2C-stub wait loops): their count and
#    interleaving are scheduling noise, the probes' own success/failure
#    prints stay in the window;
#  - cut at the terminal marker and squeeze consecutive duplicate lines.
# Comparison tiers (distinct-message set + structural sequence) are
# derived from this.
normalize() {
    sed -e 's/\r$//' \
        -e 's/^\[[[:space:]]*[0-9][0-9.]*\][[:space:]]*//' \
        -e 's/returned \(.*\) after [0-9][0-9]* usecs/returned \1 after <N> usecs/' \
        -e 's/Calibrating delay loop\.\.\. [0-9][0-9.]* BogoMIPS (lpj=[0-9][0-9]*)/Calibrating delay loop... <N> BogoMIPS (lpj=<N>)/' \
        -e 's/image sequence number: [0-9][0-9]*/image sequence number: <N>/' \
        -e 's/end trace [0-9a-f][0-9a-f]* /end trace <ID> /' \
        -e 's/ @ [0-9][0-9]*$/ @ <PID>/' \
        -e 's/PID: [0-9][0-9]*/PID: <PID>/' \
        -e 's/PID [0-9][0-9]*/PID <PID>/' \
        -e 's/(pid: [0-9][0-9]*,/(pid: <PID>,/' \
        -e 's/threadinfo=[0-9a-f][0-9a-f]*/threadinfo=<ADDR>/' \
        -e 's/task=[0-9a-f][0-9a-f]*/task=<ADDR>/' \
        -e 's/tls=[0-9a-f][0-9a-f]*/tls=<ADDR>/' \
        -e 's/^task: [0-9a-f][0-9a-f]* ti: [0-9a-f][0-9a-f]* task\.ti: [0-9a-f][0-9a-f]*$/task: <ADDR> ti: <ADDR> task.ti: <ADDR>/' \
        -e 's/^Stack : .*/<stack dump>/' \
        -e 's/^	.*/<stack dump>/' \
        -e 's/^\$.*/<regdump>/' \
        -e 's/^Hi .*/<regdump>/' \
        -e 's/^Lo .*/<regdump>/' \
        -e 's/^Status: [0-9a-f][0-9a-f]*/Status: <CP0>/' \
        -e 's/^Cause : [0-9a-f][0-9a-f]* (ExcCode/Cause : <CP0> (ExcCode/' \
        -e 's/^Modules linked in: .*/<modules>/' \
        -e 's/Tainted: [A-Za-z ][A-Za-z ]*/Tainted: <TAINT> /' \
        -e 's/^Oops\[[0-9][0-9]*\]/Oops[<N>]/' \
        -e 's/successFinish display\.\.\./success\nFinish display.../' \
        -e 's/tsk = 0x[0-9a-f][0-9a-f]*/tsk = <ADDR>/' \
        -e 's/\(thread:[A-Za-z_]*:\)[0-9a-f][0-9a-f]*/\1<PID>/' \
    | grep -v -e '^adc_read_channel_value:adc get value timeout!$' \
              -e '^i2c[0-9] write timeout([0-9][0-9]* ms)$' \
              -e '^hrtimer: interrupt took [0-9][0-9]* ns$' \
    | awk -v marker="$MARKER" 'index($0, marker) { print; exit } { print }' \
    | awk '
      # Canonicalize the two documented adjacent-swap races (run-to-run
      # print-order flips, v0.89): the lcd_lg35583/msc initcall-complete
      # lines race the framework prints that may follow them. Emit each
      # known pair with the initcall line first, whichever order the
      # boot produced. Idempotent on already-canonical windows.
      {
        if (pending != "") {
          if ((pending ~ /^Wait display\.\.\.$/ && \
               $0 ~ /^initcall lg35583_init\+0x0\/0x500 \[lcd_lg35583\] returned/) || \
              (pending ~ /^md_ingenic,mmc md_ingenic,mmc\.1: card inserted, state=0$/ && \
               $0 ~ /^initcall msc_init\+0x0\/0x138 \[soc_msc\] returned/)) {
            print $0; print pending; pending = ""
          } else {
            print pending; pending = $0
          }
        } else {
          pending = $0
        }
      }
      END { if (pending != "") print pending }' \
    | uniq
}

QPID=
cleanup() {
    if [ -n "$QPID" ]; then
        kill "$QPID" 2>/dev/null
    fi
}
trap cleanup EXIT

printf 'x1600-boot-test: booting stock firmware (%s) in %s\n' "$KERNEL" "$QEMU"
"$QEMU" -M x1600 \
    -kernel "$KERNEL" \
    -serial "file:$SERIAL_LOG" \
    -serial "file:$BT_LOG" \
    -display none -monitor none -no-reboot &
QPID=$!

complete=0
qemu_died=0
elapsed=0
while :; do
    if grep -qF "$MARKER" "$SERIAL_LOG" 2>/dev/null; then
        complete=1
        sleep 3
        break
    fi
    if ! kill -0 "$QPID" 2>/dev/null; then
        qemu_died=1
        break
    fi
    [ "$elapsed" -ge "$TIMEOUT" ] && break
    sleep 2
    elapsed=$((elapsed + 2))
done

kill "$QPID" 2>/dev/null
wait "$QPID" 2>/dev/null
QEXIT=$?
QPID=

normalize < "$SERIAL_LOG" > "$WINDOW"
WLINES=$(wc -l < "$WINDOW")

if [ "$UPDATE" -eq 1 ]; then
    main_head=$(git -C "$ROOT" rev-parse --short=7 HEAD 2>/dev/null)
    qrev=$(git -C "$ROOT/tools/vendors/qemu" rev-parse --short=7 HEAD 2>/dev/null)
    qdirty=$(git -C "$ROOT/tools/vendors/qemu" status --porcelain -- hw/mips/x1600.c 2>/dev/null)
    {
        printf '# x1600-boot-test baseline — M4 boot regression gate (docs/PLAN.md M4)\n'
        printf '# generated: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf '# firmware: stock v1.6 UNMODIFIED; kernel %s md5 %s\n' "$KERNEL" "$(md5of "$KERNEL")"
        printf '# nand image %s md5 %s\n' "$(dirname -- "$KERNEL")/nand-r1.bin" "$(md5of "$(dirname -- "$KERNEL")/nand-r1.bin")"
        printf '# qemu binary %s md5 %s\n' "$QEMU" "$(md5of "$QEMU")"
        [ -n "$main_head" ] && printf '# main repo HEAD: %s\n' "$main_head"
        if [ -n "$qrev" ]; then
            printf '# vendored qemu rev: %s (hw/mips/x1600.c: %s)\n' "$qrev" \
                "$([ -n "$qdirty" ] && printf 'UNCOMMITTED bring-up state' || printf 'clean')"
        fi
        printf '# boot cmd: qemu-system-mipsel -M x1600 -kernel <kernel> -serial file:<console log> -serial file:<ttyS0 log> -display none -monitor none -no-reboot\n'
        printf '# console port: ttyS2 = serial0 (captured; stock cmdline\n'
        printf '#   console=ttyS2,3000000n8); ttyS0 = serial1 (earlycon + BT uart,\n'
        printf '#   discardable — the window is serial0 only).\n'
        printf '# window: serial output through the terminal marker "%s" —\n' "$MARKER"
        printf '#   the documented rcS end state (wifi/DHD failure stall); the gate does\n'
        printf '#   not require the player UI.\n'
        printf '# normalization: guest timestamps stripped; consecutive duplicate lines\n'
        printf '#   squeezed; volatile numbers neutralized: initcall "after <N> usecs"\n'
        printf '#   durations, BogoMIPS/lpj, UBIFS image sequence number (randomized by\n'
        printf '#   the kernel per attach), oops trace IDs, PID/task/threadinfo/tls\n'
        printf '#   fields, register+stack dump contents, Modules-linked-in/Tainted\n'
        printf '#   oops snapshots; the documented timing-spam line classes (adc poller,\n'
        printf '#   i2cN write timeout, hrtimer delay warning) dropped.\n'
        printf '# comparison: distinct canonical messages (order/multiplicity-free)\n'
        printf '#   + ordered sequence of init-thread structural lines (calling/initcall\n'
        printf '#   chain, console handoff, root mount) — see tools/x1600-boot-test.sh.\n'
        printf '# --- window ---\n'
        cat "$WINDOW"
    } > "$BASELINE.tmp" && mv "$BASELINE.tmp" "$BASELINE" \
        || die "cannot write baseline: $BASELINE"
    printf 'BASELINE RECORDED: %s (%s lines)\n' "$BASELINE" "$WLINES"
    exit 0
fi

BASEWIN=$OUT/baseline-window-$$.log
grep -v '^#' "$BASELINE" | normalize > "$BASEWIN"
[ -s "$BASEWIN" ] || die "baseline has an empty window — wrong file? $BASELINE"

if ! grep -qF "$EARLYCON_BANNER" "$BT_LOG" || ! grep -qF "$EARLYCON_HANDOFF" "$BT_LOG"; then
    printf 'FAIL: earlycon mismatch — "%s" / "%s" not in the ttyS0 (earlycon) log\n' \
        "$EARLYCON_BANNER" "$EARLYCON_HANDOFF" >&2
    printf '%s\n' '--- last 15 lines of the captured window ---' >&2
    tail -n 15 "$WINDOW" >&2
    exit 2
fi

if ! grep -qF "$CONSOLE_HANDOFF" "$WINDOW" || ! grep -qF "$CONSOLE_HANDOFF_DONE" "$WINDOW"; then
    printf 'FAIL: console handoff mismatch — "%s" / "%s" not in the ttyS2 capture\n' \
        "$CONSOLE_HANDOFF" "$CONSOLE_HANDOFF_DONE" >&2
    printf '%s\n' '--- last 15 lines of the captured window ---' >&2
    tail -n 15 "$WINDOW" >&2
    exit 2
fi

if [ "$complete" -ne 1 ]; then
    if [ "$qemu_died" -eq 1 ]; then
        printf 'FAIL: qemu exited early (exit %s) before the boot window completed\n' "$QEXIT" >&2
    else
        printf 'FAIL: boot window incomplete — terminal marker not reached within %ss\n' "$TIMEOUT" >&2
    fi
    printf '%s\n' '--- last 15 lines of the captured window ---' >&2
    tail -n 15 "$WINDOW" >&2
    exit 2
fi

DIFF_MULTI=$OUT/diff-multiset-$$.log
DIFF_STRUCT=$OUT/diff-struct-$$.log
sort -u -o "$WINDOW.sorted" "$WINDOW"
sort -u -o "$BASEWIN.sorted" "$BASEWIN"
diff -u "$BASEWIN.sorted" "$WINDOW.sorted" > "$DIFF_MULTI"
RC_MULTI=$?
grep -E "$STRUCT_RE" "$BASEWIN" > "$BASEWIN.struct"
grep -E "$STRUCT_RE" "$WINDOW" > "$WINDOW.struct"
diff -u "$BASEWIN.struct" "$WINDOW.struct" > "$DIFF_STRUCT"
RC_STRUCT=$?

if [ "$RC_MULTI" -eq 0 ] && [ "$RC_STRUCT" -eq 0 ]; then
    printf 'PASS: boot window matches baseline (%s distinct messages, %s structural lines; boot stopped at the rcS stall marker)\n' \
        "$(wc -l < "$WINDOW.sorted")" "$(wc -l < "$WINDOW.struct")"
    printf '  baseline: %s\n' "$BASELINE"
    exit 0
fi

if [ "$RC_MULTI" -ne 0 ]; then
    printf 'FAIL: boot window messages differ from baseline %s\n' "$BASELINE" >&2
    print_bounded_diff "$DIFF_MULTI"
fi
if [ "$RC_STRUCT" -ne 0 ]; then
    printf 'FAIL: init/initcall sequence order differs from baseline %s\n' "$BASELINE" >&2
    print_bounded_diff "$DIFF_STRUCT"
fi
exit 1
