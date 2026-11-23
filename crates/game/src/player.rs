//! Flying camera with opt-in B9 Minecraft-style creative exploration and
//! fully scripted, reproducible visual-gap survey. All B8 routes stay intact.
use bevy::{
    input::mouse::AccumulatedMouseMotion,
    prelude::*,
    window::{CursorGrabMode, CursorOptions, PrimaryWindow},
};
use std::sync::OnceLock;

const NORMAL_SPEED_MPS: f32 = 18.0;
const SPRINT_SPEED_MPS: f32 = 36.0;
const PRECISE_SPEED_MPS: f32 = 6.0;
const MOUSE_SENSITIVITY: f32 = 0.0025;

#[derive(Default)]
struct B9LocalCamera {
    route_segment: Option<usize>,
    announced: bool,
}

/// Each segment is measured in game elapsed seconds, after the initial
/// 12-second warmup. Segments deliberately alternate direction so the
/// scheduler is tested against revisiting and diagonal movement. Do NOT
/// pause motion to conceal gaps. The speed is 18 m/s in every segment.
fn b9_route(elapsed_s: f32) -> (usize, &'static str, Vec3) {
    if elapsed_s < 12.0 {
        (0, "warmup", Vec3::ZERO)
    } else if elapsed_s < 30.0 {
        (1, "east-18mps", Vec3::X)
    } else if elapsed_s < 46.0 {
        (2, "north-18mps-turn", Vec3::NEG_Z)
    } else if elapsed_s < 62.0 {
        (3, "west-18mps-return", Vec3::NEG_X)
    } else if elapsed_s < 78.0 {
        (4, "south-18mps-return", Vec3::Z)
    } else if elapsed_s < 94.0 {
        (5, "northeast-diagonal-18mps", Vec3::new(1.0, 0.0, -1.0).normalize())
    } else if elapsed_s < 110.0 {
        (6, "northwest-diagonal-18mps", Vec3::new(-1.0, 0.0, -1.0).normalize())
    } else {
        (7, "final-hold", Vec3::ZERO)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn b9_survey_covers_turns_revisits_diagonal_and_fixed_speed() {
        let steps = [(0.0, 0), (12.0, 1), (31.0, 2), (47.0, 3),
                     (63.0, 4), (79.0, 5), (95.0, 6), (112.0, 7)];
        for (seconds, expected) in steps {
            assert_eq!(b9_route(seconds).0, expected);
        }
        for t in [15.0, 35.0, 50.0, 65.0, 85.0, 100.0] {
            assert!((b9_route(t).2.length() - 1.0).abs() < 1.0e-6);
        }
    }
}

pub fn fly_camera(
    keys: Res<ButtonInput<KeyCode>>,
    time: Res<Time>,
    motion: Res<AccumulatedMouseMotion>,
    mut cursor: Query<&mut CursorOptions, With<PrimaryWindow>>,
    mut cameras: Query<&mut Transform, With<Camera3d>>,
    mut local: Local<B9LocalCamera>,
) {
    static B3_AUTOROUTE: OnceLock<bool> = OnceLock::new();
    let automated_b3 = *B3_AUTOROUTE.get_or_init(|| {
        matches!(
            std::env::var("SANDBOX_STAGE").as_deref(),
            Ok("B3" | "B4" | "B5" | "B6" | "B7" | "B8")
        ) && std::env::var("SANDBOX_B3_ROUTE").as_deref() == Ok("straight")
    });
    static B9_SURVEY: OnceLock<bool> = OnceLock::new();
    let survey = *B9_SURVEY.get_or_init(|| {
        std::env::var("SANDBOX_STAGE").as_deref() == Ok("B9")
            && std::env::var("SANDBOX_B9_TEST_ROUTE").as_deref() == Ok("survey")
    });
    static B9_CREATIVE: OnceLock<bool> = OnceLock::new();
    let creative = *B9_CREATIVE.get_or_init(|| {
        std::env::var("SANDBOX_STAGE").as_deref() == Ok("B9")
            || std::env::var("SANDBOX_B9_CREATIVE").as_deref() == Ok("1")
    });
    let elapsed = time.elapsed_secs();
    let dt = time.delta_secs();
    if survey {
        let (segment, name, horizontal) = b9_route(elapsed);
        for mut transform in &mut cameras {
            transform.translation += horizontal * (NORMAL_SPEED_MPS * dt);
            if horizontal.length_squared() > 0.5 {
                let look = transform.translation + horizontal * 20.0 + Vec3::new(0.0, -9.0, 0.0);
                transform.look_at(look, Vec3::Y);
            }
            if local.route_segment != Some(segment) {
                local.route_segment = Some(segment);
                info!(
                    segment,
                    route = name,
                    elapsed_s = elapsed,
                    x = transform.translation.x,
                    y = transform.translation.y,
                    z = transform.translation.z,
                    "B9 route segment"
                );
            }
        }
        return;
    }
    if automated_b3 && elapsed >= 5.0 {
        for mut transform in &mut cameras {
            transform.translation.x += NORMAL_SPEED_MPS * dt;
        }
        return;
    }
    if creative {
        if !local.announced {
            local.announced = true;
            info!("B9 creative fly controls: TAB locks/unlocks mouse; ESC unlocks; WASD move, SPACE/E up, SHIFT/Q down, CTRL sprint, ALT slow, left/right edit SDF");
        }
        let mut mouse_locked = false;
        if let Ok(mut opts) = cursor.single_mut() {
            if keys.just_pressed(KeyCode::Tab) {
                mouse_locked = opts.grab_mode == CursorGrabMode::None;
            } else {
                mouse_locked = opts.grab_mode != CursorGrabMode::None;
            }
            if keys.just_pressed(KeyCode::Escape) {
                mouse_locked = false;
            }
            opts.grab_mode = if mouse_locked { CursorGrabMode::Locked } else { CursorGrabMode::None };
            opts.visible = !mouse_locked;
        }
        for mut transform in &mut cameras {
            if mouse_locked {
                let (mut yaw, mut pitch, _) = transform.rotation.to_euler(EulerRot::YXZ);
                yaw -= motion.delta.x * MOUSE_SENSITIVITY;
                pitch = (pitch - motion.delta.y * MOUSE_SENSITIVITY).clamp(-1.52, 1.52);
                transform.rotation = Quat::from_euler(EulerRot::YXZ, yaw, pitch, 0.0);
            }
            // Minecraft creative movement uses the camera yaw only for
            // horizontal motion, so looking down does not dive into terrain.
            let forward = transform.rotation * Vec3::NEG_Z;
            let right = transform.rotation * Vec3::X;
            let flat_forward = Vec3::new(forward.x, 0.0, forward.z).normalize_or_zero();
            let flat_right = Vec3::new(right.x, 0.0, right.z).normalize_or_zero();
            let mut direction = Vec3::ZERO;
            if keys.pressed(KeyCode::KeyW) { direction += flat_forward; }
            if keys.pressed(KeyCode::KeyS) { direction -= flat_forward; }
            if keys.pressed(KeyCode::KeyA) { direction -= flat_right; }
            if keys.pressed(KeyCode::KeyD) { direction += flat_right; }
            if keys.pressed(KeyCode::Space) || keys.pressed(KeyCode::KeyE) { direction += Vec3::Y; }
            if keys.pressed(KeyCode::ShiftLeft) || keys.pressed(KeyCode::KeyQ) { direction -= Vec3::Y; }
            let speed = if keys.pressed(KeyCode::ControlLeft) {
                SPRINT_SPEED_MPS
            } else if keys.pressed(KeyCode::AltLeft) {
                PRECISE_SPEED_MPS
            } else {
                NORMAL_SPEED_MPS
            };
            transform.translation += direction.normalize_or_zero() * (speed * dt);
        }
        return;
    }
    // Legacy controls stay unchanged for B0-B8.
    let mut velocity = Vec3::ZERO;
    if keys.pressed(KeyCode::KeyW) { velocity.z -= 1.0; }
    if keys.pressed(KeyCode::KeyS) { velocity.z += 1.0; }
    if keys.pressed(KeyCode::KeyA) { velocity.x -= 1.0; }
    if keys.pressed(KeyCode::KeyD) { velocity.x += 1.0; }
    if keys.pressed(KeyCode::KeyE) { velocity.y += 1.0; }
    if keys.pressed(KeyCode::KeyQ) { velocity.y -= 1.0; }
    for mut transform in &mut cameras {
        transform.translation += velocity.normalize_or_zero() * (NORMAL_SPEED_MPS * dt);
    }
}
