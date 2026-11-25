#!/usr/bin/env python3
"""Compare two sets of comparison-v1 result JSONs without overstating equivalence."""
import argparse
import json
import statistics
from pathlib import Path

KEYS = (
    "interval_p50_ms", "interval_p95_ms", "interval_p99_ms",
    "interval_p999_ms", "interval_max_ms", "fps_from_intervals",
    "fps_1pct_low", "fps_0_1pct_low", "over_20ms", "over_33ms"
)


def load_reports(paths, expected_engine):
    loaded = []
    for path in paths:
        data = json.loads(Path(path).read_text(encoding="utf-8-sig"))
        if data.get("schema") != "sandbox_comparison_result_v1":
            raise ValueError(f"{path}: wrong result schema")
        env = data.get("environment", {})
        if env.get("engine") != expected_engine:
            raise ValueError(f"{path}: unexpected engine")
        if not isinstance(data.get("frames"), dict):
            raise ValueError(f"{path}: missing frame metrics")
        if not all(isinstance(data["frames"].get(k), (int, float)) for k in KEYS):
            raise ValueError(f"{path}: incomplete frame metrics")
        loaded.append(data)
    return loaded


def compare(a, b, exploratory=False):
    if not a or not b:
        raise ValueError("both engine samples are required")
    if not exploratory and (len(a) < 3 or len(b) < 3):
        raise ValueError("three repetitions per candidate required; use --exploratory for provisional comparison")
    all_runs = a + b
    if any(x["environment"].get("render_mode") != "interactive" for x in all_runs):
        raise ValueError("headless results cannot be used in a graphical comparison")
    if len({x["contract_sha256"] for x in all_runs}) != 1:
        raise ValueError("contract hashes differ")
    if len({x["contract_id"] for x in all_runs}) != 1:
        raise ValueError("scenarios differ")
    for field in ("profile", "hostname", "resolution"):
        if len({str(x["environment"].get(field)) for x in all_runs}) != 1:
            raise ValueError(f"mismatched {field}")
    for field in ("cpu", "gpu"):
        if len({json.dumps(x["environment"].get(field), sort_keys=True) for x in all_runs}) != 1:
            raise ValueError(f"mismatched {field}")
    if any(x["comparability"].get("identical_scene_complexity") is not False for x in all_runs):
        raise ValueError("scenario-equivalence disclaimer missing")
    def rollup(group):
        return {key: round(statistics.median([r["frames"][key] for r in group]), 4) for key in KEYS}
    ar = rollup(a)
    br = rollup(b)
    return {
        "schema": "sandbox_comparison_pair_v1",
        "status": "EXPLORATORY" if exploratory else "MATCHED_HARDWARE_DIAGNOSTIC",
        "contract_id": all_runs[0]["contract_id"],
        "contract_sha256": all_runs[0]["contract_sha256"],
        "same_physical_machine": True,
        "scene_equivalence": False,
        "present_time_qualified": False,
        "edit_first_pixel_qualified": False,
        "strict_60fps_qualified": False,
        "a_runs": len(a),
        "b_runs": len(b),
        "a_godot_medians": ar,
        "b_bevy_medians": br,
        "p99_interval_delta_bevy_minus_godot_ms": round(br["interval_p99_ms"] - ar["interval_p99_ms"], 4),
        "interpretation": "Descriptive medians of FRAME START intervals only. The two engines have different terrain/physics workloads. No architectural winner can be inferred from this report alone."
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--godot", type=Path, required=True, nargs="+")
    ap.add_argument("--bevy", type=Path, required=True, nargs="+")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--exploratory", action="store_true")
    args = ap.parse_args()
    try:
        result = compare(load_reports(args.godot, "godot_voxel_tools"),
                         load_reports(args.bevy, "rust_bevy"),
                         args.exploratory)
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(result, indent=2, sort_keys=True, ensure_ascii=False)+"\n", encoding="utf-8")
        print(f"COMPARISON_PAIR_OK status={result['status']} report={args.out}")
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as err:
        ap.exit(2, f"COMPARISON_PAIR_INVALID: {err}\n")


if __name__ == "__main__":
    main()
