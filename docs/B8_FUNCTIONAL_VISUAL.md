# B8 — Functional/visual closure candidate (performance deferred)

Branch: `feat/b8-functional-visual-20261122`, based on the previously successful B6/B7 Release.

## Functional changes

- Replaces solid 4 m occupancy-box proxies with a 1 m sampled Marching Tetrahedra zero-surface collider for every 4 m tile near the player. Each collider samples the same seeded SDF and B4 edit journal as GPU terrain. Caves remain hollow and edited shapes trigger collider replacement in-place (old static collider is retained until the new one is constructed).
- Uses Avian trimesh collision for static terrain and sphere collision for dynamic rocks. Numerical tests cover a planar surface, cave interior and walls, edited tile boundaries, and fully empty/solid tiles. This is a one-meter approximation of the zero-set, not identical triangle topology to GPU Surface Nets; contact-equivalence/interactive review is still necessary.
- Extends buoyancy and water drag to density-parameterized Avian rigid bodies. An opt-in B8 test spawns a lighter-than-water float and a heavy rock probe, requires positive/negative vertical velocities, and records the observation.
- Adds a per-frame audit of mixed-LOD visible neighbor pairs, 2:1 adjacency, required seam ownership, and replacement visibility. Any anomalous frame is counted, even if the 1 Hz progress log did not coincide with it.
- Captures nine 1920×1080 Vulkan screenshots at 12, 16, 20, 24, 28, 32, 36, 40 and 44 seconds of a continuous 18 m/s route, alongside stderr telemetry and world edits.

## Test and acceptance evidence

Workflow: `.github/workflows/b8-functional.yml`. Run GPU route: `scripts/b8-functional-visual-ci.ps1` using the packaged `b8-functional-release` artifact. Inspect `b8-functional-visual-evidence` and `B8_FUNCTIONAL_REPORT.json`.

The functional CI requires nine actual screenshots, positive water probe qualification, SDF colliders resident, zero missing moving horizon, zero observed LOD seam/tier/atomic-publication errors, and at least one mixed-LOD pair. **CI alone cannot guarantee zero sub-frame flicker or human-visible cracks.** Inspect the screenshot series and perform a continuous interactive visual walkthrough before marking the visual gate PASS.

Performance gates stay separate: a headless-frame maximum over 16.7 ms, VRAM-peak sampling, and click-to-presented-pixel edit latency remain unqualified. No optimization or main-branch promotion is authorized by B8.
