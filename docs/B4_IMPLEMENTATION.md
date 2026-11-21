# B4 — World editing and durable journal (functional MVP first)

Scope: deterministic add/subtract SDF sphere brushes (half-meter integer coordinates), sparse per-block revisions, halo-aware dirty block tracking, stable persistence and reopen. This goal does not authorize optimization or promotion of B3 performance metrics.

The world core is independent of Bevy; the renderer must use the same brushes in WGSL and publish replacement meshes only when the correct revision is GPU-ready. Edits affect neighboring halo blocks and never delete the previous visible mesh before replacement. The GPU brush limit of 32 edits per affected block is an explicit error, not silent truncation.

Validation: Windows toolchain, CPU regression, Vulkan screenshot, edit save/reopen and latency instrumentation. **B4 remains pending until actual GPU path and input are wired and qualified.**

Integration: `SANDBOX_STAGE=B4` enables persistent SDF brushes; left mouse subtracts solid, right mouse adds solid by sphere CSG. `SANDBOX_B4_SAVE_PATH` configures a durable local journal; edited blocks and halos are rebuilt through the retained B3 GPU path with revision-gated replacement and obsolete results rejected. `SANDBOX_B4_TEST_BRUSH=1` triggers a deterministic SDF-targeted subtract operation for CI. GPU shader `sdf_density_b4.wgsl` does not change the B1 numeric reference.

Caveat: the reported `latency_ms` measures input to GPU compute readiness and queued publication, not strict click-to-display; the 100ms visual gate remains open until measured with real presentation.
