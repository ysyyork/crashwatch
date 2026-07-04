#!/usr/bin/env bash
# Optional companion to crashwatch's passive recorder: arms a HARDWARE watchdog
# and converts silent kernel lockups into a captured panic + auto-reboot.
#
# Why this is separate from install.sh: the recorder only observes. This
# actively changes reboot behavior.
#
# TRADE-OFF (read before running): a transient stall that might previously
# have self-recovered will now force a reboot. In particular
# kernel.hung_task_panic=1 fires if ANY task sits in an uninterruptible wait
# for kernel.hung_task_timeout_secs (default 120s) -- on a box doing heavy
# Docker/GPU/disk work, a legitimately slow (but not actually hung) I/O
# operation could in principle hit that window and force a reboot rather than
# eventually finishing. Raise CRASHWATCH_HUNG_TASK_TIMEOUT if you want more
# headroom before that specific trigger fires.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root:  sudo ./harden.sh" >&2
    exit 1
fi

HUNG_TASK_TIMEOUT="${CRASHWATCH_HUNG_TASK_TIMEOUT:-120}"

echo "== 1. hardware watchdog =="
loaded=""
for mod in iTCO_wdt sp5100_tco wdat_wdt; do
    if modprobe "$mod" 2>/dev/null; then
        loaded="$mod"
        break
    fi
done
if [ -z "$loaded" ] || [ ! -e /dev/watchdog ]; then
    echo "WARNING: no supported hardware watchdog found on this board (checked" >&2
    echo "iTCO_wdt/sp5100_tco/wdat_wdt). Skipping watchdog arming; lockup-panic" >&2
    echo "sysctls below will still be applied." >&2
else
    echo "$loaded" > /etc/modules-load.d/crashwatch-watchdog.conf
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-crashwatch-watchdog.conf <<EOF
[Manager]
RuntimeWatchdogSec=20s
RebootWatchdogSec=10min
EOF
    systemctl daemon-reexec
    echo "armed: $loaded, systemd pets every ~10s, forces reset if unpetted for 20s"
fi

echo "== 2. convert silent lockups into a captured panic + auto-reboot =="
cat > /etc/sysctl.d/99-crashwatch-lockup.conf <<EOF
kernel.panic = 10
kernel.panic_on_oops = 1
kernel.hardlockup_panic = 1
kernel.softlockup_panic = 1
kernel.hung_task_panic = 1
kernel.hung_task_timeout_secs = $HUNG_TASK_TIMEOUT
kernel.panic_on_io_nmi = 1
kernel.panic_on_unrecovered_nmi = 1
EOF
sysctl --system >/dev/null

echo
echo "== crashwatch hardening applied =="
systemctl show | grep RuntimeWatchdogUSec || true
sysctl kernel.panic kernel.hardlockup_panic kernel.softlockup_panic kernel.hung_task_panic kernel.hung_task_timeout_secs
echo
echo "To undo: sudo ./unharden.sh"
