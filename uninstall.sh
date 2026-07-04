#!/usr/bin/env bash
# Remove crashwatch. Keeps collected data in /var/log/crashwatch by default.
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root:  sudo ./uninstall.sh" >&2
    exit 1
fi

systemctl disable --now crashwatch-telemetry.service 2>/dev/null || true
systemctl disable crashwatch-postmortem.service 2>/dev/null || true
rm -f /etc/systemd/system/crashwatch-telemetry.service \
      /etc/systemd/system/crashwatch-postmortem.service
systemctl daemon-reload
rm -rf /opt/crashwatch

echo "crashwatch programs + units removed."
echo "Collected data kept in /var/log/crashwatch (run 'sudo rm -rf /var/log/crashwatch' to delete)."
