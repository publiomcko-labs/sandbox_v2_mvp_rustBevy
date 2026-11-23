# B13 isolated visual verification using preserved artifacts

The source Release and entire Rust/Avian regression preflight already passed in workflow **45244971799**, commit **34e3e3b394243d35009c83296fe79a8f247798f0**. That workflow's final `visual-smoke` job only failed due to a Windows PowerShell `Set-StrictMode` pipeline issue when `Where-Object` returns no objects; it had already produced two Vulkan frames and zero GPU errors.

This CI-only branch does not change any Rust source. The workflow downloads **b13-frustum-physics-windows-release** directly from the prior run with read-only Actions permissions, then reruns only the original graphical smoke with a fixed `@(...).Count` condition. It does **not** trigger the original expensive B13 preflight workflow because its branch name is `ci/b13-visual-reuse-20261123`, outside the `fix/b13-*` trigger.

Acceptance: 2 valid screenshots, positive SDF collider and rock residency markers, far field and frustum protection active, no Vulkan errors. Continuous visual continuity and gameplay physics still require user recordings; a smoke pass is not proof of the original defect being absent.
