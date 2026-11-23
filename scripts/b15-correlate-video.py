#!/usr/bin/env python3
"""B15: flag isolated 60fps pixel transients; correlate with B14 timestamps.
Candidate detection is heuristic, never a proof of missing terrain or root cause.
Requires ffmpeg + ffprobe on PATH. No Python packages required.
Usage: python scripts/b15-correlate-video.py C:/Dev/sandbox-b15-visual/captures/b15-Live-YYYYMMDD-HHMMSS
"""
import argparse
import bisect
import csv
import json
import shutil
import subprocess
from collections import Counter
from pathlib import Path


def load_pts(video):
    command = ['ffprobe', '-v', 'error', '-select_streams', 'v:0',
               '-show_entries', 'frame=best_effort_timestamp_time',
               '-of', 'csv=p=0', str(video)]
    proc = subprocess.run(command, capture_output=True, text=True, check=True)
    pts = []
    for line in proc.stdout.splitlines():
        try:
            pts.append(float(line.strip().split(',')[0]))
        except ValueError:
            continue
    if len(pts) < 3:
        raise ValueError('ffprobe returned fewer than three video presentation timestamps')
    return pts


def mean_delta(a, b):
    return sum(abs(x - y) for x, y in zip(a, b)) / len(a)


def score_frames(before, current, after, min_delta, ratio):
    # Full image and lower half. A single-frame disappearance/reappearance
    # creates high two-way deltas but comparatively low prev-vs-next delta.
    # Camera turns, exposure changes, overlay, encoder and compositor can
    # also trigger candidates: mandatory manual review.
    size = len(before)
    regions = (('all', 0, size), ('lower_half', size // 2, size))
    candidates = []
    for name, a, b in regions:
        previous = before[a:b]
        middle = current[a:b]
        following = after[a:b]
        first = mean_delta(previous, middle)
        second = mean_delta(middle, following)
        baseline = mean_delta(previous, following)
        transient_ratio = min(first, second) / max(baseline, 1.0)
        if min(first, second) >= min_delta and transient_ratio >= ratio:
            candidates.append({
                'region': name,
                'transient_ratio': round(transient_ratio, 3),
                'prev_to_current_mean': round(first, 2),
                'current_to_next_mean': round(second, 2),
                'prev_to_next_mean': round(baseline, 2),
            })
    return max(candidates, key=lambda c: c['transient_ratio']) if candidates else None


def decode(video, pts, threshold, minimum, warmup, max_reports):
    command = ['ffmpeg', '-nostdin', '-v', 'error', '-i', str(video),
               '-map', '0:v:0', '-vf', 'scale=64:36:flags=area',
               '-pix_fmt', 'rgb24', '-fps_mode', 'passthrough', '-f', 'rawvideo', 'pipe:1']
    proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    width = 64 * 36 * 3
    frames_seen = 0
    findings = []
    prevprev = None
    prev = None
    try:
        while True:
            data = proc.stdout.read(width)
            if not data:
                break
            if len(data) != width:
                raise ValueError('truncated decoded video frame')
            i = frames_seen
            frames_seen += 1
            if prevprev is not None and i-1 < len(pts):
                t = pts[i-1] - pts[0]
                if t >= warmup:
                    transient = score_frames(prevprev, prev, data, minimum, threshold)
                    if transient is not None:
                        findings.append({'video_frame': i-1, 'video_time_s': round(t, 4), **transient})
            prevprev, prev = prev, data
    finally:
        if proc.stdout:
            proc.stdout.close()
        ret = proc.wait(timeout=30)
    if ret:
        raise ValueError(f'ffmpeg RGB decode failed with code {ret}')
    if abs(frames_seen - len(pts)) > 2:
        raise ValueError(f'PTS/frame count mismatch: {len(pts)} vs {frames_seen}')
    # Preserve strongest candidates rather than claiming that first N are representative.
    findings.sort(key=lambda f: f['transient_ratio'], reverse=True)
    return frames_seen, findings[:max_reports], len(findings)


def load_csv(folder, filename):
    p = folder / 'trace' / filename
    if not p.exists():
        raise ValueError(f'missing trace: {p}')
    with p.open(newline='', encoding='utf-8-sig') as handle:
        return list(csv.DictReader(handle))


def correlate(candidates, root, recording, tolerance_ms):
    frames = load_csv(root, 'b14-frames.csv')
    events = load_csv(root, 'b14-mesh-events.csv')
    if not frames:
        raise ValueError('B14 trace empty')
    frames.sort(key=lambda r: int(r['unix_ms']))
    frame_times = [int(r['unix_ms']) for r in frames]
    events.sort(key=lambda r: int(r['unix_ms']))
    event_times = [int(r['unix_ms']) for r in events]
    launch_ms = int(recording['ffmpeg_launch_unix_ms'])
    for candidate in candidates:
        # FFmpeg launch precedes the first encoded frame. Timing uncertainty is
        # explicit: do not represent the nearest logical frame as exact sync.
        center_ms = launch_ms + round(candidate['video_time_s'] * 1000)
        lo = bisect.bisect_left(frame_times, center_ms - tolerance_ms)
        hi = bisect.bisect_right(frame_times, center_ms + tolerance_ms)
        near = frames[lo:hi]
        e_lo = bisect.bisect_left(event_times, center_ms - tolerance_ms)
        e_hi = bisect.bisect_right(event_times, center_ms + tolerance_ms)
        kinds = Counter(e['event'] for e in events[e_lo:e_hi])
        missing = sum(int(f['missing']) > 0 for f in near)
        probes = sum(int(f['probe_missing']) > 0 for f in near)
        candidate.update({
            'approx_unix_ms': center_ms,
            'sync_uncertainty_ms': tolerance_ms,
            'logical_frames_in_window': len(near),
            'logical_missing_frames_in_window': missing,
            'probe_missing_frames_in_window': probes,
            'event_counts_in_window': dict(sorted(kinds.items())),
            'triage': ('LOGICAL_GAP_POSSIBLE' if missing else
                       'RASTER_OR_COMPOSITOR_CANDIDATE' if near else
                       'UNALIGNED_NEEDS_MANUAL_SYNC'),
        })


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('session', type=Path)
    p.add_argument('--ratio', type=float, default=2.2)
    p.add_argument('--min-delta', type=float, default=10.0)
    p.add_argument('--warmup-seconds', type=float, default=20.0)
    p.add_argument('--max-reports', type=int, default=80)
    args = p.parse_args()
    if args.ratio <= 1 or args.min_delta <= 0 or args.warmup_seconds < 0 or args.max_reports < 1:
        p.error('invalid detection parameters')
    if not shutil.which('ffmpeg') or not shutil.which('ffprobe'):
        p.error('ffmpeg and ffprobe are required on PATH')
    root = args.session
    recording_path = root / 'b15-recording.json'
    with recording_path.open(encoding='utf-8-sig') as handle:
        recording = json.load(handle)
    video = root / recording['recording']
    if not video.is_file():
        p.error(f'missing video: {video}')
    pts = load_pts(video)
    n, findings, total = decode(video, pts, args.ratio,
                                args.min_delta, args.warmup_seconds, args.max_reports)
    tolerance = max(1000, int(recording.get('synchronization_uncertainty_ms', 1000)))
    correlate(findings, root, recording, tolerance)
    result = {
        'status': ('PIXEL_ANOMALY_CANDIDATES_FOR_VISUAL_REVIEW' if total else
                   'NO_HEURISTIC_ANOMALIES_NOT_VISUAL_PROOF'),
        'source': str(root),
        'decoded_video_frames': n,
        'video_duration_s': round(pts[-1] - pts[0], 3),
        'detector': {'ratio': args.ratio, 'min_delta': args.min_delta,
                     'warmup_seconds': args.warmup_seconds},
        'candidate_count': total,
        'top_candidates': findings,
        'limitations': [
            'Heuristic catches isolated reversions only; persistent gaps may be missed.',
            'Compositor/desktop capture and video encoding may create false positives.',
            'The FFmpeg launch UTC anchor has at least +/- 1s synchronization uncertainty.',
            'Correlations do not prove causal involvement of LOD swaps or GPU publication.',
        ],
    }
    out = root / 'b15-correlation.json'
    out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'status': result['status'], 'frames': n,
                      'candidate_count': total, 'reports': len(findings),
                      'output': str(out)}, ensure_ascii=False))


if __name__ == '__main__':
    main()
