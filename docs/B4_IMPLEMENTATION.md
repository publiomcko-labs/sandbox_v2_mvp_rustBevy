# B4 — World editing and durable journal (functional MVP first)

Scope: deterministic add/subtract SDF sphere brushes (half-meter integer coordinates), sparse per-block revisions, halo-aware dirty block tracking, stable persistence and reopen. This goal does not authorize optimization or promotion of B3 performance metrics.

The world core is independent of Bevy; the renderer must use the same brushes in WGSL and publish replacement meshes only when the correct revision is GPU-ready. Edits affect neighboring halo blocks and never delete the previous visible mesh before replacement. The GPU brush limit of 32 edits per affected block is an explicit error, not silent truncation.

Validation: Windows toolchain, CPU regression, Vulkan screenshot, edit save/reopen and latency instrumentation. **B4 remains pending until actual GPU path and input are wired and qualified.**
