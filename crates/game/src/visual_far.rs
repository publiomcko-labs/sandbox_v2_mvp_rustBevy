//! B11 visual coverage only: a deterministic far-field SDF-height shell.
//!
//! A 130m *required* resident ring is not the camera frustum. When there is
//! nothing behind it, the user sees a hard polygonal cutoff and background
//! leaking through the terrain. This low-resolution surface extends visible
//! terrain out to 352m without changing the B3 canonical physics/edit meshes.
//! Keep the inner 112m unfilled so the shell cannot hide caves or B4 edits.
//! This is not a substitute for verifying the actual SDF topology at seams.
use bevy::{
    asset::RenderAssetUsages,
    prelude::*,
    render::render_resource::PrimitiveTopology,
};
use sandbox_world_core::density::terrain_height_half;
use std::{
    sync::{Mutex, OnceLock, mpsc::{self, Receiver, TryRecvError}},
    thread,
    time::{Instant, SystemTime, UNIX_EPOCH},
};

const SEED: u32 = 42;
const STEP_M: i32 = 8;
const OUTER_RADIUS_M: i32 = 352;
const INNER_RADIUS_M: f32 = 112.0;
const GROUND_BIAS_M: f32 = 1.25;
const CENTER_SNAP_M: f32 = 48.0;
const SWAP_DELAY_FRAMES: u8 = 8;

type FarGeometry = (Vec<[f32;3]>, Vec<[f32;3]>, Vec<[f32;2]>, Vec<u32>);

struct FarBuildTask {
    center: (i32,i32),
    receiver: Mutex<Receiver<(FarGeometry, u128)>>,
}

#[derive(Default, Resource)]
struct FarCoverage {
    center: Option<(i32,i32)>,
    active: Option<(Entity,Handle<Mesh>)>,
    pending: Option<(Entity,Handle<Mesh>,u8)>,
    build_task: Option<FarBuildTask>,
    revisions: u64,
}

fn asynchronous_far_shell_enabled() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    *ENABLED.get_or_init(|| {
        std::env::var("SANDBOX_B16_ASYNC_FAR_SHELL").as_deref() == Ok("1")
    })
}

fn start_async_geometry(center:(i32,i32))->FarBuildTask {
    let (sender,receiver)=mpsc::sync_channel(1);
    thread::spawn(move || {
        let started=Instant::now();
        let geometry=shell_geometry(center);
        let cpu_us=started.elapsed().as_micros();
        // Game may already be exiting; a detached worker must not panic.
        let _=sender.send((geometry,cpu_us));
    });
    FarBuildTask{center,receiver:Mutex::new(receiver)}
}
pub struct B11FarVisualCoveragePlugin;

impl Plugin for B11FarVisualCoveragePlugin {
    fn build(&self, app:&mut App) {
        app.init_resource::<FarCoverage>()
            .add_systems(Update, maintain_far_coverage);
    }
}
fn snapped_center(camera:Vec3)->(i32,i32){
    ((camera.x/CENTER_SNAP_M).round() as i32*CENTER_SNAP_M as i32,
     (camera.z/CENTER_SNAP_M).round() as i32*CENTER_SNAP_M as i32)
}
fn height(x:i32,z:i32)->f32 {
    terrain_height_half(SEED,x*2,z*2)-GROUND_BIAS_M
}
fn shell_geometry(center:(i32,i32))->FarGeometry{
    const SIDE: usize=(2*OUTER_RADIUS_M/STEP_M+1) as usize;
    let mut vertices=Vec::with_capacity(SIDE*SIDE);
    let mut normals=Vec::with_capacity(SIDE*SIDE);
    let mut uvs=Vec::with_capacity(SIDE*SIDE);
    let mut indices=Vec::with_capacity((SIDE-1)*(SIDE-1)*6);
    for iz in 0..SIDE {
        for ix in 0..SIDE {
            let x=center.0+(ix as i32*STEP_M)-OUTER_RADIUS_M;
            let z=center.1+(iz as i32*STEP_M)-OUTER_RADIUS_M;
            let y=height(x,z);
            vertices.push([x as f32,y,z as f32]);
            let nx=height(x-STEP_M,z)-height(x+STEP_M,z);
            let nz=height(x,z-STEP_M)-height(x,z+STEP_M);
            let normal=Vec3::new(nx,2.0*STEP_M as f32,nz).normalize_or_zero();
            normals.push(normal.to_array());
            uvs.push([x as f32/64.0,z as f32/64.0]);
        }
    }
    for iz in 0..SIDE-1 {
        for ix in 0..SIDE-1 {
            let dx=((ix as f32+0.5)*STEP_M as f32-OUTER_RADIUS_M as f32);
            let dz=((iz as f32+0.5)*STEP_M as f32-OUTER_RADIUS_M as f32);
            if dx*dx+dz*dz<INNER_RADIUS_M*INNER_RADIUS_M {
                continue;
            }
            let a=(iz*SIDE+ix) as u32;
            let b=a+1;
            let c=a+SIDE as u32;
            let d=c+1;
            // Face +Y. Keep a hole for the visible/edited near-field meshes.
            indices.extend_from_slice(&[a,c,b,b,c,d]);
        }
    }
    (vertices,normals,uvs,indices)
}
fn mesh_from_geometry(geometry:FarGeometry)->Mesh {
    let (vertices,normals,uvs,indices)=geometry;
    Mesh::new(PrimitiveTopology::TriangleList,RenderAssetUsages::default())
        .with_inserted_attribute(Mesh::ATTRIBUTE_POSITION,vertices)
        .with_inserted_attribute(Mesh::ATTRIBUTE_NORMAL,normals)
        .with_inserted_attribute(Mesh::ATTRIBUTE_UV_0,uvs)
        .with_inserted_indices(bevy::mesh::Indices::U32(indices))
}
fn maintain_far_coverage(
    mut commands:Commands,
    camera:Query<&Transform,With<Camera3d>>,
    mut state:ResMut<FarCoverage>,
    mut meshes:ResMut<Assets<Mesh>>,
    mut materials:ResMut<Assets<StandardMaterial>>,
    mut shader_material:Local<Option<Handle<StandardMaterial>>>,
    time:Res<Time>,
) {
    let Some(camera)=camera.iter().next() else{return;};
    let correlated = std::env::var("SANDBOX_B15_4_CORRELATE").as_deref() == Ok("1");
    if shader_material.is_none() {
        *shader_material=Some(materials.add(StandardMaterial{
            base_color:Color::srgb(0.34,0.59,0.37),
            perceptual_roughness:0.9,
            cull_mode:None,
            ..default()
        }));
    }
    if let Some((entity,_,age))=&mut state.pending {
        if *age>0 {
            *age-=1;
        } else {
            let entity=*entity;
            if let Some((old,old_mesh))=state.active.take(){
                commands.entity(old).despawn();
                meshes.remove(old_mesh.id());
            }
            if let Some((current,new_mesh,_))=state.pending.take(){
                commands.entity(current).insert(Transform::IDENTITY);
                state.active=Some((current,new_mesh));
                if correlated {
                    let unix_ms = SystemTime::now().duration_since(UNIX_EPOCH)
                        .map(|d| d.as_millis()).unwrap_or(0);
                    info!(unix_ms,game_t_s=time.elapsed_secs(),revisions=state.revisions,
                        "B15.4 far shell swap published to MainWorld");
                }
            } else {
                debug!(?entity,"B11 distant terrain swap already completed");
            }
        }
    }
    let snapped=snapped_center(camera.translation);
    if state.pending.is_some() { return; }
    let asynchronous = asynchronous_far_shell_enabled();
    let mut worker_compute_us = None;
    let mut completed_geometry = None;

    if asynchronous {
        if let Some(task) = state.build_task.as_ref() {
            let finished = match task.receiver.lock() {
                Ok(receiver) => receiver.try_recv(),
                Err(_) => Err(TryRecvError::Disconnected),
            };
            match finished {
                Ok((geometry, compute_us)) => {
                    let finished_center = task.center;
                    state.build_task.take();
                    if finished_center == snapped {
                        completed_geometry=Some(geometry);
                        worker_compute_us=Some(compute_us);
                    } else {
                        // Camera changed during computation: never publish
                        // stale coverage. Keep the old shell while rebuilding.
                        info!(built_x=finished_center.0,built_z=finished_center.1,
                            target_x=snapped.0,target_z=snapped.1,
                            "B16 discarded stale far shell worker result");
                    }
                },
                Err(TryRecvError::Empty) => return,
                Err(TryRecvError::Disconnected) => {
                    state.build_task.take();
                    warn!("B16 far shell worker disconnected; retaining prior shell and retrying");
                }
            }
        }
    }
    if state.center==Some(snapped) && completed_geometry.is_none() {
        return;
    }
    if asynchronous && state.active.is_some() && completed_geometry.is_none() {
        // Initial coverage stays synchronous, but subsequent expensive CPU
        // geometry generation is off the frame's main thread. Only one
        // worker is active at a time; the old mesh remains drawable.
        state.build_task=Some(start_async_geometry(snapped));
        info!(center_x=snapped.0,center_z=snapped.1,
            "B16 async far shell generation scheduled");
        return;
    }

    let build_started = Instant::now();
    let geometry = completed_geometry.unwrap_or_else(||shell_geometry(snapped));
    let mesh=meshes.add(mesh_from_geometry(geometry));
    let build_us = build_started.elapsed().as_micros();
    if let Some(compute_us)=worker_compute_us {
        info!(center_x=snapped.0,center_z=snapped.1,
            worker_compute_us=compute_us, main_publish_us=build_us,
            "B16 far shell async geometry produced");
    }
    let entity=commands.spawn((
        Mesh3d(mesh.clone()),
        MeshMaterial3d(shader_material.as_ref().unwrap().clone()),
        // During the overlap interval, the old mesh stays slightly above
        // the new one so there are no coplanar z-fighting artifacts.
        Transform::from_xyz(0.0,-0.08,0.0),
        Name::new("B11 deterministic distant terrain visual coverage"),
    )).id();
    state.pending=Some((entity,mesh,SWAP_DELAY_FRAMES));
    state.center=Some(snapped);
    state.revisions+=1;
    if correlated {
        let unix_ms = SystemTime::now().duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis()).unwrap_or(0);
        info!(center_x=snapped.0,center_z=snapped.1,
              inner_m=INNER_RADIUS_M,outer_m=OUTER_RADIUS_M,
              revisions=state.revisions,build_us,unix_ms,
              game_t_s=time.elapsed_secs(),"B11 far field coverage built");
    } else {
        info!(center_x=snapped.0,center_z=snapped.1,
              inner_m=INNER_RADIUS_M,outer_m=OUTER_RADIUS_M,
              revisions=state.revisions,"B11 far field coverage built");
    }
}

#[cfg(test)]
mod tests{
    use super::*;
    #[test]
    fn shell_outside_inner_hole_and_centers_cover_all_axes(){
        let (_,_,_,indices)=shell_geometry((0,0));
        assert!(!indices.is_empty());
        const SIDE: usize=(2*OUTER_RADIUS_M/STEP_M+1) as usize;
        assert_eq!(SIDE,89);
        for tri in indices.chunks_exact(3){
            let center=tri.iter().map(|i|{
                let ix=(*i as usize % SIDE) as i32;
                let iz=(*i as usize / SIDE) as i32;
                Vec2::new((ix*STEP_M-OUTER_RADIUS_M) as f32,
                          (iz*STEP_M-OUTER_RADIUS_M) as f32)
            }).fold(Vec2::ZERO,|a,b|a+b)/3.0;
            assert!(center.length()>INNER_RADIUS_M-STEP_M as f32);
        }
        assert_eq!(snapped_center(Vec3::new(-59.0,0.0,49.0)),(-48,48));
    }
}
