#!/usr/bin/env bash
# Self-contained mock test for crashwatch — no external deps beyond python3 +
# coreutils. Simulates a power-loss crash (kill -9, no clean marker) and a clean
# shutdown (SIGTERM, marker written), and asserts the post-mortem does the right
# thing in each case, using a fake nvidia-smi and a temp data dir.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1"; fails=$((fails + 1)); fi; }

# Fake nvidia-smi emitting a canned "GPU pulling 560W" sample (ignores args).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
echo "560.42, 575.00, 71, 99, 40, 2900, 14001, P0, 23456, 0x0000000000000004"
EOF
chmod +x "$TMP/bin/nvidia-smi"
export PATH="$TMP/bin:$PATH"
export CRASHWATCH_DIR="$TMP/data"
export CRASHWATCH_INTERVAL="0.2"

echo "[1] telemetry records fsynced samples (and NO clean marker on power loss)"
CRASHWATCH_BOOT_ID=aaaaaaaaaaaa python3 "$ROOT/telemetry.py" &
tpid=$!
sleep 1
kill -9 "$tpid" 2>/dev/null   # simulate instant power loss: no graceful stop
wait "$tpid" 2>/dev/null
csv="$CRASHWATCH_DIR/telemetry-aaaaaaaaaaaa.csv"
check "telemetry file created"                    "[ -f '$csv' ]"
check "header present"                            "head -1 '$csv' | grep -q gpu_power_w"
check "captured GPU watts from fake nvidia-smi"   "grep -q 560.42 '$csv'"
check "no clean-stop marker after kill -9"        "[ ! -f '$CRASHWATCH_DIR/clean-aaaaaaaaaaaa' ]"

echo "[2] post-mortem DETECTS the unclean boot and writes a report"
CRASHWATCH_BOOT_ID=bbbbbbbbbbbb bash "$ROOT/postmortem.sh"
rpt="$(ls "$CRASHWATCH_DIR"/reports/crash-*.txt 2>/dev/null | head -1)"
check "crash report generated"                    "[ -n '$rpt' ]"
check "report names the crashed boot"             "grep -q aaaaaaaaaaaa '$rpt'"
check "report contains pre-crash telemetry (560W)" "grep -q 560.42 '$rpt'"

echo "[3] real SHUTDOWN (system stopping) writes marker => NO report"
rm -f "$CRASHWATCH_DIR"/reports/crash-*.txt
CRASHWATCH_FORCE_SHUTDOWN_STATE=stopping CRASHWATCH_BOOT_ID=cccccccccccc python3 "$ROOT/telemetry.py" &
tpid=$!
sleep 0.6
kill -TERM "$tpid"           # graceful stop during a system shutdown: writes marker
wait "$tpid" 2>/dev/null
check "clean-stop marker written on shutdown"     "[ -f '$CRASHWATCH_DIR/clean-cccccccccccc' ]"
CRASHWATCH_BOOT_ID=dddddddddddd bash "$ROOT/postmortem.sh"
check "no crash report for cleanly-stopped boot"  "[ -z \"\$(ls '$CRASHWATCH_DIR'/reports/crash-*.txt 2>/dev/null)\" ]"

echo "[3b] a service RESTART (system NOT stopping) must NOT write a marker"
CRASHWATCH_DIR="$TMP/data_restart" CRASHWATCH_FORCE_SHUTDOWN_STATE=running CRASHWATCH_BOOT_ID=abcabcabcabc \
  python3 "$ROOT/telemetry.py" &
tpid=$!
sleep 0.5
kill -TERM "$tpid"           # restart-style SIGTERM while the system is running
wait "$tpid" 2>/dev/null
check "no clean marker on restart-style SIGTERM"  "[ ! -f '$TMP/data_restart/clean-abcabcabcabc' ]"
CRASHWATCH_DIR="$TMP/data_restart" CRASHWATCH_BOOT_ID=defdefdefdef bash "$ROOT/postmortem.sh"
check "crash still detected after a mid-boot restart" "[ -n \"\$(ls '$TMP/data_restart'/reports/crash-*.txt 2>/dev/null)\" ]"

echo "[3c] startup self-heals a stale clean marker for the current boot"
touch "$TMP/data_restart/clean-fedfedfedfed"
CRASHWATCH_DIR="$TMP/data_restart" CRASHWATCH_BOOT_ID=fedfedfedfed python3 "$ROOT/telemetry.py" &
tpid=$!
sleep 0.4
kill -9 "$tpid" 2>/dev/null
wait "$tpid" 2>/dev/null
check "stale current-boot marker removed on startup" "[ ! -f '$TMP/data_restart/clean-fedfedfedfed' ]"

echo "[4] pstore panic remnant is captured into the report"
rm -f "$CRASHWATCH_DIR"/reports/crash-*.txt
export CRASHWATCH_PSTORE="$TMP/pstore"
mkdir -p "$CRASHWATCH_PSTORE"
echo "Kernel panic - not syncing: FAKE for test" > "$CRASHWATCH_PSTORE/dmesg-efi_pstore-1"
CRASHWATCH_BOOT_ID=eeeeeeeeeeee python3 "$ROOT/telemetry.py" & tpid=$!; sleep 0.5; kill -9 "$tpid" 2>/dev/null; wait "$tpid" 2>/dev/null
CRASHWATCH_BOOT_ID=ffffffffffff bash "$ROOT/postmortem.sh"
rpt="$(ls "$CRASHWATCH_DIR"/reports/crash-*.txt 2>/dev/null | head -1)"
check "panic text pulled into report"             "grep -q 'Kernel panic' '$rpt'"
unset CRASHWATCH_PSTORE

echo "[5] telemetry survives an unavailable GPU (nvidia-smi failing)"
cat > "$TMP/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP/bin/nvidia-smi"
CRASHWATCH_DIR="$TMP/data2" CRASHWATCH_BOOT_ID=999999999999 python3 "$ROOT/telemetry.py" & tpid=$!; sleep 0.7; kill -9 "$tpid" 2>/dev/null; wait "$tpid" 2>/dev/null
csv2="$TMP/data2/telemetry-999999999999.csv"
check "still records host rows without a GPU"      "[ -f '$csv2' ] && [ \$(wc -l < '$csv2') -ge 2 ]"

echo
if [ "$fails" -eq 0 ]; then
    echo "ALL TESTS PASSED"
else
    echo "$fails TEST(S) FAILED"
    exit 1
fi
