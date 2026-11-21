# B6/B7 — Full functional MVP baseline, no optimizations

Run `SANDBOX_STAGE=B6` or `B7` on the same B3/B4/B5 build. A 1080p Vulkan headless route at 18m/s exercises streaming at 130m, mixed LOD, persisted GPU edit, rocks, local SDF collision proxies and flat ocean physics. Two runs validate save/reopen. GitHub Actions collect FPS/frame diagnostics, CPU streaming, process RAM, approximate GPU-memory usage, screenshots and B4/B5 journal artifacts.

B7 creates a PASS/FAIL/HOLD matrix for every original criterion. Headless GPU frame timing **does not** prove Windows swapchain present frame time, and two screenshots do not prove temporal absence of cracks/flicker. Missing interactive, real-pixel edit timing, cave colliders, rock/water behavior and VRAM-peak checks must stay HOLD rather than be inferred from passing CI.

Performance optimization is explicitly deferred to a separate campaign **after the complete MVP feature path is implemented**. The B3 uncapped mixed LOD 27.399ms peak is retained as an open performance issue. No B3 or performance acceptance promotion is authorized by adding these tests.
