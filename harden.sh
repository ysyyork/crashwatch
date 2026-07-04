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
SRC="$(cd "$(dirname "$0")" && pwd)"
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
    # NOTE: do NOT rely on /etc/modules-load.d alone. It's loaded by
    # systemd-modules-load.service, which runs very early in boot -- early
    # enough that iTCO_wdt's underlying PCH/MFD platform device is sometimes
    # not enumerated yet. In that case modprobe silently "succeeds" (module
    # inserted) without the driver binding to anything: no error, no
    # /dev/watchdog, and systemd never pets a watchdog for the rest of that
    # boot -- silently defeating the whole point of this script. Confirmed
    # happening in practice on this exact board. arm-watchdog.sh runs later
    # in boot and retries, which is the actual fix.
    install -m 0755 "$SRC/arm-watchdog.sh" /opt/crashwatch/arm-watchdog.sh
    install -m 0644 "$SRC/systemd/crashwatch-watchdog-arm.service" /etc/systemd/system/crashwatch-watchdog-arm.service
    systemctl daemon-reload
    systemctl enable --now crashwatch-watchdog-arm.service
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-crashwatch-watchdog.conf <<EOF
[Manager]
RuntimeWatchdogSec=20s
RebootWatchdogSec=10min
EOF
    systemctl daemon-reexec
    sleep 1
    if [ -e /dev/watchdog ]; then
        echo "armed: $loaded, systemd pets every ~10s, forces reset if unpetted for 20s"
    else
        echo "WARNING: /dev/watchdog still absent after arm-watchdog.sh ran -- check" >&2
        echo "'journalctl -t crashwatch' and 'systemctl status crashwatch-watchdog-arm.service'" >&2
    fi
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
