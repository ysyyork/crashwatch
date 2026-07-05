#!/usr/bin/env bash
# Loads netconsole, retrying past network-not-ready-yet at boot: netconsole
# needs its local interface to already have the configured source IP bound
# (e.g. via DHCP), which is not guaranteed at the point a bare modules-load.d
# entry would fire -- the same class of early-boot race that silently defeated
# the hardware watchdog module (see arm-watchdog.sh). Ordered after
# network-online.target instead, with a retry loop as a second line of defense.
#
# Config comes from /etc/crashwatch/netconsole.env (see netconsole.env.example):
#   NETCONSOLE_LOCAL_PORT, NETCONSOLE_LOCAL_IP, NETCONSOLE_LOCAL_DEV,
#   NETCONSOLE_REMOTE_PORT, NETCONSOLE_REMOTE_IP, NETCONSOLE_REMOTE_MAC
set -uo pipefail

ENV_FILE="/etc/crashwatch/netconsole.env"
if [ ! -f "$ENV_FILE" ]; then
    logger -t crashwatch "netconsole: $ENV_FILE missing, skipping"
    exit 0
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

for var in NETCONSOLE_LOCAL_PORT NETCONSOLE_LOCAL_IP NETCONSOLE_LOCAL_DEV \
           NETCONSOLE_REMOTE_PORT NETCONSOLE_REMOTE_IP NETCONSOLE_REMOTE_MAC; do
    if [ -z "${!var:-}" ]; then
        logger -t crashwatch "netconsole: $var not set in $ENV_FILE, skipping"
        exit 0
    fi
done

TARGET="${NETCONSOLE_LOCAL_PORT}@${NETCONSOLE_LOCAL_IP}/${NETCONSOLE_LOCAL_DEV},${NETCONSOLE_REMOTE_PORT}@${NETCONSOLE_REMOTE_IP}/${NETCONSOLE_REMOTE_MAC}"

for attempt in 1 2 3 4 5 6 7 8 9 10; do
    # Wait for the local interface to actually have the configured IP (DHCP
    # may still be in flight even after network-online.target on some setups).
    if ip -4 addr show "$NETCONSOLE_LOCAL_DEV" 2>/dev/null | grep -q "inet ${NETCONSOLE_LOCAL_IP}/"; then
        modprobe -r netconsole 2>/dev/null  # in case a prior attempt half-loaded
        if modprobe netconsole "netconsole=${TARGET}" 2>/dev/null; then
            logger -t crashwatch "netconsole armed: ${TARGET} (attempt $attempt)"
            exit 0
        fi
    fi
    sleep 2
done
logger -t crashwatch "WARNING: netconsole could not be armed after retries (target ${TARGET}) -- kernel messages will not be streamed off-box on this boot"
exit 0
