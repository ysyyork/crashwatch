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
    "clocks.sm,clocks.mem,pstate,memory.used,clocks_throttle_reasons.active"
)
HEADER = (
    "wall_iso,mono_s,cpu_pkg_c,load1,mem_avail_mb,gpu_idx,gpu_power_w,gpu_plimit_w,"
    "gpu_temp_c,gpu_util,gpu_memutil,gpu_sm_mhz,gpu_mem_mhz,pstate,gpu_mem_used_mib,throttle\n"
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


def query_gpu() -> list[str]:
    try:
        result = subprocess.run(
            ["nvidia-smi", f"--query-gpu={GPU_FIELDS}", "--format=csv,noheader,nounits"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        return [line.strip() for line in result.stdout.strip().splitlines() if line.strip()]
    except Exception:
        return []


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
            gpus = query_gpu() or [",,,,,,,,,"]  # still record host metrics if GPU query fails
            for idx, gpu in enumerate(gpus):
                out.write(f"{wall},{start:.1f},{cpu},{load},{mem},{idx},{gpu}\n")
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
