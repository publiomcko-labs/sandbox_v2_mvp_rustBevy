# B15 — Windows/Vulkan diagnostic acceptance (2026-11-23)

**Qualified result:** `B15_FRAMEBUFFER_SAMPLING_PASS_VISUAL_CAUSALITY_NOT_QUALIFIED`.

## Anchors
- Functional reference: `checkpoint/b13-functional-20261123`.
- B14 diagnostic: `checkpoint/b14-diagnostic-20261123`.
- B15 verified implementation: `b46b13743a1a32a64eb06a90eaa78c0235c690e9` on `diag/b15-rendered-visibility-20261123`.
- Successful GitHub Actions run: https://github.com/publiomcko-labs/sandbox_v2_mvp_rustBevy/actions/runs/45267753711
- Evidence artifact: `b15-rendered-visibility-evidence`, ID `14863707575`; includes B14 CSV, logs, B14 screenshots, B15 raster CSV and 31 rendered 1080p PNGs.
- Release artifact: `b15-windows-release`, ID `14863378115`.

## Verified metrics
| Observation | Result |
|---|---:|
| Windows Release compile | PASS |
| Bevy headless / Vulkan run | PASS |
| Screenshot and trace validation | PASS |
| B15 actual framebuffer samples | 31 |
| Raster request time range | 48.0030–55.7647 game seconds |
| Per-frame B14 records | 4,298 |
| B14 event records | 20,166 |
| Logical missing-required frames during complete run | 589 |
| Logical missing-required frames after 20 s | 0 |
| B14 mesh-swap events | 9,080 |
| B14 mesh-removal events | 3,150 |
| Vulkan runtime errors | 0 |
| Independent B14 screenshots | 3 |

All expected PNG files have nontrivial size and records with increasing timestamps. A visual inspection of the 31 images and a coarse temporal-difference scan found no obvious wide, isolated framebuffer dropout *at the sampled instants*. This cannot rule out a one-frame flicker between captures.

## Disposition
- **B15 test instrumentation and headless raster sampling: DONE/PASS**.
- **Root cause of reported rare visible gaps: OPEN**.
- **60 FPS local interactive capture: NOT RUN** (requires an unlocked interactive Windows desktop; self-hosted GitHub Actions Windows service is Session 0).
- **16.7ms hard budget, edit latency, crack-free LOD transitions and overall MVP acceptance: NOT QUALIFIED**.
- `main` and the B13 functional checkpoint are untouched.
- Next evidence: obtain a 60fps free-flight desktop video using `scripts/b15-local-60fps.ps1` with `SANDBOX_B14_TRACE_DIR` enabled; use `scripts/b15-correlate-video.py` for candidate intervals and visually verify the exact frames before proposing a correction.
