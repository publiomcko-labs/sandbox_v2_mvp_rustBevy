#!/usr/bin/env python3
"""B15.4: offline, source-preserving correlation of B14, B11 and PresentMon.

Usage: python scripts/b15-4-correlate.py on.zip off.zip --out report.json
Inputs are ZIPs produced by b15-2-local-60fps.ps1. No third-party packages.
This analyzes timestamp proximity, not causal impact or Vulkan presentation fences.
"""
from __future__ import annotations

import argparse
import bisect
import csv
from datetime import datetime, timedelta, timezone
import io
import json
from pathlib import Path
import re
import statistics
import zipfile

ANSI = re.compile(r"\x1b\[[0-9;]*m")
TS = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)Z")
PATTERNS = [
    ("edit", "B15.1 scripted edit requested"),
    ("cohort", "B15.2 edit and seam cohort queued atomically"),
    ("repair", "B15.1 stale LOD seam metadata queued"),
    ("far_build", "B11 far field coverage built"),
    ("far_swap", "B15.4 far shell swap published"),
    ("relocation", "B15.1 GPU relocated live meshes"),
    ("edited_mesh_ready", "B4 revised GPU mesh ready for publication"),
]
FIELDS = ("index", "frame", "t_s", "cohort", "canceled", "dirty", "repair_count",
          "relocations", "scheduled", "prepare_cpu_us", "build_us", "unix_ms",
          "latency_ms", "center_x", "center_z")


def percentile(values: list[float], q: float) -> float | None:
    if not values:
        return None
    values = sorted(values)
    return round(values[max(0, min(len(values) - 1, int((len(values) - 1) * q + .999999)))], 3)


def open_member(archive: zipfile.ZipFile, name: str) -> str | None:
    normalized = name.lower().replace("\\", "/")
    for item in archive.namelist():
        if item.lower().replace("\\", "/") == normalized:
            return archive.read(item).decode("utf-8-sig", "replace")
    return None


def frame_dicts(text: str) -> list[dict]:
    return list(csv.DictReader(io.StringIO(text)))


def log_events(log: str) -> list[dict]:
    out = []
    for raw in ANSI.sub("", log).splitlines():
        match = TS.search(raw)
        if not match:
            continue
        timestamp = datetime.fromisoformat(match.group(1) + "+00:00")
        kind = next((label for label, phrase in PATTERNS if phrase in raw), None)
        if not kind:
            continue
        info = {"type": kind, "unix_ms": round(timestamp.timestamp() * 1000)}
        for key in FIELDS:
            field = re.search(r"\b" + key + r"=([0-9.]+)", raw)
            if field:
                val = field.group(1)
                info[key] = float(val) if "." in val else int(val)
        out.append(info)
    return out


def presentmon_rows(text: str, offset_minutes: int | None) -> tuple[list[dict], str]:
    rows = frame_dicts(text)
    if not rows:
        return [], "presentmon_empty"
    if "CPUStartDateTime" not in rows[0]:
        return [], "presentmon_missing_CPUStartDateTime"
    if offset_minutes is None:
        return [], "presentmon_missing_timezone_offset"
    tz = timezone(timedelta(minutes=offset_minutes))
    output = []
    for row in rows:
        raw = row.get("CPUStartDateTime", "").strip()
        if not raw or raw.upper() == "NA":
            continue
        try:
            raw = raw.replace(" ", "T")
            # Python accepts 6 microseconds; truncate any nanosecond precision.
            raw = re.sub(r"(\.\d{6})\d+", r"\1", raw)
            at = datetime.fromisoformat(raw)
            if at.tzinfo is None:
                at = at.replace(tzinfo=tz)
            ms = round(at.timestamp() * 1000)
        except ValueError:
            continue
        sample = {"unix_ms": ms}
        for field in ("MsBetweenAppPresents", "DisplayedTime", "MsGPUTime",
                      "MsGPUBusy", "MsCPUBusy", "DisplayLatency"):
            try:
                sample[field] = float(row[field])
            except (ValueError, KeyError, TypeError):
                pass
        output.append(sample)
    return output, "timestamped" if output else "presentmon_unparseable_timestamps"


def metrics_for(archive_path: str) -> dict:
    with zipfile.ZipFile(archive_path) as z:
        meta_text = open_member(z, "b15-2-recording.json")
        frame_text = open_member(z, "trace/b14-frames.csv")
        log_text = open_member(z, "game.stderr.log")
        cost_text = open_member(z, "trace/b15-4-costs.csv")
        present_text = open_member(z, "presentmon.csv")
    if not meta_text or not frame_text or log_text is None:
        raise ValueError(f"Incomplete B14 archive: {archive_path}")
    meta = json.loads(meta_text)
    frames = frame_dicts(frame_text)
    if len(frames) < 3:
        raise ValueError(f"Too few B14 frames: {archive_path}")
    series = [(int(f["unix_ms"]), float(f["game_t_s"])) for f in frames]
    starts = [p[0] for p in series]
    events = log_events(log_text)
    for ev in events:
        at = ev["unix_ms"]
        index = bisect.bisect_left(starts, at)
        choices = [i for i in (index - 1, index) if 0 <= i < len(series)]
        if choices:
            closest = min(choices, key=lambda i: abs(starts[i] - at))
            ev["near_game_t_s"] = round(series[closest][1], 3)
            ev["b14_alignment_error_ms"] = abs(starts[closest] - at)
    record_start = int(meta["ffmpeg_launch_unix_ms"])
    record_end = record_start + int(meta.get("expected_recording_duration_seconds", 120)) * 1000
    # Prefer actual duration recorded by FFprobe if exposed by the capture script.
    if "video_duration_s" in meta:
        record_end = record_start + round(float(meta["video_duration_s"]) * 1000)
    in_video = [(t, starts[i] - starts[i - 1])
                for i, (t, _) in enumerate(series)
                if i > 0 and record_start <= t <= record_end]
    all_deltas = [series[i][0] - series[i - 1][0] for i in range(1, len(series))]
    video_spikes = sorted(
        ({"unix_ms": t, "frame_gap_ms": gap} for t, gap in in_video if gap > 33.4),
        key=lambda v: v["frame_gap_ms"], reverse=True
    )
    for spike in video_spikes[:25]:
        nearby = [e for e in events if abs(e["unix_ms"] - spike["unix_ms"]) <= 1000]
        spike["nearest_events_1s"] = [e["type"] for e in sorted(
            nearby, key=lambda e: abs(e["unix_ms"] - spike["unix_ms"]))[:6]]
    count = {k: sum(e["type"] == k for e in events) for k, _ in PATTERNS}
    sum_relocation = sum(int(e.get("relocations", 0)) for e in events if e["type"] == "relocation")
    sum_repairs = sum(int(e.get("repair_count", 0)) for e in events if e["type"] == "repair")
    sum_cancelled = sum(int(e.get("canceled", 0)) for e in events if e["type"] == "cohort")
    costs = frame_dicts(cost_text) if cost_text else []
    present, present_status = presentmon_rows(
        present_text, meta.get("local_utc_offset_minutes")) if present_text else ([], "not_recorded")
    in_present = [p for p in present if record_start <= p["unix_ms"] <= record_end]
    present_gaps = [p["MsBetweenAppPresents"] for p in in_present
                    if "MsBetweenAppPresents" in p and p["MsBetweenAppPresents"] >= 0]
    gpu_times = [p["MsGPUTime"] for p in in_present if "MsGPUTime" in p]
    focus = []
    for edit in [e for e in events if e["type"] == "edit"]:
        idx = edit.get("index")
        when = edit["unix_ms"]
        related = [e for e in events if e["type"] in ("cohort", "repair", "far_build",
                                                      "far_swap", "relocation")
                   and 0 <= e["unix_ms"] - when <= 1000]
        local = [gap for ts, gap in in_video if abs(ts - when) <= 500]
        focus.append({
            "edit_index": idx, "game_t_s": edit.get("near_game_t_s"),
            "unix_ms": when, "events_next_1s": related,
            "max_b14_frame_gap_ms_within_500ms": max(local, default=None),
            "p95_b14_frame_gap_ms_within_500ms": percentile(local, .95),
        })
    return {
        "archive": Path(archive_path).name,
        "far_shell": meta.get("far_shell"),
        "capture_backend": meta.get("capture_backend"),
        "b14_frames": len(frames),
        "b14_frame_gap_all_p95_ms": percentile(all_deltas, .95),
        "b14_frame_gap_video_p95_ms": percentile([d for _, d in in_video], .95),
        "b14_frame_gap_video_max_ms": max([d for _, d in in_video], default=None),
        "b14_video_spikes_over_33_4ms": len(video_spikes),
        "video_worst_spikes": video_spikes[:25],
        "event_counts": count,
        "relocation_mesh_total": sum_relocation,
        "post_edit_seam_repair_blocks": sum_repairs,
        "cancelled_lod_jobs_on_edit_cohorts": sum_cancelled,
        "b15_4_cost_frames": len(costs),
        "b15_4_stream_cpu_us_p95": percentile(
            [float(row["stream_cpu_us"]) for row in costs if row.get("stream_cpu_us")], .95),
        "presentmon_status": present_status,
        "presentmon_frames_in_video": len(in_present),
        "presentmon_app_present_p95_ms": percentile(present_gaps, .95),
        "presentmon_gpu_time_p95_ms": percentile(gpu_times, .95),
        "focus_edits": focus,
        "timing_caveat": ("B14 wall-clock gaps and PresentMon API timestamps are distinct "
                          "measurements; 1s proximity is association, not causation. "
                          "No PresentMon means independent presentation is unmeasured."),
    }


def selftest() -> None:
    assert percentile([1, 2, 3, 4], .95) == 4
    colored = "\x1b[2m2026-11-25T10:38:09.000000Z\x1b[0m B15.2 edit and seam cohort queued atomically \x1b[3mcanceled\x1b[0m=\x1b[0m8"
    found = log_events(colored)
    assert len(found) == 1 and found[0]["canceled"] == 8
    naive = "CPUStartDateTime,MsBetweenAppPresents,MsGPUTime\n2026-11-25 07:38:09.0000000,16.7,8.0\n"
    pres, status = presentmon_rows(naive, -180)
    assert status == "timestamped" and pres[0]["unix_ms"] == 1795603089000
    print("B15_4_CORRELATOR_SELFTEST_PASS")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("shell_on", nargs="?")
    parser.add_argument("shell_off", nargs="?")
    parser.add_argument("--out", default="b15-4-correlation.json")
    parser.add_argument("--self-test", action="store_true")
    opts = parser.parse_args()
    if opts.self_test:
        selftest()
        return
    if not opts.shell_on or not opts.shell_off:
        parser.error("Supply both B11-on and B11-off ZIP archives")
    arms = [metrics_for(p) for p in (opts.shell_on, opts.shell_off)]
    result = {
        "status": "CORRELATED_WITH_PRESENT_MON" if all(
            arm["presentmon_frames_in_video"] > 50 for arm in arms
        ) else "CORRELATED_B14_ONLY_PRESENT_UNMEASURED",
        "arms": arms,
        "qualifications": [
            "A 16.7ms full-frame budget requires independent present evidence",
            "B14 reports MainWorld/GPU-dispatch-ready logical state, not pixels",
            "Edit publish latency starts after synchronous journal save",
            "Comparative timing is observational and cannot establish causation",
        ],
    }
    out = Path(opts.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps({"status": result["status"], "out": str(out),
                      "arms": [{
                          "far_shell": a["far_shell"], "presentmon_status": a["presentmon_status"],
                          "frame_p95_ms": a["b14_frame_gap_video_p95_ms"],
                          "repairs": a["post_edit_seam_repair_blocks"],
                          "canceled": a["cancelled_lod_jobs_on_edit_cohorts"],
                      } for a in arms]}, indent=2))


if __name__ == "__main__":
    main()
