#!/usr/bin/env bash
# Install crashwatch: telemetry recorder + boot-time post-mortem collector.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root:  sudo ./install.sh" >&2
    exit 1
fi

SRC="$(cd "$(dirname "$0")" && pwd)"

install -d /opt/crashwatch /var/log/crashwatch /var/log/crashwatch/reports
install -m 0755 "$SRC/telemetry.py"  /opt/crashwatch/telemetry.py
install -m 0755 "$SRC/postmortem.sh" /opt/crashwatch/postmortem.sh
install -m 0644 "$SRC/systemd/crashwatch-telemetry.service"  /etc/systemd/system/crashwatch-telemetry.service
install -m 0644 "$SRC/systemd/crashwatch-postmortem.service" /etc/systemd/system/crashwatch-postmortem.service

systemctl daemon-reload
systemctl enable --now crashwatch-telemetry.service
systemctl enable crashwatch-postmortem.service

echo "== crashwatch installed =="
echo "telemetry -> /var/log/crashwatch/telemetry-<boot>.csv"
echo "reports   -> /var/log/crashwatch/reports/crash-*.txt"
systemctl --no-pager --lines=0 status crashwatch-telemetry.service | head -4
