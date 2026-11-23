//! B3 opt-in streaming; B2 remains a separate GPU-resident reference checkpoint.
mod player;
mod physics;
mod visual_capture;

use avian3d::prelude::PhysicsPlugins;
use bevy::{
    app::ScheduleRunnerPlugin,
    diagnostic::{FrameTimeDiagnosticsPlugin, LogDiagnosticsPlugin},
    prelude::*,
    render::RenderPlugin,
    window::ExitCondition,
    winit::WinitPlugin,
};
use sandbox_gpu_terrain::{
    GpuTerrainBootstrapPlugin,
    b2::{GpuTerrainB2Plugin, b3::GpuTerrainB3Plugin},
};
use std::time::Duration;

fn main() {
    let stage = std::env::var("SANDBOX_STAGE").unwrap_or_default();
    let b0 = stage.eq_ignore_ascii_case("B0");
    let b3 = ["B3", "B4", "B5", "B6", "B7", "B8", "B9", "B9"].iter().any(|s| stage.eq_ignore_ascii_case(s));
    let headless = !b0
        && (std::env::var("SANDBOX_B2_HEADLESS").as_deref() == Ok("1")
            || std::env::var("SANDBOX_B3_HEADLESS").as_deref() == Ok("1"));
    let title = if stage.eq_ignore_ascii_case("B9") {
        "Sandbox V2 - B9 Creative Exploration and Visual Capture"
    } else if b0 {
        "Sandbox V2 - Rust/Bevy B0 GPU bootstrap"
    } else if b3 {
        "Sandbox V2 - B4/B5 MVP SDF editing and physics"
    } else {
        "Sandbox V2 - B2 GPU Surface Nets SDF terrain"
    };

    let mut app = App::new();
    let plugins = DefaultPlugins
        .set(WindowPlugin {
            primary_window: if headless {
                None
            } else {
                Some(Window {
                    title: title.into(),
                    resolution: (1920, 1080).into(),
                    ..default()
                })
            },
            exit_condition: if headless {
                ExitCondition::DontExit
            } else {
                ExitCondition::OnPrimaryClosed
            },
            ..default()
        })
        .set(RenderPlugin {
            synchronous_pipeline_compilation: headless,
            ..default()
        });
    if headless {
        // A Windows runner service executes in Session 0, where a Winit
        // window cannot reliably render frames. Render to a GPU image
        // instead, following Bevy's official headless_renderer example.
        app.add_plugins(plugins.disable::<WinitPlugin>());
        // Optional uncapped B3 headless throughput run: removes the 16ms
        // scheduler sleep so frame-time measurements expose processing cost.
        // Both A/B arms use exactly the same setting and instrumentation.
        let cadence = if b3 && std::env::var("SANDBOX_B3_BENCH_UNCAPPED").as_deref() == Ok("1") {
            Duration::ZERO
        } else {
            Duration::from_millis(16)
        };
        app.add_plugins(ScheduleRunnerPlugin::run_loop(cadence));
    } else {
        app.add_plugins(plugins);
    }
    app.add_plugins((
        PhysicsPlugins::default(),
        FrameTimeDiagnosticsPlugin::default(),
        LogDiagnosticsPlugin::default(),
    ));
    if b0 {
        app.add_plugins(GpuTerrainBootstrapPlugin);
    } else if b3 {
        app.add_plugins(GpuTerrainB3Plugin);
    } else {
        app.add_plugins(GpuTerrainB2Plugin);
    }
    if ["B5", "B6", "B7", "B8"].iter().any(|s| stage.eq_ignore_ascii_case(s)) {
        app.add_plugins(physics::MvpPhysicsPlugin);
    }
    visual_capture::configure(&mut app);
    app.add_systems(Update, player::fly_camera).run();
}
