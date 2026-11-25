#!/usr/bin/env python3
"""Portable engine-neutral comparison reducer. Stdlib only, no GPU/present claims."""
import argparse
import csv
import hashlib
import json
import math
from pathlib import Path
from statistics import mean

SCHEMA = "sandbox_comparison_result_v1"
REQUIRED = {"t_s", "interval_ms"}


def percentile(values, p):
    ordered = sorted(values)
    if not ordered:
        raise ValueError("no measurements")
    return ordered[max(0, min(len(ordered)-1, math.ceil(p*len(ordered))-1))]


def low_fps(values, fraction):
    ordered = sorted(values, reverse=True)
    n = max(1, math.ceil(len(values)*fraction))
    return 1000.0 / mean(ordered[:n])


def parse_csv(path, minimum=100):
    with Path(path).open(newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        if not REQUIRED.issubset(reader.fieldnames or []):
            raise ValueError("missing t_s/interval_ms columns")
        rows = [(float(r["t_s"]), float(r["interval_ms"])) for r in reader]
    if len(rows) < minimum:
        raise ValueError(f"incomplete trace: {len(rows)} frames, minimum {minimum}")
    prior = -1.0
    for t, ms in rows:
        if not math.isfinite(t) or not math.isfinite(ms) or t < prior or t < 0 or ms <= 0 or ms > 2000:
            raise ValueError(f"invalid or nonmonotonic row: t={t}, interval={ms}")
        prior = t
    return rows


def reduce_trace(rows, scenario, environment):
    contract = json.loads(Path(scenario).read_text(encoding="utf-8"))
    if contract.get("schema") != "sandbox_comparison_contract_v1":
        raise ValueError("incorrect contract schema")
    if contract.get("duration_s") != 46 or contract.get("warmup_s") != 12:
        raise ValueError("unexpected timing contract")
    if environment.get("scenario_id") != contract["id"]:
        raise ValueError("environment scenario mismatch")
    if environment.get("render_mode") not in ("interactive", "gpu_headless", "cpu_headless"):
        raise ValueError("unknown render mode")
    if environment.get("engine") not in ("godot_voxel_tools", "rust_bevy"):
        raise ValueError("engine not specified")
    if rows[0][0] < contract["warmup_s"] or rows[-1][0] < contract["duration_s"] - 0.5:
        raise ValueError("trace omits required steady-state range")
    vals = [ms for _, ms in rows]
    count = len(vals)
    result = {
        "schema": SCHEMA,
        "contract_id": contract["id"],
        "contract_sha256": hashlib.sha256(Path(scenario).read_bytes()).hexdigest(),
        "environment": environment,
        "frames": {
            "samples": count,
            "first_t_s": round(rows[0][0], 4),
            "last_t_s": round(rows[-1][0], 4),
            "interval_mean_ms": round(mean(vals), 4),
            "interval_p50_ms": round(percentile(vals, 0.50), 4),
            "interval_p95_ms": round(percentile(vals, 0.95), 4),
            "interval_p99_ms": round(percentile(vals, 0.99), 4),
            "interval_p999_ms": round(percentile(vals, 0.999), 4),
            "interval_max_ms": round(max(vals), 4),
            "fps_from_intervals": round(1000.0 / mean(vals), 3),
            "fps_1pct_low": round(low_fps(vals, 0.01), 3),
            "fps_0_1pct_low": round(low_fps(vals, 0.001), 3),
            "over_16_7ms": sum(ms > 16.7 for ms in vals),
            "over_20ms": sum(ms > 20 for ms in vals),
            "over_33ms": sum(ms > 33 for ms in vals),
        },
        "comparability": {
            "same_route_and_edit_schedule": True,
            "identical_scene_complexity": False,
            "graphics_frame_intervals_comparable": environment["render_mode"] == "interactive",
            "physical_present_timing_measured": False,
            "edit_first_correct_pixel_measured": False,
            "visual_130m_360_qualified": False,
            "strict_perf60_qualified": False,
            "note": "Frame-start gaps, not CPU+GPU+physical-present duration. Different SDF/world geometry. Headless rows are diagnostics only.",
        },
        "functional_proxies": environment.get("functional_proxies", {}),
    }
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--csv", required=True, type=Path)
    ap.add_argument("--contract", required=True, type=Path)
    ap.add_argument("--metadata", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()
    try:
        rows = parse_csv(args.csv)
        meta = json.loads(args.metadata.read_text(encoding="utf-8-sig"))
        result = reduce_trace(rows, args.contract, meta)
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(result, indent=2, sort_keys=True, ensure_ascii=False)+"\n", encoding="utf-8")
        print(f"COMPARISON_V1_REDUCE_OK engine={meta['engine']} frames={len(rows)} result={args.out}")
    except (ValueError, OSError, KeyError, json.JSONDecodeError) as error:
        ap.exit(2, f"COMPARISON_V1_INVALID: {error}\n")


if __name__ == "__main__":
    main()
