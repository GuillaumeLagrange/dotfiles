#!/usr/bin/env python3
"""Long-lived emitter for the bar's sampled system metrics (CPU, memory/swap,
disk, battery), as a single JSON line per tick.

This is a `deflisten` rather than one `defpoll` per metric on purpose. eww runs
defpoll commands through a blocking `Command::output()` on its script-var
runtime, so a script that takes N ms parks a worker thread for N ms; listen-vars
are read asynchronously and never do. Every metric here also reads straight from
procfs/sysfs, which is far cheaper than the process tree a shell equivalent
needs (a `date`/`jq`/`awk` fork per field).

Sampling CPU also *requires* a persistent process: utilisation is a delta
between two /proc/stat snapshots, so a stateless per-tick script has to sleep
for its sample window. Here the previous snapshot is kept in memory and the tick
interval is the window, which is both free and a more representative average.

Emits one line, shaped so the yuck can use fields directly (no simplexpr-side
JSON re-parsing or class/glyph derivation):
  {"cpu":{"usage":"42","tooltip":"..."},
   "memswap":{"text":"...","class":"ok","tooltip":"..."},
   "disk":{"free":"123.5GiB","tooltip":"..."},
   "battery":{"capacity":93,"charging":false,"class":"...","text":"...","tooltip":"..."}}
"""

import json
import os
import shutil
import sys
import time
from pathlib import Path

# Per-metric sampling periods. The tick is the GCD-ish base; each metric is
# recomputed when its own period has elapsed, so the cheap ones stay responsive
# without the expensive ones running needlessly often.
TICK_S = 1.0
CPU_PERIOD_S = 3.0
MEMSWAP_PERIOD_S = 5.0
DISK_PERIOD_S = 30.0
BATTERY_PERIOD_S = 30.0

# nf-md-battery glyphs. Charging shows the bolt-in-battery icon regardless of
# level, so only the discharging tiers need a ramp.
BAT_ICON_HIGH = "󱊣"
BAT_ICON_MEDIUM = "󱊢"
BAT_ICON_LOW = "󱊡"
BAT_ICON_CHARGING = "󰂄"

# The memory widget renders with `:markup`, so Pango resolves these to glyphs.
# Emitting the entities rather than literal characters keeps the payload ASCII
# through eww's var pipeline.
RAM_GLYPH = "&#xf061a;"
ZRAM_GLYPH = "&#xf140b;"


def human_kib(kib: float) -> str:
    """KiB -> "123.5GiB" (integer for bytes, one decimal above)."""
    b = kib * 1024
    for i, unit in enumerate(("B", "KiB", "MiB", "GiB", "TiB", "PiB")):
        if b < 1024 or i == 5:
            return f"{b:.0f}{unit}" if i == 0 else f"{b:.1f}{unit}"
        b /= 1024
    return f"{b:.1f}PiB"


def human_short(kib: float) -> str:
    """KiB -> "5.2G" / "512M", matching the memory widget's compact form."""
    if kib >= 1048576:
        return f"{kib / 1048576:.1f}G"
    return f"{kib / 1024:.0f}M"


def read_stat() -> dict[str, tuple[int, int]]:
    """Every cpu line (aggregate "cpu" + per-core "cpuN") as (total, idle)."""
    out = {}
    with open("/proc/stat") as f:
        for line in f:
            name, _, rest = line.partition(" ")
            if not (name == "cpu" or (name.startswith("cpu") and name[3:].isdigit())):
                continue
            v = [int(x) for x in rest.split()]
            user, nice, system, idle, iowait, irq, softirq, steal = v[:8]
            idle_all = idle + iowait
            busy = user + nice + system + irq + softirq + steal
            out[name] = (busy + idle_all, idle_all)
    return out


class Cpu:
    """Aggregate CPU usage % plus a per-core breakdown for the tooltip, as a
    delta between consecutive ticks."""

    def __init__(self) -> None:
        self.prev = read_stat()

    def sample(self) -> dict:
        cur = read_stat()

        def pct(name: str) -> int:
            t2, i2 = cur[name]
            t1, i1 = self.prev.get(name, (0, 0))
            dt, di = t2 - t1, i2 - i1
            return (dt - di) * 100 // dt if dt > 0 else 0

        cores = sorted(
            (n for n in cur if n != "cpu"),
            key=lambda n: int(n[3:]),
        )
        # Pad each label to the widest one so the "%" column stays aligned when
        # core counts cross into two digits (cpu0: ... cpu11:). The colon is part
        # of what gets padded, or the single-digit rows come up a column short.
        labels = {n: n + ":" for n in cores}
        width = max((len(x) for x in labels.values()), default=0)
        tooltip = "\n".join(f"{labels[n]:<{width}} {pct(n)}%" for n in cores)

        usage = pct("cpu")
        self.prev = cur
        # Zero-padded to a fixed width so the label never changes length and
        # shifts every module to its right as usage crosses 10% or 100%.
        return {"usage": f"{usage:02d}", "tooltip": tooltip}


def sample_memswap() -> dict:
    """RAM usage % with per-device swap, so zram (in-RAM compressed) and disk
    swap can be told apart at a glance."""
    total = avail = 0
    with open("/proc/meminfo") as f:
        for line in f:
            key, _, rest = line.partition(":")
            if key == "MemTotal":
                total = int(rest.split()[0])
            elif key == "MemAvailable":
                avail = int(rest.split()[0])
    ram_pct = (total - avail) * 100 // total if total > 0 else 0

    # /proc/swaps "Used" is the uncompressed page count, in KiB.
    zram_used = disk_used = 0
    with open("/proc/swaps") as f:
        next(f, None)  # header row
        for line in f:
            fields = line.split()
            if len(fields) < 4:
                continue
            used = int(fields[3])
            if fields[0].startswith("/dev/zram"):
                zram_used += used
            else:
                disk_used += used

    # Field 3 of /sys/block/zramN/mm_stat is mem_used_total, in bytes: the
    # actual RAM the compressed pages occupy.
    zram_real = 0
    for mm in Path("/sys/block").glob("zram*/mm_stat"):
        try:
            zram_real += int(mm.read_text().split()[2]) // 1024
        except (OSError, IndexError, ValueError):
            continue

    zram_raw_h = human_short(zram_used)
    return {
        # zram shows uncompressed pages -> real RAM cost, e.g. "5.2G->1.3G".
        "text": f"{RAM_GLYPH} {ram_pct}%",
        # Disk spill is the signal worth surfacing: past zram, hitting slow
        # storage. Kept at "ok" until something actually lands there.
        "class": "ok",
        "tooltip": (
            f"RAM {ram_pct}% used\n"
            f"zram {zram_raw_h} pages → {human_short(zram_real)} in RAM\n"
            f"disk swap {human_short(disk_used)}"
        ),
    }


def sample_disk() -> dict:
    """Free space on the root filesystem (one decimal, binary units with the iB
    suffix), plus a used/total and percentage tooltip."""
    du = shutil.disk_usage("/")
    avail_kib = du.free / 1024
    used_kib = du.used / 1024
    total_kib = du.total / 1024
    # df's percentage is used/(used+avail), which excludes reserved blocks.
    denom = du.used + du.free
    pcent = round(du.used * 100 / denom) if denom else 0
    return {
        "free": human_kib(avail_kib),
        "tooltip": (
            f"{human_kib(used_kib)} used out of {human_kib(total_kib)} on / ({pcent}%)"
        ),
    }


HIDDEN_BATTERY = {
    "capacity": 0,
    "charging": False,
    "class": "hidden",
    "text": "",
    "tooltip": "",
}


def sample_battery() -> dict:
    """Capacity, charging state, and a time-to-full/empty estimate."""
    bat = next(iter(sorted(Path("/sys/class/power_supply").glob("BAT*"))), None)
    if bat is None:
        return dict(HIDDEN_BATTERY)

    def read(name: str) -> str | None:
        try:
            return (bat / name).read_text().strip()
        except OSError:
            return None

    try:
        capacity = int(read("capacity") or 0)
    except ValueError:
        return dict(HIDDEN_BATTERY)
    status = read("status") or "Unknown"

    charging = status in ("Charging", "Full")
    if charging:
        cls = "charging"
    elif capacity <= 15:
        cls = "critical"
    else:
        cls = "discharging"

    if charging:
        icon = BAT_ICON_CHARGING
    elif capacity >= 67:
        icon = BAT_ICON_HIGH
    elif capacity >= 34:
        icon = BAT_ICON_MEDIUM
    else:
        icon = BAT_ICON_LOW
    text = f"{icon} {capacity}%"

    # Time estimate from energy/charge counters (µWh & µW, or µAh & µA).
    def read_int(name: str) -> int | None:
        v = read(name)
        try:
            return int(v) if v is not None else None
        except ValueError:
            return None

    now = full = rate = None
    energy_now, power_now = read_int("energy_now"), read_int("power_now")
    charge_now, current_now = read_int("charge_now"), read_int("current_now")
    if energy_now is not None and power_now is not None:
        now, full, rate = energy_now, read_int("energy_full"), power_now
    elif charge_now is not None and current_now is not None:
        now, full, rate = charge_now, read_int("charge_full"), current_now

    eta = ""
    if rate and rate > 0 and now is not None:
        if charging:
            remaining = (full - now) if full is not None else 0
            label = "until full"
        else:
            remaining, label = now, "remaining"
        if remaining > 0:
            mins = remaining * 60 // rate
            eta = f"{mins // 60}h{mins % 60:02d}m {label}"

    tooltip = f"Battery {capacity}% — {status}"
    if eta:
        tooltip = f"{tooltip}\n{eta}"

    return {
        "capacity": capacity,
        "charging": charging,
        "class": cls,
        "text": text,
        "tooltip": tooltip,
    }


def main() -> int:
    cpu = Cpu()
    state = {
        "cpu": {"usage": "00", "tooltip": ""},
        "memswap": sample_memswap(),
        "disk": sample_disk(),
        "battery": sample_battery(),
    }
    last = {"cpu": 0.0, "memswap": 0.0, "disk": 0.0, "battery": 0.0}

    # Monotonic so a wall-clock jump (suspend/resume, NTP step) can't stall a
    # metric until its period elapses again.
    started = time.monotonic()
    print(json.dumps(state, separators=(",", ":")), flush=True)

    while True:
        time.sleep(TICK_S)
        now = time.monotonic() - started
        changed = False
        for key, period, fn in (
            ("cpu", CPU_PERIOD_S, cpu.sample),
            ("memswap", MEMSWAP_PERIOD_S, sample_memswap),
            ("disk", DISK_PERIOD_S, sample_disk),
            ("battery", BATTERY_PERIOD_S, sample_battery),
        ):
            if now - last[key] < period:
                continue
            last[key] = now
            try:
                fresh = fn()
            except OSError as e:
                print(f"{key}: {e}", file=sys.stderr, flush=True)
                continue
            if fresh != state[key]:
                state[key] = fresh
                changed = True

        # Re-rendering is synchronous on eww's GTK thread, so only emit when a
        # value actually moved.
        if changed:
            print(json.dumps(state, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyboardInterrupt, BrokenPipeError):
        # The reader going away (daemon exit/reload) is a normal shutdown, not a
        # fault worth a traceback on eww's stderr. Python flushes stdout again on
        # interpreter exit, which would re-raise onto the dead pipe, so retarget
        # the fd before returning.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        sys.exit(0)
