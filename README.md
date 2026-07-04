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

It was built to diagnose spontaneous hard resets and total freezes on a
high-power GPU workstation, but it's useful for any "it just died and I don't
know why" situation — whether that's an instant power cut (screen dies with the
rest of the machine) or a hard hang (fans/lights stay on, but no video, no
network, no input — see below for why that distinction matters).

## What it records

Each 1 Hz sample (`/var/log/crashwatch/telemetry-<boot>.csv`):

| Field | Why it matters |
|-------|----------------|
| GPU power draw / limit | A spike toward the limit right before death points at power delivery / PSU |
| GPU temp, clocks, pstate, throttle bitmask | Distinguishes thermal / power-cap throttling from a clean cut |
| GPU util / mem used | What the GPU was doing at the moment of death |
| `nvidia_smi_ms` | Wall time of the GPU query itself — a driver about to wedge often answers slower before it fully hangs |
| PCIe link gen/width (current vs. max) | A link that has dropped from its max (e.g. Gen5x16 → Gen1x1) points at a GPU/PCIe hardware fault |
| ECC corrected/uncorrected totals | `N/A` on consumer GPUs (no ECC); meaningful on datacenter cards |
| `nvidia_irq_total` | Sum of all GPU MSI-X interrupt counts — a stall (stops climbing while busy) or storm (spikes) implicates the GPU/PCIe hardware |
| CPU package temp | Rules thermal in or out |
| PSI `full avg10` (CPU, memory) | % of the last 10s ALL tasks were stalled on that resource — a climb ahead of a freeze is a leading indicator of contention |
| load average, free RAM | Load spike / OOM pressure context |

The GPU query itself is hardened against being part of the problem: it runs via
`Popen` with a non-blocking kill on timeout rather than
`subprocess.run(timeout=...)`, because `run()`'s timeout path calls an
*unbounded* `wait()` after killing the child — which would hang the recorder
forever if `nvidia-smi` itself is stuck in an uninterruptible kernel wait
(D-state) on a wedged GPU. That's exactly the scenario this tool exists to
survive, so the recorder must never be able to join the hang it's trying to
observe.

## How to read a crash

After the next crash, the box boots and auto-writes a report:

```
/var/log/crashwatch/reports/crash-<timestamp>.txt
```

Interpretation cheatsheet:

- **Front-panel LED / fans died along with everything else** → real power loss. Look at GPU watts in the last samples: a spike toward the limit points at power delivery / PSU; idle at time of death means look elsewhere.
- **LED/fans stayed on, but no video output, no network, no input** → this is a **hard freeze**, not a power cut — the CPU stopped scheduling entirely. It is *not* proof the GPU caused it: when the whole scheduler halts, video/network/input all stop together as equally-downstream symptoms, whether or not the GPU was the root cause. Check `nvidia_smi_ms` and the IRQ/PCIe columns in the seconds before death for a real leading indicator instead of inferring cause from "no video" alone.
- **`pstore` has content** → it was a *kernel panic*, not a silent freeze — the stack trace is included.
- **`pstore` empty + telemetry stops mid-stream + no panic** → the freeze was total enough that not even the kernel's own panic/NMI-watchdog path could run or flush. See "companions" below for how to catch this in real time on the *next* occurrence.

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

## Testing

The suite mock-tests the whole flow **without crashing anything** — it runs the
real recorder against a temp dir with a fake `nvidia-smi`, simulates a power
loss (`kill -9`, no clean marker) vs. a clean shutdown (`SIGTERM`, marker
written), and asserts the post-mortem produces (or suppresses) a report
accordingly. No dependencies beyond `python3` + coreutils:

```bash
./tests/run_tests.sh
```

The scripts honor a few `CRASHWATCH_*` env overrides (data dir, sample interval,
boot id, pstore dir) purely so the tests can redirect them; production uses the
defaults.

## Optional companions (not included, but recommended for hard hangs)

- **netconsole / remote syslog** — stream kernel messages to another machine on
  the LAN so a hard *hang's* dying words (GPU Xid, hung-task trace, panic) are
  captured off-box in real time.
- **"Loud hang" sysctls** — `kernel.panic_on_oops=1`, `kernel.hung_task_panic=1`,
  `kernel.softlockup_panic=1`, `kernel.panic=10` convert a silent freeze into a
  captured panic and auto-reboot.

## License

MIT — see [LICENSE](LICENSE).
