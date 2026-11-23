//! B15 opt-in framebuffer sampling. Each PNG is produced by Bevy's real
//! render camera, not inferred from logical coverage or ViewVisibility.
//! The request time precedes RenderWorld's actual readback; correlate with
//! B14 unix_ms using a tolerance of at least one rendered frame.
use bevy::{
    prelude::*,
    render::view::screenshot::{save_to_disk, Screenshot},
};
use sandbox_gpu_terrain::b2::B2HeadlessTarget;
use std::{
    fs::{self, File},
    io::{BufWriter, Write},
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
};

const MAX_SAMPLES: u32 = 120;

#[derive(Clone)]
struct PendingCapture {
    id: u32,
    requested_t: f32,
    requested_ms: u128,
    camera: Vec3,
    file: PathBuf,
}

#[derive(Resource)]
struct RasterTrace {
    directory: PathBuf,
    log: BufWriter<File>,
    start_s: f32,
    end_s: f32,
    interval_s: f32,
    next_at_s: f32,
    attempted: u32,
    completed: u32,
    pending: Option<PendingCapture>,
    failed: bool,
}

fn unix_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or_default()
}

fn setting(name: &str, default: f32) -> f32 {
    std::env::var(name).ok()
        .and_then(|s| s.parse::<f32>().ok())
        .filter(|v| v.is_finite())
        .unwrap_or(default)
}

pub fn configure(app: &mut App) {
    let Ok(dir) = std::env::var("SANDBOX_B15_RASTER_DIR") else { return; };
    if dir.trim().is_empty() { return; }
    let start = setting("SANDBOX_B15_START_S", 48.0);
    let end = setting("SANDBOX_B15_END_S", 56.0);
    let interval = setting("SANDBOX_B15_INTERVAL_S", 0.25);
    if start < 0.0 || end <= start || end > 110.0 || !(0.016..=2.0).contains(&interval) {
        error!(start, end, interval, "B15 invalid capture window; disabled");
        return;
    }
    let directory = PathBuf::from(dir);
    let opened = (|| -> std::io::Result<_> {
        fs::create_dir_all(&directory)?;
        let mut log = BufWriter::new(File::create(directory.join("b15-raster.csv"))?);
        writeln!(log, "sample,request_game_t_s,request_unix_ms,camera_x,camera_y,camera_z,saved_unix_ms,bytes,file")?;
        log.flush()?;
        Ok(log)
    })();
    match opened {
        Ok(log) => {
            app.insert_resource(RasterTrace {
                directory: directory.clone(), log, start_s: start, end_s: end,
                interval_s: interval, next_at_s: start, attempted: 0,
                completed: 0, pending: None, failed: false,
            })
            .add_systems(Update, sample_frame.after(crate::player::fly_camera));
            info!(path=%directory.display(), start, end, interval,
                "B15 real framebuffer sampling enabled");
        },
        Err(error) => error!(%error, path=%directory.display(), "B15 raster trace could not open"),
    }
}

fn sample_frame(
    mut commands: Commands,
    time: Res<Time>,
    mut trace: ResMut<RasterTrace>,
    camera: Query<&Transform, With<Camera3d>>,
    target: Option<Res<B2HeadlessTarget>>,
) {
    if trace.failed { return; }
    let now = time.elapsed_secs();
    // Enforce only one in-flight asynchronous screenshot. Never confuse
    // a requested frame with a completed framebuffer readback.
    if let Some(pending) = trace.pending.clone() {
        match fs::metadata(&pending.file) {
            Ok(metadata) if metadata.len() > 2_000 => {
                if let Err(error) = writeln!(trace.log,
                    "{},{:.4},{},{:.3},{:.3},{:.3},{},{},{}",
                    pending.id, pending.requested_t, pending.requested_ms,
                    pending.camera.x, pending.camera.y, pending.camera.z,
                    unix_ms(), metadata.len(),
                    pending.file.file_name().and_then(|n| n.to_str()).unwrap_or("unknown")
                ).and_then(|_| trace.log.flush()) {
                    error!(%error, "B15 raster manifest write failed");
                    trace.failed = true;
                    return;
                }
                trace.completed += 1;
                trace.pending = None;
            },
            _ if now - pending.requested_t > 10.0 => {
                error!(id=pending.id, "B15 screenshot failed to complete within 10 seconds");
                trace.failed = true;
                return;
            },
            _ => return,
        }
    }
    if now < trace.next_at_s || now < trace.start_s || now > trace.end_s
        || trace.attempted >= MAX_SAMPLES { return; }
    let Ok(transform) = camera.single() else { return; };
    let id = trace.attempted + 1;
    let file = trace.directory.join(format!("b15-{id:04}.png"));
    let screenshot = match target {
        Some(target) => Screenshot::image(target.0.clone()),
        None => Screenshot::primary_window(),
    };
    commands.spawn(screenshot).observe(save_to_disk(file.clone()));
    trace.pending = Some(PendingCapture {
        id,
        requested_t: now,
        requested_ms: unix_ms(),
        camera: transform.translation,
        file,
    });
    trace.attempted = id;
    trace.next_at_s = now + trace.interval_s;
    if id == 1 || id % 10 == 0 {
        info!(attempted=id, completed=trace.completed, at_s=now,
            "B15 framebuffer readback requested");
    }
}
