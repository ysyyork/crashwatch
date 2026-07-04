#!/usr/bin/env bash
# Arms the hardware watchdog module, retrying past the early-boot race where
# systemd-modules-load.service (which runs very early) can silently no-op:
# iTCO_wdt's underlying PCH/MFD platform device isn't always enumerated yet at
# that point in boot, so modprobe "succeeds" (module inserted) without the
# driver actually binding to anything -- no error, no /dev/watchdog, and
# systemd never picks up a watchdog to pet for the rest of that boot.
#
# Ordered later in boot (sysinit.target) than modules-load.service, which
# already gives PCI/platform enumeration more time -- the retry loop is a
# second line of defense on top of that.
set -uo pipefail

for mod in iTCO_wdt sp5100_tco wdat_wdt; do
    for attempt in 1 2 3 4 5; do
        modprobe "$mod" 2>/dev/null
        if [ -e /dev/watchdog ]; then
            logger -t crashwatch "hardware watchdog armed via $mod (attempt $attempt)"
            exit 0
        fi
        sleep 1
    done
done
logger -t crashwatch "WARNING: no hardware watchdog could be armed after retries -- crashwatch cannot force-recover from a total freeze on this boot"
exit 0
