use bevy::prelude::*;
use std::sync::OnceLock;

const HORIZONTAL_SPEED_MPS: f32 = 18.0;

/// B0 free-flight camera. This does not assert terrain or collision functionality.
pub fn fly_camera(
    keys: Res<ButtonInput<KeyCode>>,
    time: Res<Time>,
    mut cameras: Query<&mut Transform, With<Camera3d>>,
) {
    // Deterministic 18m/s route for B3 self-hosted headless smoke.
    // Warm up the full 130m ring first; never auto-pause to hide gaps.
    static B3_AUTOROUTE: OnceLock<bool> = OnceLock::new();
    let automated = *B3_AUTOROUTE.get_or_init(|| {
        matches!(
            std::env::var("SANDBOX_STAGE").as_deref(),
            Ok("B3" | "B4" | "B5" | "B6" | "B7" | "B8")
        ) && std::env::var("SANDBOX_B3_ROUTE").as_deref() == Ok("straight")
    });
    let mut velocity = Vec3::ZERO;
    if automated && time.elapsed_secs() >= 5.0 {
        for mut transform in &mut cameras {
            transform.translation.x += HORIZONTAL_SPEED_MPS * time.delta_secs();
        }
        return;
    }

    if keys.pressed(KeyCode::KeyW) {
        velocity.z -= 1.0;
    }
    if keys.pressed(KeyCode::KeyS) {
        velocity.z += 1.0;
    }
    if keys.pressed(KeyCode::KeyA) {
        velocity.x -= 1.0;
    }
    if keys.pressed(KeyCode::KeyD) {
        velocity.x += 1.0;
    }
    if keys.pressed(KeyCode::KeyE) {
        velocity.y += 1.0;
    }
    if keys.pressed(KeyCode::KeyQ) {
        velocity.y -= 1.0;
    }

    for mut transform in &mut cameras {
        transform.translation +=
            velocity.normalize_or_zero() * HORIZONTAL_SPEED_MPS * time.delta_secs();
    }
}
