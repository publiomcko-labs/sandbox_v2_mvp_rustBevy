//! Optional 46-second cross-engine benchmark. Does not modify normal gameplay.
use bevy::prelude::*;
use std::{
    fs::File,
    io::{BufWriter, Write},
    time::Instant,
};

const WARMUP_S: f32 = 12.0;
const END_S: f32 = 46.0;

pub struct ComparisonV1Plugin;

#[derive(Resource)]
struct ComparisonTrace {
    last: Instant,
    samples: Vec<(f32, f64)>,
    finished: bool,
}

impl Plugin for ComparisonV1Plugin {
    fn build(&self, app: &mut App) {
        app.insert_resource(ComparisonTrace {
            last: Instant::now(),
            samples: Vec::with_capacity(5000),
            finished: false,
        })
        .add_systems(Last, sample_frame);
    }
}

fn sample_frame(
    time: Res<Time>,
    mut trace: ResMut<ComparisonTrace>,
    mut exit: MessageWriter<AppExit>,
) {
    if trace.finished {
        return;
    }
    let now = Instant::now();
    let t = time.elapsed_secs();
    let interval_ms = now.duration_since(trace.last).as_secs_f64() * 1000.0;
    trace.last = now;
    if (WARMUP_S..=END_S).contains(&t) && interval_ms > 0.0 {
        trace.samples.push((t, interval_ms));
    }
    if t < END_S {
        return;
    }
    trace.finished = true;
    let path = match std::env::var("SANDBOX_COMPARISON_TRACE_CSV") {
        Ok(path) if !path.trim().is_empty() => path,
        _ => {
            error!("COMPARISON_V1_TRACE_PATH_MISSING");
            std::process::exit(3);
        }
    };
    let written = (|| -> std::io::Result<()> {
        let file = File::create(&path)?;
        let mut writer = BufWriter::new(file);
        writeln!(writer, "t_s,interval_ms")?;
        for (time, millis) in &trace.samples {
            writeln!(writer, "{time:.6},{millis:.6}")?;
        }
        writer.flush()
    })();
    if let Err(err) = written {
        error!(%err, %path, "COMPARISON_V1_TRACE_WRITE_FAILED");
        std::process::exit(3);
    }
    info!(
        frames = trace.samples.len(),
        duration_s = END_S,
        warmup_s = WARMUP_S,
        "COMPARISON_V1_COMPLETE"
    );
    exit.write(AppExit::Success);
}
