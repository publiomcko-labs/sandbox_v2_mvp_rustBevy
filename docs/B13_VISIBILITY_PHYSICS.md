# B13 — GPU terrain visibility and SDF physics readiness guard

Based on the approved B12 candidate, leaving main unchanged.

## Reproduced defects
The uploaded 100s automatic and 120s free-flight B12 videos show abrupt missing wedges inside the view and dynamic rocks traversing sections before their physics tiles are resident. The 100s run logged 13 incomplete horizon samples out of 91 despite earlier CI one-off screenshot passes.

## Code-level causes and changes
1. B3 GPU meshes are generated from zero-filled CPU placeholder vertex buffers, then written by GPU compute. The B3 draw entities carried a static AABB despite uncertain actual GPU-produced positions; they did not carry `NoFrustumCulling`. B13 aligns with B2 by disabling CPU AABB-based rejection specifically on these GPU-produced terrain blocks.
2. Rocks previously turned dynamic up to 28m from the camera while edited SDF terrain collision coverage existed only to 24m, with a 24-tile/frame asynchronous builder. Even at smaller distances it could lag. B13 uses a 16m activation / 19m deactivation hysteresis, defers activation until all SDF collision tiles below the rock's actual edited-SDF footprint are resident at the current revision, and immediately freezes a dynamic rock if its support is evicted.
3. Collider generation is ordered before rock activation in Update. Diagnostics expose activation delays, forced freezes, and resident collider counts.

## Acceptance and limits
The B13 workflow compiles/runs targeted unit tests on Linux and builds Windows Release, captures two Vulkan screenshots, checks GPU/physics diagnostics and shader errors. This does not by itself prove pixel-perfect continuous terrain or full rock physics everywhere. Re-run the user's same 100s and 120s window video collection, with fresh saves, and compare directly against B12 before promotion.

B10 A/B established that disabling water and using uniform LOD alone did not remove the holes. B11's low-resolution far shell cannot repair missing inner SDF geometry. No performance optimizations were undertaken.
