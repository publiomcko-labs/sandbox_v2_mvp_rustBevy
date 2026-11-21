//! B2: GPU-resident density -> Surface Nets -> Bevy MeshAllocator.
//! Vertex/index storage is written on the GPU and drawn by the normal Bevy
//! mesh pipeline without copying triangles back to CPU.
//!
//! B2 intentionally fixes capacity per block. Empty edge slots become
//! degenerate triangles. B3 will add compaction, indirect drawing and
//! mixed-LOD transitions before streaming is enabled. Same-LOD seams
//! use one negative cell of SDF halo for vertex replication.

pub mod b3;

use bevy::{
    asset::RenderAssetUsages,
    camera::{RenderTarget, visibility::NoFrustumCulling},
    core_pipeline::schedule::camera_driver,
    mesh::Indices,
    platform::collections::HashMap,
    prelude::*,
    render::{
        Render, RenderApp, RenderStartup,
        extract_component::{ExtractComponent, ExtractComponentPlugin},
        mesh::allocator::{MeshAllocator, MeshAllocatorSettings},
        render_resource::{
            binding_types::{storage_buffer, storage_buffer_read_only, uniform_buffer},
            *,
        },
        renderer::{RenderContext, RenderGraph, RenderQueue},
    },
};
use sandbox_world_core::{BlockCoord, density::DensityGrid, edits::{Brush, EditMode, MAX_GPU_BRUSHES_PER_BLOCK}};
use std::collections::HashSet;

const SEED: u32 = 42;
const DENSITY_SHADER: &str = "shaders/sdf_density_b4.wgsl";
const EXTRACT_SHADER: &str = "shaders/surface_nets.wgsl";
const TRANSITION_SHADER: &str = "shaders/lod_transition.wgsl";
const SEAM_EDGES_PER_FACE: usize = 2 * 32 * 32;
const FLOATS_PER_VERTEX: u32 = 8;
const INDICES_PER_CELL: u32 = 18;

pub struct GpuTerrainB2Plugin;

impl Plugin for GpuTerrainB2Plugin {
    fn build(&self, app: &mut App) {
        app.add_plugins(ExtractComponentPlugin::<BuildSdfMesh>::default());
        app.add_systems(Startup, setup_b2_scene);
        let Some(render_app) = app.get_sub_app_mut(RenderApp) else {
            return;
        };
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
        // A Bevy mesh slab is the destination of GPU extraction, never a CPU
        // mesh readback buffer. This must be configured before mesh allocation.
        render_app
            .world_mut()
            .resource_mut::<MeshAllocatorSettings>()
            .extra_buffer_usages = BufferUsages::STORAGE;
    }
}

#[derive(Component, ExtractComponent, Clone)]
#[extract_app(RenderApp)]
struct BuildSdfMesh {
    handle: Handle<Mesh>,
    grid: DensityGrid,
    seed: u32,
    seam_mask: u32,
    neighbor_lod_words: [u32; 2],
    brushes: Vec<Brush>,
}

fn b2_counts(grid: DensityGrid) -> (usize, usize) {
    let cells = grid.cells * grid.cells * grid.cells;
    // One negative halo cell along each axis. The extra cells are
    // referenced by quads owned at each block's low border.
    ((grid.cells + 1).pow(3), cells * INDICES_PER_CELL as usize)
}

fn b3_mixed_counts(grid: DensityGrid, seam_mask: u32) -> (usize, usize) {
    let (vertices, indices) = b2_counts(grid);
    let faces = (seam_mask & 0b111).count_ones() as usize;
    (
        vertices + faces * SEAM_EDGES_PER_FACE * 4,
        indices + faces * SEAM_EDGES_PER_FACE * 6,
    )
}

fn setup_b2_scene(
    mut commands: Commands,
    mut meshes: ResMut<Assets<Mesh>>,
    mut materials: ResMut<Assets<StandardMaterial>>,
    mut images: ResMut<Assets<Image>>,
) {
    // Only a static demonstration patch: streaming, edge stitching and LOD
    // transitions are B3. All visual vertex/index contents come from compute.
    let lod = std::env::var("SANDBOX_B2_LOD")
        .ok()
        .and_then(|s| s.parse::<u8>().ok())
        .filter(|lod| *lod <= 2)
        .unwrap_or(1);
    let cave_scene = std::env::var("SANDBOX_B2_SCENE").as_deref() == Ok("cave");

    let material = materials.add(StandardMaterial {
        base_color: Color::srgb(0.34, 0.59, 0.37),
        perceptual_roughness: 0.9,
        cull_mode: None,
        ..default()
    });

    // Two vertical layers preserve both the surface and the cave at y~-7.
    // Blocks share their density samples; seam triangulation awaits B3.
    for by in [-1, 0] {
        for bz in [-1, 0] {
            for bx in [-1, 0] {
                let coord = BlockCoord {
                    x: bx,
                    y: by,
                    z: bz,
                };
                let grid = DensityGrid::new(coord, lod)
                    .expect("B2 static demo block is inside GPU integer domain");
                let (vertices, indices) = b2_counts(grid);
                let mut mesh = Mesh::new(
                    PrimitiveTopology::TriangleList,
                    RenderAssetUsages::RENDER_WORLD,
                )
                .with_inserted_attribute(Mesh::ATTRIBUTE_POSITION, vec![[0.0_f32; 3]; vertices])
                .with_inserted_attribute(Mesh::ATTRIBUTE_NORMAL, vec![[0.0_f32; 3]; vertices])
                .with_inserted_attribute(Mesh::ATTRIBUTE_UV_0, vec![[0.0_f32; 2]; vertices])
                .with_inserted_indices(Indices::U32(vec![0_u32; indices]));
                mesh.asset_usage = RenderAssetUsages::RENDER_WORLD;
                let handle = meshes.add(mesh);
                commands.spawn((
                    BuildSdfMesh {
                        handle: handle.clone(),
                        grid,
                        seed: SEED,
                        seam_mask: 0,
                        neighbor_lod_words: [0; 2],
                        brushes: Vec::new(),
                    },
                    Mesh3d(handle),
                    MeshMaterial3d(material.clone()),
                    // AABB computed from zero-valued placeholder vertices
                    // is NOT the actual eventual GPU surface bounds.
                    NoFrustumCulling,
                    Transform::from_xyz(bx as f32 * 16.0, by as f32 * 16.0, bz as f32 * 16.0),
                ));
            }
        }
    }

    commands.spawn((
        DirectionalLight {
            illuminance: 12_000.0,
            shadow_maps_enabled: false,
            ..default()
        },
        Transform::from_rotation(Quat::from_euler(EulerRot::XYZ, -0.8, 0.6, 0.0)),
    ));
    let camera_transform = if cave_scene {
        Transform::from_xyz(7.0, -7.0, -6.0).looking_at(Vec3::new(-12.0, -7.0, -6.0), Vec3::Y)
    } else {
        Transform::from_xyz(-27.0, 20.0, 34.0).looking_at(Vec3::new(-7.0, 2.0, -7.0), Vec3::Y)
    };
    if std::env::var("SANDBOX_B2_HEADLESS").as_deref() == Ok("1") {
        let mut image = Image::new_target_texture(1280, 720, TextureFormat::Rgba8UnormSrgb, None);
        image.asset_usage = RenderAssetUsages::RENDER_WORLD;
        let target = images.add(image);
        commands.insert_resource(B2HeadlessTarget(target.clone()));
        commands.spawn((
            Camera3d::default(),
            RenderTarget::Image(target.into()),
            camera_transform,
        ));
        info!("B2 headless GPU image target created (1280x720, no Windows desktop required)");
    } else {
        commands.spawn((Camera3d::default(), camera_transform));
    }
    info!("B2 static GPU terrain initialized (8 blocks, LOD {lod}, seed {SEED})");
}

/// Target texture retained in MainWorld for the screenshot capture system.
#[derive(Resource)]
pub struct B2HeadlessTarget(pub Handle<Image>);

#[derive(Resource, Default)]
struct PendingB2(Vec<BuildSdfMesh>);

/// Density buffers allocated once per block and retained, like the Bevy mesh
/// slabs. No density, vertex or triangle readback occurs in the runtime path.
#[derive(Resource, Default)]
struct B2ResidentBuffers(HashMap<AssetId<Mesh>, Buffer>);

#[derive(Resource)]
struct B2Pipelines {
    density_layout: BindGroupLayoutDescriptor,
    surface_layout: BindGroupLayoutDescriptor,
    density: CachedComputePipelineId,
    vertices: CachedComputePipelineId,
    indices: CachedComputePipelineId,
    transition: CachedComputePipelineId,
}

#[derive(ShaderType, Clone, Copy)]
struct B2Params {
    // Must be identical to the first eight words of the B1 WGSL parameters.
    base_x: i32,
    base_y: i32,
    base_z: i32,
    seed: u32,
    step_half: i32,
    dimension: u32,
    count: u32,
    reserved: u32,
    // MeshAllocator range addresses. Vertex addresses are float offsets.
    vertex_start: u32,
    vertex_end: u32,
    index_start: u32,
    index_end: u32,
    cells: u32,
    padding0: u32,
    padding1: u32,
    padding2: u32,
}

fn init_b2_pipelines(mut commands: Commands, assets: Res<AssetServer>, cache: Res<PipelineCache>) {
    let density_layout = BindGroupLayoutDescriptor::new(
        "B2 density layout",
        &BindGroupLayoutEntries::sequential(
            ShaderStages::COMPUTE,
            (
                uniform_buffer::<B2Params>(false),
                storage_buffer::<Vec<f32>>(false),
                storage_buffer_read_only::<Vec<i32>>(false),
            ),
        ),
    );
    let surface_layout = BindGroupLayoutDescriptor::new(
        "B2 Surface Nets layout",
        &BindGroupLayoutEntries::sequential(
            ShaderStages::COMPUTE,
            (
                uniform_buffer::<B2Params>(false),
                // WGSL binding 1 is var<storage, read>. The bool in
                // storage_buffer means *dynamic offset*, not read_only.
                storage_buffer_read_only::<Vec<f32>>(false),
                storage_buffer::<Vec<f32>>(false),
                storage_buffer::<Vec<u32>>(false),
            ),
        ),
    );
    let density_shader = assets.load(DENSITY_SHADER);
    let extract_shader = assets.load(EXTRACT_SHADER);
    let transition_shader = assets.load(TRANSITION_SHADER);
    let density = cache.queue_compute_pipeline(ComputePipelineDescriptor {
        label: Some("B2 density compute".into()),
        layout: vec![density_layout.clone()],
        shader: density_shader,
        ..default()
    });
    let vertices = cache.queue_compute_pipeline(ComputePipelineDescriptor {
        label: Some("B2 Surface Nets vertices".into()),
        layout: vec![surface_layout.clone()],
        shader: extract_shader.clone(),
        entry_point: Some("emit_vertices".into()),
        ..default()
    });
    let indices = cache.queue_compute_pipeline(ComputePipelineDescriptor {
        label: Some("B2 Surface Nets indices".into()),
        layout: vec![surface_layout.clone()],
        shader: extract_shader,
        entry_point: Some("emit_indices".into()),
        ..default()
    });
    let transition = cache.queue_compute_pipeline(ComputePipelineDescriptor {
        label: Some("B3 2:1 adaptive dual seam GPU".into()),
        layout: vec![surface_layout.clone()],
        shader: transition_shader,
        entry_point: Some("emit_transition".into()),
        ..default()
    });
    commands.insert_resource(B2Pipelines {
        density_layout,
        surface_layout,
        density,
        vertices,
        indices,
        transition,
    });
}

fn prepare_b2(
    commands: Query<&BuildSdfMesh>,
    mut pending: ResMut<PendingB2>,
    mut resident: ResMut<B2ResidentBuffers>,
    cache: Res<PipelineCache>,
    pipelines: Res<B2Pipelines>,
    b3_ready: Option<Res<b3::B3ReadySet>>,
    mut frame: Local<u64>,
) {
    if cache.get_compute_pipeline(pipelines.density).is_none()
        || cache.get_compute_pipeline(pipelines.vertices).is_none()
        || cache.get_compute_pipeline(pipelines.indices).is_none()
        || cache.get_compute_pipeline(pipelines.transition).is_none()
    {
        pending.0.clear();
        return;
    }
    *frame += 1;
    // The B2 static stage retains its original eager reclamation.
    // The B3 streaming stage amortizes the O(resident meshes) HashSet
    // and retain pass: a stale density buffer is kept at most 15 frames
    // after mesh eviction, never indefinitely.
    if b3_ready.is_none() || *frame % 16 == 0 {
        let active: HashSet<_> = commands.iter().map(|job| job.handle.id()).collect();
        resident.0.retain(|mesh_id, _| active.contains(mesh_id));
    }
    pending.0.clear();
    let quota = if b3_ready.is_some() { 5 } else { usize::MAX };
    pending.0.extend(
        commands
            .iter()
            .filter(|job| !resident.0.contains_key(&job.handle.id()))
            .take(quota)
            .cloned(),
    );
}

fn compute_b2(
    mut context: RenderContext,
    pending: Res<PendingB2>,
    mut resident: ResMut<B2ResidentBuffers>,
    allocator: Res<MeshAllocator>,
    cache: Res<PipelineCache>,
    pipelines: Res<B2Pipelines>,
    queue: Res<RenderQueue>,
    b3_ready: Option<Res<b3::B3ReadySet>>,
) {
    let (
        Some(density_pipeline),
        Some(vertices_pipeline),
        Some(indices_pipeline),
        Some(transition_pipeline),
    ) = (
        cache.get_compute_pipeline(pipelines.density),
        cache.get_compute_pipeline(pipelines.vertices),
        cache.get_compute_pipeline(pipelines.indices),
        cache.get_compute_pipeline(pipelines.transition),
    )
    else {
        return;
    };

    for job in &pending.0 {
        let id = job.handle.id();
        if resident.0.contains_key(&id) {
            continue;
        }
        let (Some(vslice), Some(islice)) = (
            allocator.mesh_vertex_slice(&id),
            allocator.mesh_index_slice(&id),
        ) else {
            // GPU buffers not uploaded yet; retry next render frame.
            continue;
        };
        let cells = job.grid.cells as u32;
        let vertex_count = (cells + 1).pow(3);
        let cell_count = cells.pow(3);
        let index_count = cell_count * INDICES_PER_CELL;
        let vertex_start = vslice.range.start * FLOATS_PER_VERTEX;
        let vertex_end = vslice.range.end * FLOATS_PER_VERTEX;
        let index_start = islice.range.start;
        let index_end = islice.range.end;
        if vertex_end - vertex_start < vertex_count * FLOATS_PER_VERTEX
            || index_end - index_start < index_count
        {
            error!(?id, "B2 mesh slab capacity too small; refusing overflow");
            continue;
        }

        if job.brushes.len() > MAX_GPU_BRUSHES_PER_BLOCK {
            error!(?id, "B4 brush overflow rejected (no silent terrain truncation)");
            continue;
        }
        let mut brush_bytes = Vec::with_capacity(job.brushes.len().max(1) * 32);
        for brush in &job.brushes {
            for value in [
                brush.center_half[0],
                brush.center_half[1],
                brush.center_half[2],
                brush.radius_half,
                if brush.mode == EditMode::Add { 0 } else { 1 },
                0, 0, 0,
            ] {
                brush_bytes.extend_from_slice(&value.to_le_bytes());
            }
        }
        if brush_bytes.is_empty() {
            brush_bytes.resize(32, 0);
        }
        let edits_buffer = context.render_device().create_buffer(&BufferDescriptor {
            label: Some("B4 immutable block brush records"),
            size: brush_bytes.len() as u64,
            usage: BufferUsages::STORAGE | BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        queue.write_buffer(&edits_buffer, 0, &brush_bytes);
        let words = job.grid.uniform_words(job.seed);
        let params = B2Params {
            base_x: words[0] as i32,
            base_y: words[1] as i32,
            base_z: words[2] as i32,
            seed: job.seed,
            step_half: job.grid.step_half,
            dimension: job.grid.dim as u32,
            count: job.grid.len() as u32,
            reserved: job.seam_mask,
            vertex_start,
            vertex_end,
            index_start,
            index_end,
            cells,
            padding0: job.brushes.len() as u32,
            padding1: job.neighbor_lod_words[0],
            padding2: job.neighbor_lod_words[1],
        };
        let density_buffer = context.render_device().create_buffer(&BufferDescriptor {
            label: Some("B2 resident SDF density samples"),
            size: job.grid.len() as u64 * 4,
            usage: BufferUsages::STORAGE,
            mapped_at_creation: false,
        });
        let mut uniform = UniformBuffer::from(params);
        uniform.write_buffer(context.render_device(), &queue);

        let density_group = context.render_device().create_bind_group(
            None,
            &cache.get_bind_group_layout(&pipelines.density_layout),
            &BindGroupEntries::sequential((
                &uniform,
                density_buffer.as_entire_buffer_binding(),
                edits_buffer.as_entire_buffer_binding(),
            )),
        );
        let surface_group = context.render_device().create_bind_group(
            None,
            &cache.get_bind_group_layout(&pipelines.surface_layout),
            &BindGroupEntries::sequential((
                &uniform,
                density_buffer.as_entire_buffer_binding(),
                vslice.buffer.as_entire_buffer_binding(),
                islice.buffer.as_entire_buffer_binding(),
            )),
        );

        {
            let mut pass = context
                .command_encoder()
                .begin_compute_pass(&ComputePassDescriptor {
                    label: Some("B2 density dispatch"),
                    ..default()
                });
            pass.set_pipeline(density_pipeline);
            pass.set_bind_group(0, &density_group, &[]);
            pass.dispatch_workgroups((job.grid.len() as u32).div_ceil(64), 1, 1);
        }
        {
            let mut pass = context
                .command_encoder()
                .begin_compute_pass(&ComputePassDescriptor {
                    label: Some("B2 vertices dispatch"),
                    ..default()
                });
            pass.set_pipeline(vertices_pipeline);
            pass.set_bind_group(0, &surface_group, &[]);
            pass.dispatch_workgroups(vertex_count.div_ceil(64), 1, 1);
        }
        {
            let mut pass = context
                .command_encoder()
                .begin_compute_pass(&ComputePassDescriptor {
                    label: Some("B2 indices dispatch"),
                    ..default()
                });
            pass.set_pipeline(indices_pipeline);
            pass.set_bind_group(0, &surface_group, &[]);
            pass.dispatch_workgroups((3 * cell_count).div_ceil(64), 1, 1);
        }
        if job.seam_mask & 0b111 != 0 {
            let mut pass = context
                .command_encoder()
                .begin_compute_pass(&ComputePassDescriptor {
                    label: Some("B3 adaptive LOD transition dispatch"),
                    ..default()
                });
            pass.set_pipeline(transition_pipeline);
            pass.set_bind_group(0, &surface_group, &[]);
            pass.dispatch_workgroups((3 * SEAM_EDGES_PER_FACE as u32).div_ceil(64), 1, 1);
        }
        // The render graph executes these stages before the camera draw.
        // Preserve each buffer for the lifetime of the mesh; no per-frame
        // uploads or runtime readback.
        resident.0.insert(id, density_buffer);
        if let Some(ref signal) = b3_ready {
            // The draw command uses this mesh only from a future frame
            // after these three compute dispatches have been submitted.
            if let Ok(mut set) = signal.0.lock() {
                set.insert(id);
            }
        }
        info!(?id, ?job.grid.coord, lod = job.grid.lod,
            vertices = vertex_count, index_slots = index_count,
            "B2 GPU density/extraction dispatched");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixed_capacity_matches_lod_and_bounds() {
        for lod in 0..=2 {
            let g = DensityGrid::new(BlockCoord { x: 0, y: -1, z: -1 }, lod).unwrap();
            let (vertices, indices) = b2_counts(g);
            assert_eq!(vertices, (g.cells + 1).pow(3));
            assert_eq!(indices, g.cells.pow(3) * 18);
            assert!(indices <= u32::MAX as usize);
            for mask in 0..8 {
                let (v, i) = b3_mixed_counts(g, mask);
                let faces = mask.count_ones() as usize;
                assert_eq!(v, vertices + faces * SEAM_EDGES_PER_FACE * 4);
                assert_eq!(i, indices + faces * SEAM_EDGES_PER_FACE * 6);
            }
        }
    }
}
