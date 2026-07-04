#!/usr/bin/env bash
# Reverse harden.sh: disarm the hardware watchdog and restore default
# (non-panicking) lockup behavior.
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root:  sudo ./unharden.sh" >&2
    exit 1
fi

systemctl disable --now crashwatch-watchdog-arm.service 2>/dev/null || true
rm -f /etc/systemd/system/crashwatch-watchdog-arm.service
rm -f /opt/crashwatch/arm-watchdog.sh
rm -f /etc/systemd/system.conf.d/99-crashwatch-watchdog.conf
rm -f /etc/modules-load.d/crashwatch-watchdog.conf   # stale from older crashwatch versions
rm -f /etc/sysctl.d/99-crashwatch-lockup.conf
systemctl daemon-reload
systemctl daemon-reexec
sysctl --system >/dev/null

echo "crashwatch hardening removed. Reboot to fully unload the watchdog module."
