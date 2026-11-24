//! B3 streaming integration for the B2 GPU-resident extraction path.
//!
//! Present whole 16m logical blocks; retain old meshes while adding new ones.
//! No GPU->CPU mesh readback and no mixed-LOD cracks (uniform LOD2 baseline).
//! Presentation is delayed until the GPU compute encoder has dispatched all
//! three passes. The CPU does not synchronously wait for GPU completion.

use super::{
    B2HeadlessTarget, B2Pipelines, B2ResidentBuffers, BuildSdfMesh, PendingB2, b3_mixed_counts,
    compute_b2, init_b2_pipelines, prepare_b2,
};
use bevy::{
    asset::RenderAssetUsages,
    camera::{RenderTarget, visibility::NoFrustumCulling},
    core_pipeline::schedule::camera_driver,
    mesh::Indices,
    prelude::*,
    render::{
        Render, RenderApp, RenderStartup,
        extract_component::ExtractComponentPlugin,
        mesh::allocator::MeshAllocatorSettings,
        render_resource::{BufferUsages, PrimitiveTopology, TextureFormat},
        renderer::RenderGraph,
    },
};
use sandbox_streaming::{
    lod::{LodFrontier, SeamInfo, frontier, next_lod, seam_info},
    scheduler::{
        BLOCKS_PER_FRAME, STREAM_LOD, StreamPlan, block_distance_xz, plan, within_retention,
    },
};
use sandbox_world_core::{BlockCoord, density::{DensityGrid, terrain_height_half}, edits::{Brush, EditMode, WorldEdits}};
use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Mutex},
    time::Instant,
    path::PathBuf,
};

const SEED: u32 = 42;
const MAX_RESIDENT_BLOCKS: usize = 1100;
const OPTIMIZED_BLOCKS_PER_FRAME: usize = 5;
const PLAN_UPDATE_DISTANCE_M: f32 = 1.5;
const PLAN_UPDATE_MAX_AGE_FRAMES: u64 = 12;
const DIRECTION_COSINE_THRESHOLD: f32 = 0.96;

/// MainWorld ↔ RenderWorld: renderer inserts IDs after all compute passes
/// have been encoded. MainWorld consumes readiness on a subsequent frame.
#[derive(Resource, Clone, Default)]
pub(super) struct B3ReadySet(pub Arc<Mutex<HashSet<AssetId<Mesh>>>>);

mod frame_audit;

pub struct GpuTerrainB3Plugin;

impl Plugin for GpuTerrainB3Plugin {
    fn build(&self, app: &mut App) {
        let ready = B3ReadySet::default();
        app.insert_resource(ready.clone())
            .init_resource::<StreamWorld>()
            .init_resource::<B4EditState>()
            .add_systems(Update, b4_brush_input)
            .add_plugins(ExtractComponentPlugin::<BuildSdfMesh>::default())
            .add_systems(Startup, setup_b3_scene)
            .add_systems(PostUpdate, stream_b3);

        // B14 stays completely absent outside explicit diagnostic runs.
        // The Last schedule sees the current frame's PostUpdate publication
        // and Bevy ViewVisibility after visibility propagation/culling.
        if let Ok(trace_dir) = std::env::var("SANDBOX_B14_TRACE_DIR") {
            if !trace_dir.trim().is_empty() {
                match frame_audit::B14FrameAudit::open(&trace_dir) {
                    Ok(audit) => {
                        app.insert_resource(audit)
                            .add_systems(Last, frame_audit::trace_frame);
                        info!(path=%trace_dir, "B14 per-frame visibility trace enabled");
                    },
                    Err(error) => {
                        error!(%error,path=%trace_dir,
                            "B14 per-frame trace initialization failed");
                    },
                }
            }
        }

        let Some(render_app) = app.get_sub_app_mut(RenderApp) else {
            return;
        };
        render_app.world_mut().insert_resource(ready);
        render_app
            .init_resource::<PendingB2>()
            .init_resource::<B2ResidentBuffers>()
            .add_systems(RenderStartup, init_b2_pipelines)
            .add_systems(Render, prepare_b2)
            .add_systems(RenderGraph, compute_b2.before(camera_driver));
    }

    fn finish(&self, app: &mut App) {
        let Some(render_app) = app.get_sub_app_mut(RenderApp) else {
            return;
        };
        let mut settings = render_app
            .world_mut()
            .resource_mut::<MeshAllocatorSettings>();
        settings.extra_buffer_usages = BufferUsages::STORAGE;
        // B15.1: compare on/off under identical B14 instrumentation.
        // Larger initial slabs/growth reduce GPU-produced mesh relocation,
        // but increase reserved VRAM. No change unless explicitly selected.
        if std::env::var("SANDBOX_B15_1_STABLE_SLABS").as_deref() == Ok("1") {
            settings.slab_allocator_settings.min_slab_size = 16 * 1024 * 1024;
            settings.slab_allocator_settings.growth_factor = 2.0;
            info!("B15.1 stable GPU mesh slabs enabled (16 MiB min, growth 2x)");
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct LodSpec {
    lod: u8,
    seam: SeamInfo,
    revision: u64,
}

struct ActiveBlock {
    mesh: Handle<Mesh>,
    entity: Entity,
    visible: bool,
    spec: LodSpec,
}

struct PendingUpgrade {
    block: ActiveBlock,
    ready: bool,
}

#[derive(Resource, Default)]
pub struct B4EditState {
    pub world: WorldEdits,
    path: PathBuf,
    enabled: bool,
    load_failed: bool,
    auto_test_done: bool,
    scripted_edit_index: usize,
    pending_latency: HashMap<BlockCoord, Instant>,
}

fn b4_brush_input(
    mut editor: ResMut<B4EditState>,
    mouse: Res<ButtonInput<MouseButton>>,
    time: Res<Time>,
    camera: Query<&Transform, With<Camera3d>>,
) {
    if !editor.enabled || editor.load_failed { return; }
    // Deterministic, opt-in six-edit stress arm for B15.1. The B11 route
    // passes new, revisited, and LOD-refined terrain in both A/B runs.
    // Default interactive controls and persisted gameplay remain unchanged.
    const SCRIPT_TIMES: [f32; 6] = [25.0, 28.0, 31.0, 34.0, 37.0, 40.0];
    let scripted = std::env::var("SANDBOX_B15_1_SCRIPTED_EDITS").as_deref() == Ok("1")
        && editor.scripted_edit_index < SCRIPT_TIMES.len()
        && time.elapsed_secs() >= SCRIPT_TIMES[editor.scripted_edit_index];
    let auto = std::env::var("SANDBOX_B4_TEST_BRUSH").as_deref() == Ok("1")
        && !editor.auto_test_done && time.elapsed_secs() > 8.0;
    let mode = if scripted {
        if editor.scripted_edit_index % 2 == 0 { EditMode::Subtract }
        else { EditMode::Add }
    } else if auto || mouse.just_pressed(MouseButton::Left) {
        EditMode::Subtract
    } else if mouse.just_pressed(MouseButton::Right) {
        EditMode::Add
    } else {
        return;
    };
    if auto { editor.auto_test_done = true; }
    if scripted { editor.scripted_edit_index += 1; }
    let Some(transform) = camera.iter().next() else { return; };
    let center_half = if scripted {
        let x = (transform.translation.x * 2.0).round() as i32;
        let z = (transform.translation.z * 2.0).round() as i32;
        let y = (terrain_height_half(SEED, x, z) * 2.0).round() as i32;
        info!(index=editor.scripted_edit_index, t_s=time.elapsed_secs(),
            "B15.1 scripted edit requested");
        [x,y,z]
    } else {
        // Preserve original raycast for all interactive edits.
        let mut hit = None;
        for step in 1..=200 {
            let p = transform.translation + transform.forward() * (step as f32 * 0.25);
            let half = [(p.x * 2.0).round() as i32,
                (p.y * 2.0).round() as i32, (p.z * 2.0).round() as i32];
            if editor.world.sample(SEED, half) <= 0.0 {
                hit = Some(half);
                break;
            }
        }
        let Some(center_half) = hit else {
            warn!("B4 input: no SDF surface within ray range (50m)");
            return;
        };
        center_half
    };
    let previous = editor.world.clone();
    let brush = Brush { center_half, radius_half: 6, mode };
    match editor.world.apply(brush) {
        Err(reason) => error!(reason, "B4 edit rejected"),
        Ok(changed) => {
            if let Err(error) = editor.world.save_to(&editor.path) {
                editor.world = previous;
                error!(%error, "B4 journal save failed; edit rolled back");
                return;
            }
            let instant = Instant::now();
            for block in &changed { editor.pending_latency.insert(*block, instant); }
            info!(?center_half, ?mode, touched=changed.len(), edits=editor.world.len(), "B4 edit persisted; GPU rebuild queued");
        }
    }
}

#[derive(Resource, Default)]
struct StreamWorld {
    blocks: HashMap<BlockCoord, ActiveBlock>,
    material: Option<Handle<StandardMaterial>>,
    previous_position: Option<Vec3>,
    frame: u64,
    dispatches: u64,
    evictions: u64,
    cached_plan: Option<StreamPlan>,
    plan_position: Vec3,
    plan_direction: Vec2,
    plan_frame: u64,
    plan_refreshes: u64,
    baseline_scheduler: bool,
    cpu_samples_us: Vec<u32>,
    mixed_lod: bool,
    last_lod_epoch: u64,
    transition_target: HashMap<BlockCoord, LodSpec>,
    // Edited chunks commit independently of unrelated LOD refinement cohorts.
    edit_priority: HashSet<BlockCoord>,
    transition_pending: HashMap<BlockCoord, PendingUpgrade>,
    transition_commits: u64,
    atomic_publication_errors: u64,
    lod_audited_frames: u64,
    lod_bad_frames: u64,
    b15_2_atomic_edits: bool,
    b15_2_edit_transactions: u64,
    b15_2_cancelled_lod_jobs: u64,
    b15_2_edit_cohort_blocks: u64,
    b15_2_post_edit_repair_blocks: u64,
    b15_2_last_edit_frame: Option<u64>,
}

fn setup_b3_scene(
    mut commands: Commands,
    mut state: ResMut<StreamWorld>,
    mut materials: ResMut<Assets<StandardMaterial>>,
    mut images: ResMut<Assets<Image>>,
    mut editor: ResMut<B4EditState>,
) {
    state.baseline_scheduler = std::env::var("SANDBOX_B3_SCHEDULER").as_deref() == Ok("baseline");
    // Default ON only in B15.2 experimental source; opt out for matched A/B.
    state.b15_2_atomic_edits =
        std::env::var("SANDBOX_B15_2_EDIT_ATOMIC").as_deref() != Ok("0");
    info!(atomic_edits=state.b15_2_atomic_edits,
        "B15.2 SDF+LOD seam transactional publication configuration");
    let stage = std::env::var("SANDBOX_STAGE").unwrap_or_default();
    editor.enabled = matches!(stage.as_str(), "B4" | "B5" | "B6" | "B7" | "B8" | "B9" | "B11")
        || std::env::var("SANDBOX_B4_ENABLE").as_deref() == Ok("1");
    editor.path = std::env::var_os("SANDBOX_B4_SAVE_PATH").map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("world-b4.edits"));
    if editor.enabled {
        match WorldEdits::load_from(&editor.path) {
            Ok(world) => {
                info!(edits=world.len(), path=%editor.path.display(), "B4 journal loaded");
                editor.world = world;
            },
            Err(error) => {
                editor.load_failed = true;
                error!(%error, path=%editor.path.display(), "B4 corrupt journal: edits disabled to protect save");
            }
        }
    }
    // Mixed LOD is deliberately experimental until Vulkan seam and
    // long-route visual gates pass. The B3 reference still defaults LOD2.
    state.mixed_lod = std::env::var("SANDBOX_B3_MIXED_LOD").as_deref() == Ok("1");
    state.cpu_samples_us = Vec::with_capacity(60);
    state.material = Some(materials.add(StandardMaterial {
        base_color: Color::srgb(0.34, 0.59, 0.37),
        perceptual_roughness: 0.9,
        cull_mode: None,
        ..default()
    }));

    commands.spawn((
        DirectionalLight {
            illuminance: 12_000.0,
            shadow_maps_enabled: false,
            ..default()
        },
        Transform::from_rotation(Quat::from_euler(EulerRot::XYZ, -0.8, 0.6, 0.0)),
    ));

    let cave = std::env::var("SANDBOX_B2_SCENE").as_deref() == Ok("cave");
    let camera_transform = if cave {
        Transform::from_xyz(-8.0, -7.0, 2.0).looking_at(Vec3::new(6.0, -7.0, -3.0), Vec3::Y)
    } else {
        Transform::from_xyz(-17.0, 15.0, 14.0).looking_at(Vec3::new(4.0, 2.0, -7.0), Vec3::Y)
    };
    if std::env::var("SANDBOX_B2_HEADLESS").as_deref() == Ok("1")
        || std::env::var("SANDBOX_B3_HEADLESS").as_deref() == Ok("1")
    {
        let (width, height) = if std::env::var("SANDBOX_B3_RENDER_1080P").as_deref() == Ok("1") {
            (1920, 1080)
        } else {
            (1280, 720)
        };
        let mut image =
            Image::new_target_texture(width, height, TextureFormat::Rgba8UnormSrgb, None);
        image.asset_usage = RenderAssetUsages::RENDER_WORLD;
        let target = images.add(image);
        commands.insert_resource(B2HeadlessTarget(target.clone()));
        commands.spawn((
            Camera3d::default(),
            RenderTarget::Image(target.into()),
            camera_transform,
        ));
    } else {
        commands.spawn((Camera3d::default(), camera_transform));
    }
    info!("B13 GPU mesh visibility: frustum culling disabled for compute-produced vertices");
    info!(
        "B3 streaming stage initialized: 130m horizon, 36m directional prefetch, uniform LOD2, 18m/s route optional"
    );
}

/// Assemble a GPU-resident allocation placeholder. Only the GPU compute
/// pipeline writes true positions, normals, indices and transition quads.
fn create_block(
    commands: &mut Commands,
    meshes: &mut Assets<Mesh>,
    material: &Handle<StandardMaterial>,
    coord: BlockCoord,
    spec: LodSpec,
    world: &WorldEdits,
    priority: bool,
) -> Option<ActiveBlock> {
    let grid = DensityGrid::new(coord, spec.lod).ok()?;
    let (vertex_count, index_count) = b3_mixed_counts(grid, spec.seam.negative_face_mask);
    let mesh = Mesh::new(
        PrimitiveTopology::TriangleList,
        RenderAssetUsages::RENDER_WORLD,
    )
    .with_inserted_attribute(Mesh::ATTRIBUTE_POSITION, vec![[0.0_f32; 3]; vertex_count])
    .with_inserted_attribute(Mesh::ATTRIBUTE_NORMAL, vec![[0.0_f32; 3]; vertex_count])
    .with_inserted_attribute(Mesh::ATTRIBUTE_UV_0, vec![[0.0_f32; 2]; vertex_count])
    .with_inserted_indices(Indices::U32(vec![0_u32; index_count]));
    let handle = meshes.add(mesh);
    let entity = commands
        .spawn((
            BuildSdfMesh {
                handle: handle.clone(),
                grid,
                seed: SEED,
                seam_mask: spec.seam.negative_face_mask,
                neighbor_lod_words: spec.seam.neighbor_words,
                brushes: world.brushes_for_grid(grid),
                priority,
            },
            Mesh3d(handle.clone()),
            MeshMaterial3d(material.clone()),
            Visibility::Hidden,
            // Positions and indices are generated after mesh allocation on the
            // GPU. The CPU placeholder has only zero vertices, so its AABB
            // cannot be trusted for camera-frustum rejection. Keep B3's
            // actually resident geometry drawable, as B2 already does.
            NoFrustumCulling,
            Transform::from_xyz(
                coord.x as f32 * 16.0,
                coord.y as f32 * 16.0,
                coord.z as f32 * 16.0,
            ),
        ))
        .id();
    Some(ActiveBlock {
        mesh: handle,
        entity,
        visible: false,
        spec,
    })
}

/// A LOD update is a transaction: keep the old visible topology until all
/// new GPU-resident meshes in this neighborhood are ready. Direct-face AND
/// diagonal 3x3x3 dependencies are grouped so packed seam LODs and neighbor
/// geometry cannot publish at incompatible revisions.
fn connected_ready_components(
    target: &HashMap<BlockCoord, LodSpec>,
    pending: &HashMap<BlockCoord, PendingUpgrade>,
) -> Vec<Vec<BlockCoord>> {
    let mut remaining: HashSet<BlockCoord> = target.keys().copied().collect();
    let mut ready = Vec::new();
    while let Some(first) = remaining.iter().copied().next() {
        remaining.remove(&first);
        let mut group = vec![first];
        let mut at = 0;
        while at < group.len() {
            let current = group[at];
            at += 1;
            for dx in -1..=1 {
                for dy in -1..=1 {
                    for dz in -1..=1 {
                        if dx == 0 && dy == 0 && dz == 0 {
                            continue;
                        }
                        let neighbor = BlockCoord {
                            x: current.x + dx,
                            y: current.y + dy,
                            z: current.z + dz,
                        };
                        if remaining.remove(&neighbor) {
                            group.push(neighbor);
                        }
                    }
                }
            }
        }
        if group
            .iter()
            .all(|coord| pending.get(coord).is_some_and(|p| p.ready))
        {
            ready.push(group);
        }
    }
    ready
}

/// B15.1: a streamed LOD2 block cannot always assume uniform neighbors:
/// visible LOD1 geometry may already have been refined in that direction.
fn initial_stream_seam(
    coord: BlockCoord,
    blocks: &HashMap<BlockCoord, ActiveBlock>,
) -> SeamInfo {
    let mut levels = HashMap::new();
    for dx in -1..=1 {
        for dy in -1..=1 {
            for dz in -1..=1 {
                let neighbor = BlockCoord {
                    x: coord.x + dx, y: coord.y + dy, z: coord.z + dz,
                };
                if let Some(active) = blocks.get(&neighbor) {
                    levels.insert(neighbor, active.spec.lod);
                }
            }
        }
    }
    levels.insert(coord, STREAM_LOD);
    seam_info(coord, &levels)
}

/// A LOD cohort must not publish an incomplete seam against blocks that
/// stay visible. Edit-only cohorts preserve the active LOD and are not
/// blocked by pre-existing seam defects elsewhere.
fn cohort_seams_valid(
    cohort: &[BlockCoord],
    blocks: &HashMap<BlockCoord, ActiveBlock>,
    pending: &HashMap<BlockCoord, PendingUpgrade>,
) -> bool {
    let mut specs: HashMap<BlockCoord, LodSpec> = blocks.iter()
        .filter_map(|(&coord, block)| block.visible.then_some((coord, block.spec)))
        .collect();
    for &coord in cohort {
        let Some(replacement) = pending.get(&coord) else { return false; };
        specs.insert(coord, replacement.block.spec);
    }
    for &coord in cohort {
        for (axis, delta) in [(0, [1, 0, 0]), (1, [0, 1, 0]), (2, [0, 0, 1]),
                               (0, [-1, 0, 0]), (1, [0, -1, 0]), (2, [0, 0, -1])] {
            let neighbor = BlockCoord { x: coord.x + delta[0], y: coord.y + delta[1], z: coord.z + delta[2] };
            let (positive, negative) = if delta[axis] > 0 { (neighbor, coord) } else { (coord, neighbor) };
            let (Some(plus), Some(minus)) = (specs.get(&positive), specs.get(&negative)) else { continue; };
            let difference = plus.lod.abs_diff(minus.lod);
            let bit = 1u32 << axis;
            if difference > 1 || (difference > 0 && plus.seam.negative_face_mask & bit == 0) {
                return false;
            }
        }
    }
    true
}

/// Reconcile seam metadata with the *planned* LOD snapshot, including new
/// streamed blocks that appeared after an earlier LOD transaction began.
/// Obsolete pending GPU meshes are invalidated, never published with stale
/// neighborhood mask data.
fn reconcile_lod_seams(
    state: &mut StreamWorld,
    commands: &mut Commands,
    meshes: &mut Assets<Mesh>,
    ready: &B3ReadySet,
) {
    if !state.mixed_lod || !state.edit_priority.is_empty() { return; }
    let levels: HashMap<_,_> = state.blocks.iter()
        .map(|(&coord, block)| (coord, state.transition_target.get(&coord)
            .map_or(block.spec.lod, |spec| spec.lod))).collect();
    let repairs: Vec<_> = state.blocks.iter().filter_map(|(&coord, block)| {
        if !block.visible { return None; }
        let proposed = state.transition_target.get(&coord).copied().unwrap_or(block.spec);
        let required = seam_info(coord, &levels);
        (proposed.seam != required).then_some((
            coord, LodSpec { seam: required, ..proposed }
        ))
    }).collect();
    if repairs.is_empty() { return; }
    for (coord, spec) in repairs.iter().copied() {
        state.transition_target.insert(coord, spec);
        if let Some(obsolete) = state.transition_pending.remove(&coord) {
            commands.entity(obsolete.block.entity).despawn();
            meshes.remove(obsolete.block.mesh.id());
            if let Ok(mut set) = ready.0.lock() {
                set.remove(&obsolete.block.mesh.id());
            }
        }
    }
    if state.b15_2_atomic_edits
        && state.b15_2_last_edit_frame.is_some_and(|f| state.frame.saturating_sub(f) <= 20)
    {
        state.b15_2_post_edit_repair_blocks += repairs.len() as u64;
    }
    info!(repair_count=repairs.len(),
        "B15.1 stale LOD seam metadata queued for coherent regeneration");
}

/// B15.2: a persisted edit invalidates GPU density over its affected chunks,
/// and an in-flight LOD transaction may have planned neighboring seams against
/// different LODs. Restore a *single published LOD snapshot* within the 3x3x3
/// seam dependency closure, cancel the conflicting in-flight LOD replacements,
/// then publish all edited/seam-repair meshes as one GPU-ready cohort.
/// This does not allocate a GPU fence or promise presentation-time completion.
fn begin_b15_2_edit_cohort(
    state: &mut StreamWorld,
    dirty: &[(BlockCoord, LodSpec)],
    world: &WorldEdits,
    commands: &mut Commands,
    meshes: &mut Assets<Mesh>,
    ready: &B3ReadySet,
) {
    if dirty.is_empty() { return; }
    let fresh_edit = dirty.iter().any(|(coord, spec)| {
        state.transition_target.get(coord)
            .is_none_or(|target| target.revision != spec.revision)
    });
    let levels: HashMap<BlockCoord, u8> = state.blocks.iter()
        .map(|(&coord, block)| (coord, block.spec.lod)).collect();
    let mut closure = HashSet::new();
    for (coord, _) in dirty {
        for dx in -1..=1 {
            for dy in -1..=1 {
                for dz in -1..=1 {
                    closure.insert(BlockCoord {
                        x: coord.x + dx,
                        y: coord.y + dy,
                        z: coord.z + dz,
                    });
                }
            }
        }
    }
    // Existing unfinished edit cohorts must not be committed separately if
    // another click updates their SDF revisions before the GPU publication.
    closure.extend(state.edit_priority.iter().copied());
    let mut coords: Vec<_> = closure.into_iter().collect();
    coords.sort_by_key(|c| (c.x, c.y, c.z));
    let mut canceled = 0u64;
    let mut repairs = 0u64;
    for coord in coords {
        let Some(active) = state.blocks.get(&coord) else { continue; };
        let desired = LodSpec {
            lod: active.spec.lod,
            seam: seam_info(coord, &levels),
            revision: world.revision(coord),
        };
        // Only invalidate an in-flight LOD mesh when this chunk actually
        // needs a new edit revision or new visible-neighbor seam. Unaffected
        // neighbors must KEEP their valid LOD transactions: eagerly
        // canceling the entire 3x3x3 neighborhood caused excessive rebuilds
        // and post-edit seam repair churn in the first B15.2 A/B.
        let queued = state.transition_target.get(&coord).copied();
        let need_new = desired != active.spec;
        let incompatible = need_new && state.transition_pending.get(&coord)
            .is_some_and(|p| p.block.spec != desired);
        let must_cancel = need_new && (incompatible
            || (queued.is_some() && queued != Some(desired)));
        if must_cancel {
            if let Some(obsolete) = state.transition_pending.remove(&coord) {
                commands.entity(obsolete.block.entity).despawn();
                meshes.remove(obsolete.block.mesh.id());
                if let Ok(mut set) = ready.0.lock() {
                    set.remove(&obsolete.block.mesh.id());
                }
                canceled += 1;
            }
            if state.transition_target.remove(&coord).is_some() { canceled += 1; }
        }
        if need_new {
            state.transition_target.insert(coord, desired);
            state.edit_priority.insert(coord);
            repairs += 1;
        } else {
            // The old surface already satisfies this frozen LOD snapshot.
            state.edit_priority.remove(&coord);
        }
    }
    if fresh_edit {
        state.b15_2_edit_transactions += 1;
        state.b15_2_last_edit_frame = Some(state.frame);
        info!(frame=state.frame, dirty=dirty.len(), cohort=repairs, canceled,
            "B15.2 edit and seam cohort queued atomically");
    }
    state.b15_2_cancelled_lod_jobs += canceled;
    if fresh_edit { state.b15_2_edit_cohort_blocks += repairs; }
}

/// B8 render-topology audit over PUBLISHED and GPU-ready blocks only.
/// A mixed visible pair must be 2:1 and have a seam owned by the
/// positive-coordinate block, or it can expose an actual raster crack.
fn audit_visible_lod_seams(blocks:&HashMap<BlockCoord,ActiveBlock>)->(usize,usize,usize){
    let mut pairs=0usize;
    let mut invalid_tier=0usize;
    let mut absent_seam=0usize;
    for (&coord,block) in blocks {
        if !block.visible{continue;}
        for (axis,(dx,dy,dz)) in [(-1,0,0),(0,-1,0),(0,0,-1)].into_iter().enumerate() {
            let other=BlockCoord{x:coord.x+dx,y:coord.y+dy,z:coord.z+dz};
            let Some(neighbor)=blocks.get(&other).filter(|b|b.visible) else{continue;};
            if block.spec.lod==neighbor.spec.lod {continue;}
            pairs+=1;
            if block.spec.lod.abs_diff(neighbor.spec.lod)>1 {invalid_tier+=1;}
            if block.spec.seam.negative_face_mask&(1<<axis)==0 {absent_seam+=1;}
        }
    }
    (pairs,invalid_tier,absent_seam)
}

fn stream_b3(
    mut commands: Commands,
    mut meshes: ResMut<Assets<Mesh>>,
    camera: Query<&Transform, With<Camera3d>>,
    mut state: ResMut<StreamWorld>,
    ready: Res<B3ReadySet>,
    mut editor: ResMut<B4EditState>,
) {
    let cpu_start = Instant::now();
    let Some(transform) = camera.iter().next() else {
        return;
    };
    let position = transform.translation;
    let pos = [position.x, position.y, position.z];
    let direction = if let Some(previous) = state.previous_position {
        let motion = position - previous;
        if motion.x.hypot(motion.z) >= 0.001 {
            [motion.x, motion.z]
        } else {
            let forward = transform.forward();
            [forward.x, forward.z]
        }
    } else {
        let forward = transform.forward();
        [forward.x, forward.z]
    };
    state.previous_position = Some(position);
    state.frame += 1;

    // A 130m ring does not need 360 degree replanning on every 16ms
    // frame. Refresh after 1.5m / 12 frames / an appreciable turn.
    // Required coverage is still audited from the CURRENT camera
    // position once per second, rather than trusting the cached plan.
    let direction2 = Vec2::new(direction[0], direction[1]).normalize_or_zero();
    let moved = (position.xz() - state.plan_position.xz()).length();
    let heading_changed = state.plan_direction.dot(direction2) < DIRECTION_COSINE_THRESHOLD;
    let should_refresh = state.baseline_scheduler
        || state.cached_plan.is_none()
        || moved >= PLAN_UPDATE_DISTANCE_M
        || state.frame.saturating_sub(state.plan_frame) >= PLAN_UPDATE_MAX_AGE_FRAMES
        || heading_changed;
    if should_refresh {
        state.cached_plan = Some(plan(pos, direction));
        state.plan_position = position;
        state.plan_direction = direction2;
        state.plan_frame = state.frame;
        state.plan_refreshes += 1;
    }

    // The readiness set is produced by the render graph after GPU dispatch.
    // Existing LOD2 meshes stay drawn until the new geometry is ready.
    if let Ok(mut dispatched) = ready.0.lock() {
        for (&coord, block) in state.blocks.iter_mut() {
            if !block.visible && dispatched.remove(&block.mesh.id()) {
                commands.entity(block.entity).insert(Visibility::Visible);
                block.visible = true;
                if let Some(start) = editor.pending_latency.remove(&coord) {
                    info!(?coord, latency_ms=start.elapsed().as_secs_f64()*1000.0,
                        "B15.1 new edited GPU chunk ready for publication");
                }
            }
        }
        for replacement in state.transition_pending.values_mut() {
            if !replacement.ready && dispatched.remove(&replacement.block.mesh.id()) {
                replacement.ready = true;
            }
        }
    }

    // Invalidate obsolete GPU work when a newer persisted edit revision arrives.
    // The currently visible mesh remains until all affected replacement blocks are ready.
    let dirty: Vec<_> = state.blocks.iter().filter_map(|(&coord, active)| {
        let revision = editor.world.revision(coord);
        (revision > active.spec.revision).then_some((coord, LodSpec {
            lod: active.spec.lod,
            seam: active.spec.seam,
            revision,
        }))
    }).collect();
    if state.b15_2_atomic_edits {
        begin_b15_2_edit_cohort(
            &mut state, &dirty, &editor.world, &mut commands, &mut meshes, &ready,
        );
    } else {
        // B15.1 comparison arm: reconstruct the affected chunk separately,
        // then defer seam reconciliation until after its publication.
        for (coord, spec) in dirty {
            state.edit_priority.insert(coord);
            if state.transition_target.get(&coord) != Some(&spec) {
                state.transition_target.insert(coord, spec);
                if let Some(obsolete) = state.transition_pending.remove(&coord) {
                    commands.entity(obsolete.block.entity).despawn();
                    meshes.remove(obsolete.block.mesh.id());
                    if let Ok(mut set) = ready.0.lock() {
                        set.remove(&obsolete.block.mesh.id());
                    }
                }
            }
        }
    }

    if state.mixed_lod && state.frame % 6 == 0 && state.edit_priority.is_empty() {
        reconcile_lod_seams(&mut state, &mut commands, &mut meshes, &ready);
    }

    if !state.transition_target.is_empty() {
        // B15.1: local edits do not wait for a 200+ block connected LOD
        // refinement cohort. Their replacements retain current LOD/seams;
        // delay unrelated LOD commits until this small edit cohort finishes.
        let critical: HashMap<_,_> = state.edit_priority.iter()
            .filter_map(|coord| state.transition_target.get(coord).map(|spec| (*coord, *spec)))
            .collect();
        let cohorts = if !critical.is_empty() {
            connected_ready_components(&critical, &state.transition_pending)
        } else {
            connected_ready_components(&state.transition_target, &state.transition_pending)
        };
        for cohort in cohorts {
            if (critical.is_empty() || state.b15_2_atomic_edits)
                && !cohort_seams_valid(
                    &cohort, &state.blocks, &state.transition_pending
                ) {
                // Neighbors may have streamed in since the transaction was
                // prepared. Hold the old valid geometry and reconcile next.
                continue;
            }
            for coord in cohort {
                let Some(mut replacement) = state.transition_pending.remove(&coord) else {
                    continue;
                };
                state.transition_target.remove(&coord);
                state.edit_priority.remove(&coord);
                if let Some(old) = state.blocks.remove(&coord) {
                    if !old.visible {
                        state.atomic_publication_errors+=1;
                        error!(?coord,"B8 LOD revision swap without visible source");
                    }
                    commands.entity(old.entity).despawn();
                    meshes.remove(old.mesh.id());
                }
                commands
                    .entity(replacement.block.entity)
                    .insert(Visibility::Visible);
                replacement.block.visible = true;
                state.blocks.insert(coord, replacement.block);
                state.transition_commits += 1;
                if let Some(start) = editor.pending_latency.remove(&coord) {
                    info!(?coord, latency_ms=start.elapsed().as_secs_f64()*1000.0, "B4 revised GPU mesh ready for publication");
                }
            }
        }
    }

    // Eviction is amortized on replanning frames, rather than scanning
    // ~800 resident mesh handles 60 times per second. The retention ring
    // is still 52 m larger than the mandatory 130 m horizon.
    if should_refresh {
        let stale: Vec<_> = state
            .blocks
            .keys()
            .copied()
            .filter(|c| !within_retention(pos, *c))
            .collect();
        for key in stale {
            if let Some(old) = state.blocks.remove(&key) {
                commands.entity(old.entity).despawn();
                meshes.remove(old.mesh.id());
                if let Ok(mut set) = ready.0.lock() {
                    set.remove(&old.mesh.id());
                }
                state.evictions += 1;
                if let Some(obsolete) = state.transition_pending.remove(&key) {
                    commands.entity(obsolete.block.entity).despawn();
                    meshes.remove(obsolete.block.mesh.id());
                }
                state.transition_target.remove(&key);
                state.edit_priority.remove(&key);
            }
        }
    }

    // Compute a stable three-tier update once the mandatory ring is
    // actually resident and no previous mixed-LOD transaction is pending.
    // Initial generation stays at welded uniform LOD2, avoiding seams
    // against unloaded/unfinished neighboring blocks.
    if state.mixed_lod
        && state.edit_priority.is_empty()
        && state.transition_target.is_empty()
        && state.frame >= 180
        && state.frame.saturating_sub(state.last_lod_epoch) >= 60
    {
        let audit = plan(pos, direction);
        let all_required_visible = audit
            .required
            .iter()
            .all(|coord| state.blocks.get(coord).is_some_and(|block| block.visible));
        if all_required_visible {
            let mut levels = HashMap::new();
            for (&coord, block) in &state.blocks {
                let distance = block_distance_xz(pos, coord);
                levels.insert(coord, next_lod(block.spec.lod, distance));
            }
            let mut desired = HashMap::new();
            for (&coord, block) in &state.blocks {
                let lod = levels[&coord];
                let spec = LodSpec {
                    lod,
                    seam: seam_info(coord, &levels),
                    revision: editor.world.revision(coord),
                };
                if block.spec != spec {
                    desired.insert(coord, spec);
                }
            }
            state.last_lod_epoch = state.frame;
            state.transition_target = desired;
        }
    }

    let material = state
        .material
        .as_ref()
        .expect("B3 material not initialized")
        .clone();
    let limit = if state.baseline_scheduler {
        BLOCKS_PER_FRAME
    } else {
        OPTIMIZED_BLOCKS_PER_FRAME
    };
    let mut new_count = 0_usize;

    // Fast lane 1: new blocks touched by an edit while the world is still
    // streaming are generated before the rest of the 130m horizon.
    let mut missing_edited: Vec<_> = editor.pending_latency.keys().copied()
        .filter(|c| !state.blocks.contains_key(c)).collect();
    missing_edited.sort_by_key(|c| (c.x, c.y, c.z));
    for coord in missing_edited {
        if new_count >= limit || state.blocks.len() >= MAX_RESIDENT_BLOCKS { break; }
        let spec = LodSpec { lod: STREAM_LOD,
            seam: initial_stream_seam(coord, &state.blocks),
            revision: editor.world.revision(coord) };
        if let Some(block) = create_block(
            &mut commands, &mut meshes, &material, coord, spec, &editor.world, true
        ) {
            state.blocks.insert(coord, block);
            new_count += 1;
            state.dispatches += 1;
        }
    }

    // Fast lane 2: existing edited chunks are rebuilt with the current
    // visible LOD and seam specification. LOD-only work stays queued.
    let mut edit_coords: Vec<_> = state.edit_priority.iter().copied().collect();
    edit_coords.sort_by_key(|c| (c.x, c.y, c.z));
    for coord in edit_coords {
        if new_count >= limit { break; }
        if state.transition_pending.contains_key(&coord) || !state.blocks.contains_key(&coord) {
            continue;
        }
        let Some(&spec) = state.transition_target.get(&coord) else { continue; };
        if let Some(block) = create_block(
            &mut commands, &mut meshes, &material, coord, spec, &editor.world, true
        ) {
            state.transition_pending.insert(coord, PendingUpgrade { block, ready: false });
            new_count += 1;
            state.dispatches += 1;
        }
    }

    // Regular streaming retains its original bounded throughput and 130m
    // horizon. Never spend its allocation quota ahead of pending edits.
    let target_count = state.cached_plan.as_ref().expect("B3 plan").targets.len();
    for index in 0..target_count {
        if new_count >= limit || state.blocks.len() >= MAX_RESIDENT_BLOCKS {
            break;
        }
        let coord = state.cached_plan.as_ref().expect("B3 plan").targets[index].coord;
        if state.blocks.contains_key(&coord) { continue; }
        let spec = LodSpec {
            lod: STREAM_LOD,
            seam: initial_stream_seam(coord, &state.blocks),
            revision: editor.world.revision(coord),
        };
        if let Some(created) = create_block(
            &mut commands, &mut meshes, &material, coord, spec, &editor.world, false
        ) {
            state.blocks.insert(coord, created);
            new_count += 1;
            state.dispatches += 1;
        } else {
            error!(?coord, "B3 block outside SDF numeric domain");
        }
    }

    // Background LOD/refinement work is disabled while an edit cohort waits
    // for GPU extraction; old visible meshes continue to be drawn.
    if state.edit_priority.is_empty() && !state.transition_target.is_empty()
        && new_count < limit {
        let mut coords: Vec<_> = state.transition_target.keys().copied().collect();
        coords.sort_by_key(|c| (c.x, c.y, c.z));
        for coord in coords {
            if new_count >= limit { break; }
            if state.transition_pending.contains_key(&coord) || !state.blocks.contains_key(&coord) {
                continue;
            }
            let spec = state.transition_target[&coord];
            if let Some(created) = create_block(
                &mut commands, &mut meshes, &material, coord, spec, &editor.world, false
            ) {
                state.transition_pending.insert(coord, PendingUpgrade {
                    block: created, ready: false,
                });
                new_count += 1;
                state.dispatches += 1;
            }
        }
    }
    // Newly streamed neighbors can invalidate previously packed seam masks.
    // Reconcile promptly; their repairs join the next atomic LOD cohort.
    if new_count > 0 && state.edit_priority.is_empty() {
        reconcile_lod_seams(&mut state, &mut commands, &mut meshes, &ready);
    }

    // Every render-update frame: a one-frame seam violation must not be
    // hidden by the one-Hz progress telemetry.
    let (visible_mixed_pairs,tier_errors,seam_ownership_errors)=
        audit_visible_lod_seams(&state.blocks);
    state.lod_audited_frames+=1;
    if tier_errors>0 || seam_ownership_errors>0 {
        state.lod_bad_frames+=1;
        if state.lod_bad_frames==1 {
            error!(tier_errors,seam_ownership_errors,
                   "B8 published mixed LOD seam topology violation");
        }
    }

        let elapsed_us = cpu_start.elapsed().as_micros().min(u32::MAX as u128) as u32;
    state.cpu_samples_us.push(elapsed_us);
    if state.frame % 60 == 0 {
        // This is deliberately a fresh plan. All reported required/missing
        // counts match the actual current position, not a cached origin.
        let audit = plan(pos, direction);
        let required = audit.required.len();
        let visible = audit
            .required
            .iter()
            .filter(|c| state.blocks.get(c).is_some_and(|b| b.visible))
            .count();
        let cpu_max_us = state.cpu_samples_us.iter().copied().max().unwrap_or(0);
        let cpu_avg_us = state.cpu_samples_us.iter().map(|x| *x as u64).sum::<u64>()
            / state.cpu_samples_us.len().max(1) as u64;
        state.cpu_samples_us.clear();
        let lod0 = state.blocks.values().filter(|b| b.spec.lod == 0).count();
        let lod1 = state.blocks.values().filter(|b| b.spec.lod == 1).count();
        let lod2 = state.blocks.values().filter(|b| b.spec.lod == 2).count();
        let seam_blocks = state
            .blocks
            .values()
            .filter(|b| b.spec.seam.negative_face_mask != 0)
            .count();
        info!(
            required,
            visible,
            missing = required - visible,
            resident = state.blocks.len(),
            scheduled = new_count,
            evictions = state.evictions,
            total_allocations = state.dispatches,
            x = position.x,
            y = position.y,
            z = position.z,
            cpu_max_us,
            cpu_avg_us,
            replans = state.plan_refreshes,
            baseline_scheduler = state.baseline_scheduler,
            mixed_lod = state.mixed_lod,
            lod0,
            lod1,
            lod2,
            seam_blocks,
            transition_pending = state.transition_pending.len(),
            transition_queued = state.transition_target.len(),
            transition_commits = state.transition_commits,
            visible_mixed_pairs,
            tier_errors,
            seam_ownership_errors,
            atomic_publication_errors=state.atomic_publication_errors,
            lod_bad_frames=state.lod_bad_frames,
            lod_audited_frames=state.lod_audited_frames,
            b15_2_atomic_edits=state.b15_2_atomic_edits,
            b15_2_edit_transactions=state.b15_2_edit_transactions,
            b15_2_cancelled_lod_jobs=state.b15_2_cancelled_lod_jobs,
            b15_2_edit_cohort_blocks=state.b15_2_edit_cohort_blocks,
            b15_2_post_edit_repair_blocks=state.b15_2_post_edit_repair_blocks,
            "B3 horizon coverage (130m, two vertical layers, GPU mesh ready)"
        );
        if required > visible {
            warn!(
                missing = required - visible,
                "B3 incomplete horizon; gate remains HOLD"
            );
        }
    }
}
