#!/usr/bin/env python3
"""B14 offline diagnostic reducer: logical coverage, never framebuffer proof.

Usage: python scripts/b14-analyze-trace.py path/to/b14-evidence --out b14-analysis.json
No third-party dependencies; does not modify input traces.
"""
import argparse
import csv
import json
from collections import Counter
from pathlib import Path
from statistics import mean

FRAME_COLUMNS = (
    'frame', 'game_t_s', 'missing', 'probe_missing', 'required_unselected',
    'view_exits', 'mesh_swaps', 'removed', 'removed_published', 'gpu_ready',
    'spawned', 'observation_us', 'transition_pending', 'transition_queued',
)
EVENT_TYPES = ('spawn', 'gpu_ready', 'remove', 'mesh_swap', 'view_exit')


def read_rows(path, required):
    with path.open('r', newline='', encoding='utf-8-sig') as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames or not set(required).issubset(reader.fieldnames):
            raise ValueError(f'{path}: missing required columns {sorted(set(required) - set(reader.fieldnames or []))}')
        rows = list(reader)
    if not rows:
        raise ValueError(f'{path}: empty CSV')
    return rows


def analyze(folder, warmup_s=20.0):
    folder = Path(folder)
    trace = folder / 'trace' if (folder / 'trace').is_dir() else folder
    frames = read_rows(trace / 'b14-frames.csv', FRAME_COLUMNS)
    events = read_rows(trace / 'b14-mesh-events.csv', ('frame', 'game_t_s', 'event'))
    indexed = []
    for row in frames:
        try:
            entry = {key: (float(row[key]) if key == 'game_t_s' else int(row[key])) for key in FRAME_COLUMNS}
        except (TypeError, ValueError) as exc:
            raise ValueError(f'invalid frame row: {row}') from exc
        if entry['frame'] <= 0 or entry['game_t_s'] < 0 or any(entry[key] < 0 for key in FRAME_COLUMNS if key not in ('frame', 'game_t_s')):
            raise ValueError('negative B14 counter or invalid frame index')
        if indexed and (entry['frame'] != indexed[-1]['frame'] + 1 or entry['game_t_s'] < indexed[-1]['game_t_s']):
            raise ValueError('non-consecutive frame indices or decreasing game time')
        indexed.append(entry)
    event_counts = Counter()
    for event in events:
        kind = event['event']
        event_counts[kind] += 1
        if int(event['frame']) < indexed[0]['frame'] or int(event['frame']) > indexed[-1]['frame']:
            raise ValueError('event references frame outside observed sequence')
    unexpected = set(event_counts) - set(EVENT_TYPES) - {'published_lost', 'view_enter'}
    if unexpected:
        raise ValueError(f'unknown B14 event types: {sorted(unexpected)}')
    for event_type, frame_field in [
        ('spawn', 'spawned'), ('gpu_ready', 'gpu_ready'),
        ('mesh_swap', 'mesh_swaps'), ('remove', 'removed'),
        ('view_exit', 'view_exits'),
    ]:
        if event_counts[event_type] != sum(row[frame_field] for row in indexed):
            raise ValueError(f'per-frame/event mismatch: {event_type}')
    steady = [row for row in indexed if row['game_t_s'] >= warmup_s]
    if not steady:
        raise ValueError('trace does not reach requested warmup boundary')
    positive = lambda rows, field: sum(row[field] > 0 for row in rows)
    last_missing = [row['game_t_s'] for row in indexed if row['missing'] > 0]
    last_probe_missing = [row['game_t_s'] for row in indexed if row['probe_missing'] > 0]
    steady_logical_ok = all(positive(steady, k) == 0 for k in ('missing', 'probe_missing', 'required_unselected', 'view_exits'))
    overhead = sorted(row['observation_us'] for row in indexed)
    result = {
        'source': 'B14 MainWorld visibility and GPU-ready telemetry; NOT pixel/raster evidence',
        'frame_rows': len(indexed),
        'event_rows': len(events),
        'elapsed_s': indexed[-1]['game_t_s'],
        'first_frame': indexed[0]['frame'],
        'last_frame': indexed[-1]['frame'],
        'initialization': {
            'frames_with_missing_required': positive(indexed, 'missing'),
            'frames_with_missing_probes': positive(indexed, 'probe_missing'),
            'last_missing_required_at_s': max(last_missing) if last_missing else None,
            'last_missing_probe_at_s': max(last_probe_missing) if last_probe_missing else None,
        },
        'steady': {
            'warmup_boundary_s': warmup_s,
            'frames': len(steady),
            'missing_required_frames': positive(steady, 'missing'),
            'missing_probe_frames': positive(steady, 'probe_missing'),
            'required_unselected_frames': positive(steady, 'required_unselected'),
            'view_exit_frames': positive(steady, 'view_exits'),
            'mesh_swaps': sum(row['mesh_swaps'] for row in steady),
            'removed_published': sum(row['removed_published'] for row in steady),
            'result': 'LOGICAL_COVERAGE_STABLE' if steady_logical_ok else 'LOGICAL_GAPS_PRESENT',
        },
        'events': dict(sorted(event_counts.items())),
        'instrumentation': {
            'mean_observation_us': round(mean(overhead), 2),
            'p95_observation_us': overhead[min(len(overhead)-1, int(0.95*(len(overhead)-1)))],
            'max_observation_us': overhead[-1],
            'flush_frequency': 'every frame (per source implementation)',
        },
        'limitations': [
            'ViewVisibility and logical GPU-ready flags cannot establish actual visible pixel coverage.',
            'An 18 m/s headless straight route and three still screenshots cannot exclude intermittent on-screen flicker.',
            'This analysis does not measure the complete 16.7 ms frame budget or visual correctness of every LOD seam.',
        ],
    }
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('evidence', type=Path, help='B14 evidence directory, or trace directory')
    parser.add_argument('--warmup-seconds', type=float, default=20.0)
    parser.add_argument('--out', type=Path, help='Write reproducible JSON report to this path')
    args = parser.parse_args()
    if not 0 <= args.warmup_seconds < 120:
        parser.error('--warmup-seconds must be between 0 and 120')
    try:
        result = analyze(args.evidence, args.warmup_seconds)
    except (OSError, ValueError) as exc:
        parser.exit(2, f'B14_TRACE_INVALID: {exc}\n')
    output = json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + '\n'
    if args.out:
        args.out.write_text(output, encoding='utf-8')
    print(output, end='')


if __name__ == '__main__':
    main()
