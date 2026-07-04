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

## Hardening: `harden.sh` (optional, changes reboot behavior)

The passive recorder only *observes*. It cannot make a silent total freeze
(fans/lights on, no video, no network, no input — a full scheduler lockup)
produce a diagnosable trace or even recover on its own: without a hardware
watchdog, that class of failure just sits dead until someone manually
power-cycles it, and even when the kernel's own lockup detectors *do* notice,
by default they only print a warning instead of panicking — so if local
logging is also stalled, that warning is lost forever.

`harden.sh` closes both gaps:

1. **Arms a hardware watchdog** (`iTCO_wdt` on most Intel boards,
   `sp5100_tco`/`wdat_wdt` as fallbacks) via systemd's `RuntimeWatchdogSec`.
   systemd pets it periodically from a kernel timer independent of anything in
   userspace; if the scheduler itself freezes, the pets stop and the chipset
   forces a hardware reset — no more sitting dead indefinitely.
2. **Converts silent lockup detection into a captured panic + auto-reboot** via
   `kernel.hardlockup_panic`, `kernel.softlockup_panic`, `kernel.hung_task_panic`,
   `kernel.panic_on_oops`, `kernel.panic_on_io_nmi`, `kernel.panic_on_unrecovered_nmi`,
   and `kernel.panic=10`. When the kernel *can* detect the problem, this makes
   it write to `pstore` and reboot automatically instead of printing a warning
   that dies with the machine.

```bash
sudo ./harden.sh
sudo ./unharden.sh   # revert
```

**Trade-off — read before running:** a transient stall that might previously
have self-recovered will now force a reboot. In particular
`kernel.hung_task_panic=1` fires if *any* task sits in an uninterruptible wait
for `kernel.hung_task_timeout_secs` (default 120s) — on a box doing heavy
Docker/GPU/disk work, a legitimately slow (not actually hung) I/O operation
could in principle hit that window. Raise the timeout if you want more
headroom: `CRASHWATCH_HUNG_TASK_TIMEOUT=300 sudo -E ./harden.sh`.

**Ceiling on what this buys you:** if the freeze is severe enough that even
NMI delivery is blocked (a true hardware-level paralysis, not just a wedged
driver), no software-side detector runs at all — only the independent hardware
watchdog timer will still fire, which is why both layers exist together. And
even the watchdog can't tell you *why* it froze, only that it did; for that,
pair this with **netconsole** to a second always-on machine on your LAN, which
streams kernel messages off-box in real time and can catch a final message
that never made it to local disk.

## License

MIT — see [LICENSE](LICENSE).
