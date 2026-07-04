#!/usr/bin/env python3
"""crashwatch black-box telemetry.

Samples the machine's vital signs at 1 Hz and fsync()s every line to disk, so
that an instant hard reset / power loss / hard hang still leaves the final
second of state on disk. One append-only file per boot; the tail of the
*previous* boot's file is the pre-crash black box.

Pure stdlib + nvidia-smi. Runs as a root system service (see the .service unit).

Requires Python 3.9+ (uses PEP 585 builtin-generic annotations, e.g. list[str]).
"""
import glob
import os
import signal
import subprocess
import time

# Env overrides exist purely so the test suite can point the recorder at a temp
# dir and force a boot id. Production uses the defaults.
INTERVAL = float(os.environ.get("CRASHWATCH_INTERVAL", "1.0"))
DATA_DIR = os.environ.get("CRASHWATCH_DIR", "/var/log/crashwatch")
RETAIN_DAYS = 14
GPU_FIELDS = (
    "power.draw,power.limit,temperature.gpu,utilization.gpu,utilization.memory,"
    "clocks.sm,clocks.mem,pstate,memory.used,clocks_throttle_reasons.active,"
    "pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max,"
    "ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total"
)
GPU_FIELD_COUNT = GPU_FIELDS.count(",") + 1
HEADER = (
    "wall_iso,mono_s,cpu_pkg_c,load1,mem_avail_mb,psi_cpu_full_avg10,psi_mem_full_avg10,"
    "nvidia_irq_total,nvidia_smi_ms,gpu_idx,gpu_power_w,gpu_plimit_w,gpu_temp_c,gpu_util,"
    "gpu_memutil,gpu_sm_mhz,gpu_mem_mhz,pstate,gpu_mem_used_mib,throttle,pcie_gen_cur,"
    "pcie_gen_max,pcie_width_cur,pcie_width_max,ecc_corrected,ecc_uncorrected\n"
)

_running = True


def _stop(_signum, _frame):
    global _running
    _running = False


def boot_id() -> str:
    forced = os.environ.get("CRASHWATCH_BOOT_ID")
    if forced:
        return forced
    with open("/proc/sys/kernel/random/boot_id") as handle:
        return handle.read().strip().replace("-", "")[:12]


def read_cpu_temp() -> str:
    """Package/Tctl temperature in Celsius, read straight from hwmon sysfs."""
    for name_path in glob.glob("/sys/class/hwmon/hwmon*/name"):
        try:
            name = open(name_path).read().strip()
        except OSError:
            continue
        if name not in ("coretemp", "k10temp", "zenpower"):
            continue
        base = os.path.dirname(name_path)
        for label_path in glob.glob(base + "/temp*_label"):
            try:
                if any(tag in open(label_path).read() for tag in ("Package", "Tctl", "Tdie")):
                    value = open(label_path.replace("_label", "_input")).read().strip()
                    return f"{int(value) / 1000.0:.1f}"
            except OSError:
                continue
        try:
            value = open(base + "/temp1_input").read().strip()
            return f"{int(value) / 1000.0:.1f}"
        except OSError:
            continue
    return ""


def read_loadavg() -> str:
    try:
        return open("/proc/loadavg").read().split()[0]
    except OSError:
        return ""


def read_mem_avail_mb() -> str:
    try:
        for line in open("/proc/meminfo"):
            if line.startswith("MemAvailable:"):
                return str(int(line.split()[1]) // 1024)
    except OSError:
        pass
    return ""


def read_psi_full_avg10(path: str) -> str:
    """'full avg10' from /proc/pressure/{cpu,memory}: % of the last 10s ALL tasks
    spent stalled waiting on that resource. A climb here ahead of a freeze is a
    leading indicator of contention. Requires CONFIG_PSI (on by default on
    modern kernels); returns "" if unavailable.
    """
    try:
        for line in open(path):
            if line.startswith("full "):
                for field in line.split():
                    if field.startswith("avg10="):
                        return field.split("=", 1)[1]
    except OSError:
        pass
    return ""


def read_nvidia_irq_total() -> str:
    """Sum of all nvidia MSI-X interrupt counts (all vectors, all CPUs) from
    /proc/interrupts. A stall (stops climbing while the GPU is busy) or a storm
    (sudden spike) both point at the GPU/PCIe hardware rather than a pure
    software hang.
    """
    total = 0
    found = False
    try:
        with open("/proc/interrupts") as handle:
            for line in handle:
                if line.rstrip().endswith("nvidia"):
                    found = True
                    total += sum(int(tok) for tok in line.split()[1:] if tok.isdigit())
    except OSError:
        return ""
    return str(total) if found else ""


def system_is_shutting_down() -> bool:
    """True only during a real system shutdown/reboot — not a `systemctl restart`.

    Guards the clean-stop marker: without this, restarting the service (e.g. a
    reinstall) would drop a false "clean shutdown" marker and a later crash on
    the same boot would be missed.
    """
    forced = os.environ.get("CRASHWATCH_FORCE_SHUTDOWN_STATE")
    if forced is not None:
        return forced.strip() == "stopping"
    try:
        result = subprocess.run(
            ["systemctl", "is-system-running"], capture_output=True, text=True, timeout=5
        )
        return result.stdout.strip() == "stopping"
    except Exception:
        return False


def query_gpu() -> tuple[str, list[str]]:
    """Returns (elapsed_ms, csv_lines). elapsed_ms is itself a leading
    indicator: a GPU driver about to wedge typically answers slower before it
    fully hangs.

    Deliberately uses Popen + a non-blocking kill instead of
    subprocess.run(timeout=...): run()'s timeout path calls an UNBOUNDED
    process.wait() after kill(), which would hang forever if nvidia-smi itself
    is stuck in an uninterruptible kernel wait (D-state) on a wedged GPU --
    exactly the scenario this recorder exists to survive.
    """
    start = time.monotonic()
    try:
        proc = subprocess.Popen(
            ["nvidia-smi", f"--query-gpu={GPU_FIELDS}", "--format=csv,noheader,nounits"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            start_new_session=True,
        )
    except Exception:
        return "", []
    try:
        stdout, _ = proc.communicate(timeout=5)
        elapsed_ms = f"{(time.monotonic() - start) * 1000:.0f}"
        return elapsed_ms, [line.strip() for line in stdout.strip().splitlines() if line.strip()]
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        if proc.stdout:
            proc.stdout.close()
        try:
            os.waitpid(proc.pid, os.WNOHANG)  # opportunistic reap; never blocks
        except OSError:
            pass
        return f"{(time.monotonic() - start) * 1000:.0f}", []
    except Exception:
        return f"{(time.monotonic() - start) * 1000:.0f}", []


def cleanup_old(now: float) -> None:
    for old in glob.glob(os.path.join(DATA_DIR, "telemetry-*.csv")):
        try:
            if now - os.path.getmtime(old) > RETAIN_DAYS * 86400:
                os.remove(old)
        except OSError:
            continue


def main() -> None:
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    os.makedirs(DATA_DIR, exist_ok=True)
    bid = boot_id()
    path = os.path.join(DATA_DIR, f"telemetry-{bid}.csv")

    # If a schema upgrade (e.g. new columns) happens mid-boot, the existing file
    # still has the OLD header on line 1. Appending new-shape rows under it would
    # silently misalign every downstream column read. Rotate it aside instead.
    if os.path.exists(path):
        try:
            with open(path) as existing:
                if existing.readline() != HEADER:
                    os.replace(path, path + ".old")
        except OSError:
            pass

    is_new = not os.path.exists(path)

    # A clean marker for the CURRENT boot is stale by definition (we are running
    # on this boot right now) — e.g. left behind by a `systemctl restart`. Drop
    # it so a later crash on this same boot is still detected.
    try:
        os.remove(os.path.join(DATA_DIR, f"clean-{bid}"))
    except OSError:
        pass

    cleanup_old(time.time())

    with open(path, "a", buffering=1) as out:
        if is_new:
            out.write(HEADER)
            out.flush()
            os.fsync(out.fileno())
        while _running:
            start = time.monotonic()
            wall = time.strftime("%Y-%m-%dT%H:%M:%S")
            cpu = read_cpu_temp()
            load = read_loadavg()
            mem = read_mem_avail_mb()
            psi_cpu = read_psi_full_avg10("/proc/pressure/cpu")
            psi_mem = read_psi_full_avg10("/proc/pressure/memory")
            irq = read_nvidia_irq_total()
            smi_ms, gpus = query_gpu()
            gpus = gpus or [",".join([""] * GPU_FIELD_COUNT)]  # still record host metrics if GPU query fails
            for idx, gpu in enumerate(gpus):
                out.write(
                    f"{wall},{start:.1f},{cpu},{load},{mem},{psi_cpu},{psi_mem},"
                    f"{irq},{smi_ms},{idx},{gpu}\n"
                )
            out.flush()
            os.fsync(out.fileno())
            elapsed = time.monotonic() - start
            if elapsed < INTERVAL:
                time.sleep(INTERVAL - elapsed)

    # Only on a real system shutdown/reboot: drop a marker so the post-mortem
    # knows THIS boot ended cleanly and is not a crash. A bare service
    # restart/stop must NOT write it (see system_is_shutting_down).
    if system_is_shutting_down():
        try:
            with open(os.path.join(DATA_DIR, f"clean-{bid}"), "w") as marker:
                marker.write(time.strftime("%Y-%m-%dT%H:%M:%S\n"))
                marker.flush()
                os.fsync(marker.fileno())
        except OSError:
            pass


if __name__ == "__main__":
    main()
