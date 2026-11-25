//! B14: optional, per-frame MainWorld audit after Bevy's visibility pass.
//! This observes logical GPU-ready publication and ViewVisibility, NOT pixels.
//! CSV is flushed every frame to retain the final frames if the process exits.

use super::StreamWorld;
use bevy::{asset::AssetId, prelude::*};
use sandbox_streaming::scheduler::{block_distance_xz, HORIZON_M, REQUIRED_LAYERS};
use sandbox_world_core::{BlockCoord, density::terrain_height_half};
use std::{
    collections::HashMap,
    fs::{self, File},
    io::{self, BufWriter, Write},
    path::Path,
    time::{Instant, SystemTime, UNIX_EPOCH},
};

const SEED: u32 = 42;
const HORIZONTAL_RADIUS_BLOCKS: i64 = 10;
const PROBE_DISTANCES_M: [f32; 4] = [24.0, 48.0, 72.0, 96.0];
const PROBE_OFFSETS: [f32; 5] = [-0.65, -0.325, 0.0, 0.325, 0.65];

#[derive(Clone, Copy)]
struct BlockFrame {
    asset: AssetId<Mesh>,
    lod: u8,
    revision: u64,
    published: bool,
    view_selected: bool,
}

#[derive(Resource)]
pub(super) struct B14FrameAudit {
    frames: BufWriter<File>,
    events: BufWriter<File>,
    b15_4_correlated: Option<BufWriter<File>>,
    previous: HashMap<BlockCoord, BlockFrame>,
    prior_commits: u64,
    prior_evictions: u64,
    recorded_frames: u64,
    recorded_events: u64,
    write_failed: bool,
}

impl B14FrameAudit {
    pub(super) fn open(directory: &str) -> io::Result<Self> {
        let directory = Path::new(directory);
        fs::create_dir_all(directory)?;
        let mut frames = BufWriter::new(File::create(directory.join("b14-frames.csv"))?);
        let mut events = BufWriter::new(File::create(directory.join("b14-mesh-events.csv"))?);
        writeln!(frames, "frame,game_t_s,unix_ms,cam_x,cam_y,cam_z,forward_x,forward_z,required,required_published,required_view_selected,missing,required_unselected,logical_visible,view_selected,probes,probe_missing,dispatch_total,evictions_total,lod_commits_total,transition_pending,transition_queued,spawned,removed,removed_published,gpu_ready,mesh_swaps,view_exits,observation_us")?;
        writeln!(events, "frame,game_t_s,unix_ms,x,y,z,event,old_lod,new_lod,old_revision,new_revision,old_published,new_published,old_view,new_view")?;
        frames.flush()?;
        events.flush()?;
        // Identical instrumentation in B11-on and B11-off runs. Does not
        // alter the stable B14 CSV schema or the off-by-default MVP.
        let b15_4_correlated = if std::env::var("SANDBOX_B15_4_CORRELATE").as_deref()
            == Ok("1")
        {
            let mut writer = BufWriter::new(File::create(directory.join("b15-4-costs.csv"))?);
            writeln!(writer, "frame,game_t_s,unix_ms,stream_cpu_us,b14_observation_us,cancelled_lod_total,post_edit_repair_total,edit_transactions_total,transition_pending,transition_target,lod_commits_total,required,missing")?;
            writer.flush()?;
            Some(writer)
        } else {
            None
        };
        Ok(Self {
            frames, events, b15_4_correlated, previous: HashMap::new(),
            prior_commits: 0, prior_evictions: 0, recorded_frames: 0,
            recorded_events: 0, write_failed: false,
        })
    }
}

fn projected_probe_coord(camera: Vec3, facing: Vec2, distance_m: f32, lateral: f32) -> BlockCoord {
    let sideways = Vec2::new(-facing.y, facing.x);
    let point = camera.xz() + facing * distance_m + sideways * (lateral * distance_m);
    // The unedited surface height defines a diagnostic probe only. An
    // edited cave/void can still make this probe a false positive; it is not
    // a pixel-level proof of a hole.
    let height = terrain_height_half(SEED, (point.x * 2.0).round() as i32,
        (point.y * 2.0).round() as i32);
    BlockCoord::from_meter_grid(point.x.floor() as i64, height.floor() as i64,
        point.y.floor() as i64)
}

fn classify_change(old: Option<BlockFrame>, new: Option<BlockFrame>) -> Option<&'static str> {
    match (old, new) {
        (None, Some(_)) => Some("spawn"),
        (Some(_), None) => Some("remove"),
        (Some(a), Some(b)) if a.asset != b.asset => Some("mesh_swap"),
        (Some(a), Some(b)) if a.published != b.published => {
            Some(if b.published { "gpu_ready" } else { "published_lost" })
        },
        (Some(a), Some(b)) if a.view_selected != b.view_selected => {
            Some(if b.view_selected { "view_enter" } else { "view_exit" })
        },
        _ => None,
    }
}

pub(super) fn trace_frame(
    mut audit: ResMut<B14FrameAudit>,
    state: Res<StreamWorld>,
    time: Res<Time>,
    cameras: Query<&Transform, With<Camera3d>>,
    view_flags: Query<&ViewVisibility>,
) {
    if audit.write_failed { return; }
    let Some(camera) = cameras.iter().next() else { return; };
    let started = Instant::now();
    let now = time.elapsed_secs();
    let timestamp_ms = SystemTime::now().duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis()).unwrap_or(0);
    let mut current = HashMap::with_capacity(state.blocks.len());
    let mut logical_visible = 0_usize;
    let mut view_selected = 0_usize;
    for (&coord, block) in &state.blocks {
        let selected = view_flags.get(block.entity).is_ok_and(|v| v.get());
        if block.visible { logical_visible += 1; }
        if block.visible && selected { view_selected += 1; }
        current.insert(coord, BlockFrame {
            asset: block.mesh.id(),
            lod: block.spec.lod,
            revision: block.spec.revision,
            published: block.visible,
            view_selected: selected,
        });
    }
    let center_x = (camera.translation.x / 16.0).floor() as i64;
    let center_z = (camera.translation.z / 16.0).floor() as i64;
    let mut required = 0_usize;
    let mut ready = 0_usize;
    let mut selected_required = 0_usize;
    let pos = camera.translation.to_array();
    for z in (center_z-HORIZONTAL_RADIUS_BLOCKS)..=(center_z+HORIZONTAL_RADIUS_BLOCKS) {
        for x in (center_x-HORIZONTAL_RADIUS_BLOCKS)..=(center_x+HORIZONTAL_RADIUS_BLOCKS) {
            let coord = BlockCoord { x, y: 0, z };
            if block_distance_xz(pos, coord) > HORIZON_M { continue; }
            for y in REQUIRED_LAYERS {
                required += 1;
                let c = BlockCoord { x, y, z };
                if let Some(sample) = current.get(&c) {
                    if sample.published { ready += 1; }
                    if sample.published && sample.view_selected { selected_required += 1; }
                }
            }
        }
    }
    let forward3 = camera.forward();
    let facing = Vec2::new(forward3.x, forward3.z).normalize_or_zero();
    let facing = if facing.length_squared() > 0.01 { facing } else { Vec2::new(0.0, -1.0) };
    let mut probe_missing = 0_usize;
    for distance in PROBE_DISTANCES_M {
        for offset in PROBE_OFFSETS {
            let c = projected_probe_coord(camera.translation, facing, distance, offset);
            if !current.get(&c).is_some_and(|b| b.published) { probe_missing += 1; }
        }
    }
    let previous = std::mem::replace(&mut audit.previous, current);
    let mut updates = Vec::new();
    let mut spawned = 0_usize;
    let mut removed = 0_usize;
    let mut removed_published = 0_usize;
    let mut gpu_ready = 0_usize;
    let mut mesh_swaps = 0_usize;
    let mut view_exits = 0_usize;
    for (&coord, &next) in &audit.previous {
        let old = previous.get(&coord).copied();
        if let Some(kind) = classify_change(old, Some(next)) {
            match kind {
                "spawn" => spawned += 1,
                "gpu_ready" => gpu_ready += 1,
                "mesh_swap" => mesh_swaps += 1,
                "view_exit" => view_exits += 1,
                _ => (),
            }
            updates.push((coord, kind, old, Some(next)));
        }
    }
    for (&coord, &old) in &previous {
        if !audit.previous.contains_key(&coord) {
            removed += 1;
            if old.published { removed_published += 1; }
            updates.push((coord, "remove", Some(old), None));
        }
    }
    // Deterministic event order across identical replays. Do not confuse a
    // removed outside-retention block with a visible screen-space hole.
    updates.sort_by_key(|(coord, kind, _, _)| (coord.x, coord.y, coord.z, *kind));
    let frame = state.frame;
    let mut io_failure = None;
    for (coord, kind, old, new) in updates {
        let old_lod = old.map_or(-1_i32, |v| v.lod as i32);
        let new_lod = new.map_or(-1_i32, |v| v.lod as i32);
        let old_revision = old.map_or(-1_i64, |v| v.revision as i64);
        let new_revision = new.map_or(-1_i64, |v| v.revision as i64);
        if let Err(error) = writeln!(
            audit.events,
            "{frame},{now:.4},{timestamp_ms},{},{},{},{kind},{old_lod},{new_lod},{old_revision},{new_revision},{},{},{},{}",
            coord.x, coord.y, coord.z,
            old.is_some_and(|v| v.published) as u8,
            new.is_some_and(|v| v.published) as u8,
            old.is_some_and(|v| v.view_selected) as u8,
            new.is_some_and(|v| v.view_selected) as u8,
        ) { io_failure = Some(error); break; }
        audit.recorded_events += 1;
    }
    let missing = required.saturating_sub(ready);
    let unselected = ready.saturating_sub(selected_required);
    let observation_us = started.elapsed().as_micros();
    if io_failure.is_none() {
        if let Err(error) = writeln!(audit.frames,
            "{frame},{now:.4},{timestamp_ms},{:.3},{:.3},{:.3},{:.4},{:.4},{required},{ready},{selected_required},{missing},{unselected},{logical_visible},{view_selected},{},{probe_missing},{},{},{},{},{},{spawned},{removed},{removed_published},{gpu_ready},{mesh_swaps},{view_exits},{observation_us}",
            camera.translation.x, camera.translation.y, camera.translation.z,
            facing.x, facing.y,
            PROBE_DISTANCES_M.len() * PROBE_OFFSETS.len(),
            state.dispatches, state.evictions, state.transition_commits,
            state.transition_pending.len(), state.transition_target.len(),
        ) { io_failure = Some(error); }
    }
    if io_failure.is_none() {
        if let Some(writer) = audit.b15_4_correlated.as_mut() {
            if let Err(error) = writeln!(
                writer,
                "{frame},{now:.4},{timestamp_ms},{},{observation_us},{},{},{},{},{},{},{required},{missing}",
                state.b15_4_stream_cpu_last_us,
                state.b15_2_cancelled_lod_jobs,
                state.b15_2_post_edit_repair_blocks,
                state.b15_2_edit_transactions,
                state.transition_pending.len(),
                state.transition_target.len(),
                state.transition_commits,
            ) {
                io_failure = Some(error);
            } else if let Err(error) = writer.flush() {
                io_failure = Some(error);
            }
        }
    }
    if io_failure.is_none() {
        if let Err(error) = audit.frames.flush() { io_failure = Some(error); }
    }
    if io_failure.is_none() {
        if let Err(error) = audit.events.flush() { io_failure = Some(error); }
    }
    if let Some(error) = io_failure {
        error!(%error,frame,"B14 per-frame audit file I/O failed");
        audit.write_failed = true;
        return;
    }
    if (missing > 0 || probe_missing > 0) && (frame % 60 == 0) {
        warn!(frame, missing, probe_missing,unselected,
            "B14 visibility audit: unresolved coverage sampled");
    }
    if frame % 60 == 0 {
        info!(frame,required,ready,missing,probe_missing,
            gpu_ready,mesh_swaps,removed_published,view_exits,observation_us,
            "B14 audit one-second summary");
    }
    audit.prior_commits = state.transition_commits;
    audit.prior_evictions = state.evictions;
    audit.recorded_frames += 1;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn b14_probe_respects_negative_world_coordinates_and_vertical_layers() {
        let camera = Vec3::new(-17.0, 18.0, -20.0);
        let facing = Vec2::new(0.0,-1.0);
        let coord = projected_probe_coord(camera, facing, 24.0, 0.0);
        assert!(coord.x < 0 && coord.z < 0);
        assert!(REQUIRED_LAYERS.contains(&coord.y));
    }
}
