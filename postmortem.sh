#!/usr/bin/env bash
# crashwatch boot-time post-mortem collector.
#
# Runs once per boot. If the PREVIOUS boot ended without crashwatch writing a
# clean-stop marker, that boot crashed / hung / lost power. Assemble a report:
# the pre-crash telemetry tail (the black box), any kernel-panic remnants in
# pstore, and the previous boot's last kernel lines.
set -uo pipefail

DATA=/var/log/crashwatch
REPORTS="$DATA/reports"
mkdir -p "$REPORTS"

cur=$(tr -d - < /proc/sys/kernel/random/boot_id | cut -c1-12)

# Most recent telemetry file that is NOT the current boot = the previous session.
prev=$(ls -t "$DATA"/telemetry-*.csv 2>/dev/null | grep -v "telemetry-$cur.csv" | head -1)
[ -z "${prev:-}" ] && exit 0

pbid=$(basename "$prev" .csv | sed 's/telemetry-//')
if [ -f "$DATA/clean-$pbid" ]; then
    exit 0  # previous boot shut down gracefully — not a crash
fi

ts=$(date +%Y%m%d-%H%M%S)
rpt="$REPORTS/crash-$ts.txt"
{
    echo "================ CRASHWATCH POST-MORTEM ================"
    echo "generated:        $(date -Is)"
    echo "crashed boot id:  $pbid"
    echo "current boot id:  $cur"
    echo "verdict: previous boot ended WITHOUT a clean stop (crash / hang / power loss)."
    echo
    echo "=== FINAL 150 TELEMETRY SAMPLES BEFORE DEATH (the black box) ==="
    echo "cols: $(head -1 "$prev")"
    tail -150 "$prev"
    echo
    echo "=== KERNEL PANIC REMNANTS (pstore) — empty here means NOT a panic (points to power/hard-reset) ==="
    ls -la /sys/fs/pstore/ 2>/dev/null
    cat /sys/fs/pstore/* 2>/dev/null | head -300
    echo
    echo "=== PREVIOUS BOOT: last 80 kernel lines ==="
    journalctl -k -b -1 --no-pager 2>/dev/null | tail -80
    echo
    echo "=== CURRENT BOOT: first 50 kernel lines (firmware/reset hints) ==="
    journalctl -k -b 0 --no-pager 2>/dev/null | head -50
    echo
    echo "=== sensors at report time ==="
    sensors 2>/dev/null
    echo "======================================================="
} > "$rpt" 2>&1

# Preserve any pstore records before something clears them, then free pstore.
cp -a /sys/fs/pstore/* "$REPORTS/" 2>/dev/null || true

logger -t crashwatch "post-mortem: previous boot $pbid crashed; report at $rpt"
exit 0
