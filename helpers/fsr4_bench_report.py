#!/usr/bin/env python3
"""Summarize raw MangoHud frame-time CSV captures, no synthetic FPS values."""
import csv
import math
import statistics
import sys
from pathlib import Path

MODES = ("default", "cyboman", "v3")


def parse(path: Path):
    try:
        with path.open(encoding="utf-8-sig", newline="", errors="replace") as f:
            rows = csv.reader(f)
            header = None
            frames = []
            for row in rows:
                clean = [c.strip().lower() for c in row]
                if header is None:
                    if "frametime" in clean and "fps" in clean:
                        header = clean
                        ms_index = clean.index("frametime")
                    continue
                if len(row) <= ms_index:
                    continue
                try:
                    ms = float(row[ms_index].strip())
                except ValueError:
                    continue
                if math.isfinite(ms) and 0.1 < ms < 500:
                    frames.append(ms)
    except (OSError, csv.Error) as e:
        print(f"SKIP {path}: {e}", file=sys.stderr)
        return None
    if len(frames) < 100:
        print(f"SKIP {path}: fewer than 100 valid frame times", file=sys.stderr)
        return None
    frames.sort()
    tail = max(1, math.ceil(len(frames) * .01))
    return {
        "frames": len(frames),
        "mean_fps": 1000 * len(frames) / sum(frames),
        "one_percent_low": 1000 / statistics.mean(frames[-tail:]),
        "p99_ms": frames[min(len(frames) - 1, math.ceil(len(frames) * .99) - 1)],
    }


def main(directory: Path):
    print(f"MangoHud results from {directory}")
    if not directory.is_dir():
        raise SystemExit("No results directory. Run the benchmark first on BC250.")
    measurements = {}
    for mode in MODES:
        captures = []
        for path in sorted((directory / mode).glob("**/*.csv")):
            data = parse(path)
            if data is not None:
                captures.append((path, data))
        measurements[mode] = captures
        if not captures:
            print(f"{mode:8}: NO CAPTURES")
            continue
        for path, data in captures:
            print(f"{mode:8}: {data['mean_fps']:7.2f} FPS | 1% low {data['one_percent_low']:7.2f} "
                  f"| P99 {data['p99_ms']:6.2f} ms | {data['frames']:6} frames | {path.name}")
        fps = [v["mean_fps"] for _, v in captures]
        spread = statistics.stdev(fps) if len(fps) > 1 else float("nan")
        print(f"  Mean of captures: {statistics.mean(fps):.2f} FPS; run-to-run SD: {spread:.2f} FPS; n={len(fps)}")
        if len(captures) < 3:
            print("  INCOMPLETE: need at least 3 clean captures for this mode")
    base = [x["mean_fps"] for _, x in measurements["default"]]
    if not base:
        print("No baseline: cannot calculate FPS gains.")
        return
    baseline = statistics.mean(base)
    for mode in MODES[1:]:
        fps = [x["mean_fps"] for _, x in measurements[mode]]
        if fps:
            avg = statistics.mean(fps)
            print(f"{mode} vs default: {100 * (avg / baseline - 1):+.2f}% average FPS "
                  f"({'PROVISIONAL' if len(fps) < 3 or len(base) < 3 else '3+ repeats'})")
    print("Results do NOT prove bit-exactness or active FSR4 shader overrides.")
    print("Check OptiScaler in-game, shader-dump compatibility, image quality and GPU faults.")


if __name__ == "__main__":
    main(Path(sys.argv[1]).expanduser() if len(sys.argv) > 1 else Path.home())
