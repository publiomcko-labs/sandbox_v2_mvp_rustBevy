# B14 — Per-frame visibility: qualified diagnostic closeout

**Disposition:** B14 diagnostic and Windows/Vulkan CI **PASS**; visual continuity and MVP performance **NOT QUALIFIED**. No promotion to main.

## Reference

- Functional baseline: `checkpoint/b13-functional-20261123` at `34e3e3b394243d35009c83296fe79a8f247798f0`.
- Instrumented branch: `diag/b14-per-frame-visibility-20261123` at `a258fd63ee05d09acbbab35eca11723e1c1acba8`.
- Run: https://github.com/publiomcko-labs/sandbox_v2_mvp_rustBevy/actions/runs/45261223096
- Evidence: `b14-frame-visibility-evidence` (artifact `14861046750`).
- B14 is opt-in with `SANDBOX_B14_TRACE_DIR`; B13 baseline remains untouched.

## Observed evidence

Headless Windows/Vulkan, B11 terrain, mixed LOD, straight 18 m/s route, 1080p offscreen render, screenshots at 12/40/72 s.

| Indicator | Value |
|---|---:|
| Test duration | 72.2104 s |
| Per-frame observations | 4,345 |
| Mesh event rows | 20,251 |
| Mesh swaps | 9,162 |
| Published mesh removals | 3,150 |
| Frames missing required *logical* blocks (whole run) | 597 |
| Frames missing diagnostic probes (whole run) | 229 |
| Last missing required block | 16.6495 s |
| Last missing probe | 16.5515 s |
| Frames at or after 20 s | 3,169 |
| Required-block gaps after 20 s | 0 |
| Probe gaps after 20 s | 0 |
| Required but view-unselected after 20 s | 0 |
| View-exit events after 20 s | 0 |
| Mesh swaps after 20 s | 7,890 |
| Published mesh removals after 20 s | 2,588 |
| Vulkan errors | 0 |
| B14 observation overhead mean / p95 / max | 248.44 / 332 / 1,177 µs |

The fixed 20 s boundary is **descriptive**, not an a priori acceptance threshold: startup holes are real in the logical trace. Following startup, the trace does **not** support the hypothesis that required *logical* blocks are missing while streaming steadily at 18 m/s.

## Limits and decision

- `ViewVisibility` and the CPU-side `published`/GPU-ready bookkeeping are **not evidence of pixels actually drawn**. GPU triangle output, index/vertex validity, raster/depth, render extraction and publication ordering remain possible causes of visible holes.
- Three screenshots are insufficient to exclude short flicker. The headless straight route is not a substitute for local free-flight, turns, returns and editing video at 60 FPS.
- There is no equivalent-instrumentation control for performance. The B14 observer's self-measured cost is not the full impact on frame time. The hard 16.7 ms and edit-latency criteria remain unqualified.
- Do not infer watertight LOD seams, water/rock visual equivalence, or complete functional sign-off.

**Close B14 as a successful diagnostic campaign.** Preserve B13 as the functional checkpoint and B14 separately for reproduction. The next experiment should correlate *presented 60 FPS video* with timestamped GPU mesh content/readiness, render-extraction and LOD swap events; categorize holes as invalid/empty geometry, synchronization, SDF seam or far-field/depth interference. Make only a causally justified narrow correction and A/B test against B13.

Offline reducer for the raw CSVs is available with this closeout; it validates ordering and event counts and emits a machine-readable summary. No production engine behavior was changed by the closeout.
