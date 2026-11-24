# B15.1 — GPU residency, interactive SDF editing and LOD seam corrections

**Status (2026-11-24):** `B15_1_WINDOWS_VULKAN_AB_SURVEY_PASS_VISUAL_REVIEW_PENDING`. Automated contract, Release and Windows/Vulkan gates PASS. No merge or promotion to `main`. Pixel-level, free-flight visual and 16.7ms frame-budget acceptance remain **OPEN**.

## Source and evidence

- Functional reference: `checkpoint/b13-functional-20261123`.
- Instrumentation base: `checkpoint/b15-diagnostic-20261123`.
- Tested experimental source: `fix/b15-1-gpu-edit-lod-20261124` at `74cf52a8c86c5a7ce63ea772dadbceba28df33f1`.
- Successful workflow: https://github.com/publiomcko-labs/sandbox_v2_mvp_rustBevy/actions/runs/45382524004
- A/B evidence: workflow artifact `b15-1-gpu-edit-ab-evidence` (ID `14914013666`), with raw logs, B14 telemetry, screenshots and `B15_1_AB_SUMMARY.json`.
- Executable and shaders: workflow artifact `b15-1-windows-release` (ID `14913914026`).
- All measurements are single-run, diagnostic estimates; `frame` telemetry does not prove the monitor's displayed refresh cadence.

## Corrective implementation

1. **Live GPU mesh residency:** When `MeshAllocator` relocates a GPU-compute mesh slab, the render pass now prioritizes *all* affected live allocations for recomputation before `camera_driver`, rather than waiting behind a quota of five new blocks. Unmodified view/publication flags alone had falsely appeared to indicate ready geometry.
2. **SDF editing latency:** Edited blocks are queued ahead of ordinary streaming and LOD refinements. Edit cohorts commit separately from large pending LOD cohorts while retaining their prior visible mesh until replacement. Six deterministic edits at game seconds 25, 28, 31, 34, 37 and 40 are opt-in for CI only.
3. **LOD seams:** Newly arriving LOD2 blocks derive seam metadata from visible neighbor tiers. Stale LOD seam masks are reconciled; incoherent mixed-tier cohorts are prevented from publication. The existing per-frame seam audit remains active.
4. **Experimental allocator:** `SANDBOX_B15_1_STABLE_SLABS=1` sets 16MiB minimum slab allocation and 2× growth. This uses more reserved VRAM; the experiment measures whether that cost reduces relocation churn.
5. **60fps recording:** `scripts/b15-local-60fps.ps1` targets the game window instead of the full multi-monitor desktop and records actual encoded FPS. It remains unverified on an interactive Windows desktop in this campaign.

## Verified Windows/Vulkan campaign

Each arm included 72s of B11 + B14 telemetry, mixed LOD, physics, 18m/s motion, three 1080p captures, six scripted edits, and zero runtime validation errors. The `survey` arm exercised east/north/west/south movement, including turns and returns.

| Metric | Standard slabs / straight | 16MiB slabs / straight | 16MiB slabs / turns+returns |
|---|---:|---:|---:|
| B14 frames | 4,137 | 4,206 | 4,257 |
| Scripted SDF edits | 6 | 6 | 6 |
| Published edited block meshes | 32 | 32 | 22 |
| Maximum publication latency (ms) | 61.35 | 52.73 | 48.79 |
| Publication latency > 100ms | 0 | 0 | 0 |
| GPU mesh relocations | 11,567 | 6,270 | 6,113 |
| LOD invalid frames | 0 | 0 | 0 |
| Missing logical horizon after t=20s | 0 | 0 | 0 |
| Vulkan errors | 0 | 0 | 0 |
| Frame telemetry p95 interval (ms) | 24.4 | 23.3 | 23.7 |
| Frame telemetry > 100ms intervals | 16 | 12 | 11 |

The two straight-route arms have comparable conditions. Larger slabs reduced observed mesh relocation events by **45.8%** (11,567 → 6,270). The survey is a different route, not a direct A/B FPS comparison.

**Important caveat:** the per-frame stream publishes updated terrain within 100ms in these six *automated* edit events. This is not proof that mouse-to-first-pixel editing during actual free flight always meets 100ms. p95 frame intervals 23–24ms and occasional 250ms intervals fail strict 16.7ms frame-budget acceptance. Large bursts of mesh relocations remain, so immediate re-extraction may introduce GPU/CPU cost. Three sparse screenshots per arm cannot exclude transient pixel gaps.

## Decision

- Preserve `checkpoint/b15-1-ci-20261124` as an **experimental, CI-qualified candidate**, not a promoted functional baseline.
- Preserve B13 checkpoint and `main` unchanged. Keep slab enlargement opt-in rather than default pending GPU memory/performance qualification.
- Next gate: interactive 60 FPS video restricted to the game window with B14 logs; reproduce edits while moving, turning and revisiting, and compare pixel-level defects and frame-time spikes to B15.1 and B13 under matching instrumentation.
- Do not declare the rare terrain flicker, all LOD cracks, or final 60FPS criteria resolved until this local check passes.
