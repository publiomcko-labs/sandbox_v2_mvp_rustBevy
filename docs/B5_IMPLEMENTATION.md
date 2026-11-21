# B5 — Functional rocks and water physics (candidate)

Stage: `SANDBOX_STAGE=B5` uses GPU B3/B4 terrain, persisted edit journal and Avian 0.8 rigid bodies. It adds deterministic 130m rock streaming (shared mesh), dynamic bodies within 28m and demotion outside 36m when resting, a GPU-rendered ocean plane at y=0, exact submerged sphere volume, basic buoyancy/drag and fixed-update physics, and a persistent rock position/velocity journal (`SANDBOX_B5_SAVE_PATH`). Near-camera 4m SDF-sampled static cubes provide a CPU collision proxy, including coarse cave void support.

**Functional baseline limitations to retain until B7**: static collision is a coarse 4m SDF occupancy proxy and is not proven parity-equivalent to the GPU 0.5–2m surface; 100ms edit collider rebuild latency and visual/pixel parity remain unqualified. Ocean has no hydraulic flow, local river geometry or player buoyancy. Water and rock physics are basic and intentionally not optimized.

Tests: sphere submerged-volume physics, sink inequality (rock density 2650 > water 1000), deterministic seeds, save/reopen of rock states, Windows build and physical GPU screenshot. No performance tuning or B3 promotion.
