# crashwatch

A tiny "black box" flight recorder for Linux machines that **reset or freeze
without leaving any trace in the logs** — the frustrating class of failure where
`journalctl` just stops mid-sentence and the next line is the following boot.

That silence happens because the machine dies before it can write anything.
crashwatch works around it two ways:

1. **Telemetry recorder** — samples vital signs at 1 Hz and `fsync()`s every line
   to disk, so whatever the *last written line* is, it survives an instant power
   cut. After a crash, the tail of the previous boot's file is the machine's
   final second.
2. **Boot-time post-mortem** — on every boot, detects whether the previous boot
   ended without a clean shutdown and, if so, writes a single report combining
   the pre-crash telemetry tail, any kernel-panic remnants (`pstore`), and the
   previous boot's last kernel lines.

It was built to diagnose spontaneous hard resets on a high-power GPU workstation
(where a PSU transient / power-delivery fault can reset the box with zero
software fingerprint), but it's useful for any "it just rebooted and I don't
know why" situation.

## What it records

Each 1 Hz sample (`/var/log/crashwatch/telemetry-<boot>.csv`):

| Field | Why it matters |
|-------|----------------|
| GPU power draw / limit | A spike toward the limit right before death points at power delivery / PSU |
| GPU temp, clocks, pstate, throttle bitmask | Distinguishes thermal / power-cap throttling from a clean cut |
| GPU util / mem used | What the GPU was doing at the moment of death |
| CPU package temp | Rules thermal in or out |
| load average, free RAM | Load spike / OOM pressure context |

## How to read a crash

After the next crash, the box boots and auto-writes a report:

```
/var/log/crashwatch/reports/crash-<timestamp>.txt
```

Interpretation cheatsheet:

- **Last samples show GPU watts spiking toward the limit / throttle bit set** → power / thermal.
- **It died at idle** → power-transient unlikely; look elsewhere.
- **`pstore` has content** → it was a *kernel panic*, not a power cut — the stack trace is included.
- **`pstore` empty + telemetry stops mid-stream + no panic** → instant hard reset (power / hardware).

## Install

Requires: Linux + systemd, **Python 3.9+** (stdlib only — no pip installs).
`nvidia-smi` optional (GPU fields are simply blank without it). `lm-sensors`
optional (nicer report).

```bash
git clone https://github.com/ysyyork/crashwatch.git
cd crashwatch
sudo ./install.sh
```

That installs the scripts to `/opt/crashwatch`, enables two systemd services,
and starts recording immediately. Verify:

```bash
systemctl status crashwatch-telemetry.service
tail -f /var/log/crashwatch/telemetry-*.csv
```

## Uninstall

```bash
sudo ./uninstall.sh          # removes services + programs, keeps data
sudo rm -rf /var/log/crashwatch   # also delete collected data
```

## Layout

```
telemetry.py                          # 1 Hz fsynced recorder
postmortem.sh                         # boot-time crash detector + report writer
systemd/crashwatch-telemetry.service  # runs the recorder
systemd/crashwatch-postmortem.service # runs the collector once at boot
install.sh / uninstall.sh
```

## Optional companions (not included, but recommended for hard hangs)

- **netconsole / remote syslog** — stream kernel messages to another machine on
  the LAN so a hard *hang's* dying words (GPU Xid, hung-task trace, panic) are
  captured off-box in real time.
- **"Loud hang" sysctls** — `kernel.panic_on_oops=1`, `kernel.hung_task_panic=1`,
  `kernel.softlockup_panic=1`, `kernel.panic=10` convert a silent freeze into a
  captured panic and auto-reboot.

## License

MIT — see [LICENSE](LICENSE).
