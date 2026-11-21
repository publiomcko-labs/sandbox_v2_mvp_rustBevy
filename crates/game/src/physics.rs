//! B5 baseline mechanics: deterministic rock streaming, local SDF colliders,
//! Avian dynamic rigid bodies, basic ocean buoyancy and persistent rock state.
//! All numerical/visual performance gates remain independent and unqualified.
use avian3d::prelude::*;
use bevy::prelude::*;
use sandbox_gpu_terrain::b2::b3::B4EditState;
use sandbox_world_core::{
    BlockCoord,
    density::{density_half, hash2, terrain_height_half},
};
use std::{collections::{HashMap, HashSet}, fs, path::PathBuf};

const SEED: u32 = 42;
const ROCK_RADIUS: f32 = 0.45;
const WATER_Y: f32 = 0.0;
const ROCK_DENSITY: f32 = 2650.0;
const WATER_DENSITY: f32 = 1000.0;
const COLLIDER_CELL_M: i32 = 4;
const COLLIDER_RADIUS_M: f32 = 24.0;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Component)]
struct RockId { x: i32, z: i32 }

#[derive(Clone, Copy)]
struct Snapshot { position: Vec3, velocity: Vec3 }

#[derive(Resource, Default)]
struct RockWorld {
    entities: HashMap<RockId, Entity>,
    states: HashMap<RockId, Snapshot>,
    last_center: Option<(i32, i32)>,
    mesh: Option<Handle<Mesh>>,
    material: Option<Handle<StandardMaterial>>,
    water_entity: Option<Entity>,
    save_path: PathBuf,
    last_save_s: f32,
}

#[derive(Resource, Default)]
struct TerrainColliders {
    cells: HashMap<(i32, i32, i32), (Entity, u64)>,
}

pub struct MvpPhysicsPlugin;

impl Plugin for MvpPhysicsPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<RockWorld>()
            .init_resource::<TerrainColliders>()
            .add_systems(Startup, setup_rocks_water)
            .add_systems(Update, (stream_rocks, maintain_terrain_colliders, save_rock_states))
            .add_systems(FixedUpdate, buoyancy_for_rocks);
    }
}

fn default_rock_position(id: RockId) -> Vec3 {
    let x = id.x as f32 * 8.0 + 4.0;
    let z = id.z as f32 * 8.0 + 4.0;
    let h = terrain_height_half(SEED, (x * 2.0) as i32, (z * 2.0) as i32);
    Vec3::new(x, h + ROCK_RADIUS + 0.5, z)
}

fn read_rock_states(path: &PathBuf) -> Result<HashMap<RockId, Snapshot>, String> {
    let data = match fs::read_to_string(path) {
        Ok(data) => data,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(HashMap::new()),
        Err(error) => return Err(error.to_string()),
    };
    if data.len() > 2 * 1024 * 1024 { return Err("B5 saved state too large".into()); }
    let mut lines = data.lines();
    if lines.next() != Some("RB5 1") { return Err("B5 incompatible saved state".into()); }
    let mut result = HashMap::new();
    for line in lines {
        let parts: Vec<_> = line.split_ascii_whitespace().collect();
        if parts.len() != 8 { return Err("B5 malformed rock record".into()); }
        let x = parts[0].parse::<i32>().map_err(|_| "B5 invalid X")?;
        let z = parts[1].parse::<i32>().map_err(|_| "B5 invalid Z")?;
        let mut value = [0.0_f32; 6];
        for (dest, input) in value.iter_mut().zip(&parts[2..]) {
            *dest = input.parse::<f32>().map_err(|_| "B5 invalid float")?;
            if !dest.is_finite() { return Err("B5 non-finite rock state".into()); }
        }
        let id = RockId {x,z};
        if result.insert(id, Snapshot {
            position: Vec3::new(value[0],value[1],value[2]),
            velocity: Vec3::new(value[3],value[4],value[5]),
        }).is_some() {
            return Err("B5 duplicate rock ID".into());
        }
    }
    Ok(result)
}

fn write_rock_states(path: &PathBuf, states: &HashMap<RockId, Snapshot>) -> std::io::Result<()> {
    let mut keys: Vec<_> = states.keys().copied().collect();
    keys.sort_by_key(|id| (id.x, id.z));
    let mut text = String::from("RB5 1\n");
    for id in keys {
        let state = states[&id];
        text.push_str(&format!(
            "{} {} {} {} {} {} {} {}\n",
            id.x, id.z,
            state.position.x, state.position.y, state.position.z,
            state.velocity.x, state.velocity.y, state.velocity.z,
        ));
    }
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() { fs::create_dir_all(parent)?; }
    }
    let temp = path.with_extension("b5tmp");
    fs::write(&temp, text)?;
    fs::rename(temp, path)
}

fn setup_rocks_water(
    mut commands: Commands,
    mut meshes: ResMut<Assets<Mesh>>,
    mut materials: ResMut<Assets<StandardMaterial>>,
    mut rocks: ResMut<RockWorld>,
) {
    rocks.save_path = std::env::var_os("SANDBOX_B5_SAVE_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("world-b5-rocks.txt"));
    match read_rock_states(&rocks.save_path) {
        Ok(states) => { info!(restored=states.len(), "B5 persistent rocks loaded"); rocks.states = states; },
        Err(error) => error!(%error, "B5 invalid rock save; refusing to overwrite until fixed"),
    }
    rocks.mesh = Some(meshes.add(Cuboid::new(0.8, 0.7, 0.9)));
    rocks.material = Some(materials.add(StandardMaterial {
        base_color: Color::srgb(0.42, 0.38, 0.32),
        perceptual_roughness: 0.88,
        ..default()
    }));
    let water_mesh = meshes.add(Plane3d::default().mesh().size(370.0, 370.0));
    let water_material = materials.add(StandardMaterial {
        base_color: Color::srgba(0.10, 0.31, 0.58, 0.62),
        alpha_mode: AlphaMode::Blend,
        perceptual_roughness: 0.24,
        cull_mode: None,
        ..default()
    });
    rocks.water_entity = Some(commands.spawn((
        Mesh3d(water_mesh),
        MeshMaterial3d(water_material),
        Transform::from_xyz(0.0, WATER_Y, 0.0),
        Name::new("B5 ocean, y=0"),
    )).id());
}

fn stream_rocks(
    mut commands: Commands,
    time: Res<Time>,
    camera: Query<&Transform, With<Camera3d>>,
    scene_rocks: Query<(Entity, &RockId, &Transform, Option<&RigidBody>, Option<&LinearVelocity>)>,
    mut rocks: ResMut<RockWorld>,
) {
    let Some(view) = camera.iter().next() else { return; };
    let pos = view.translation;
    if let Some(water) = rocks.water_entity {
        commands.entity(water).insert(Transform::from_xyz(pos.x, WATER_Y, pos.z));
    }
    for (entity,id,transform,body,velocity) in &scene_rocks {
        let horizontal = Vec2::new(pos.x-transform.translation.x, pos.z-transform.translation.z).length();
        if body.is_none() && horizontal <= 28.0 {
            commands.entity(entity).insert((
                RigidBody::Dynamic,
                Collider::sphere(ROCK_RADIUS),
                Friction::new(0.8),
                Restitution::new(0.05),
                LinearVelocity(rocks.states.get(id).map_or(Vec3::ZERO, |s| s.velocity)),
            ));
        } else if body.is_some() && horizontal > 36.0
            && velocity.is_none_or(|v| v.0.length() < 0.1)
        {
            commands.entity(entity)
                .remove::<RigidBody>()
                .remove::<Collider>()
                .remove::<LinearVelocity>();
        }
        if horizontal > 182.0 {
            rocks.states.insert(*id, Snapshot {
                position: transform.translation,
                velocity: velocity.map_or(Vec3::ZERO, |v| v.0),
            });
            rocks.entities.remove(id);
            commands.entity(entity).despawn();
        }
    }
    let grid_center = ((pos.x / 8.0).floor() as i32, (pos.z / 8.0).floor() as i32);
    if rocks.last_center == Some(grid_center) { return; }
    rocks.last_center = Some(grid_center);
    let mesh = rocks.mesh.as_ref().expect("B5 rock mesh").clone();
    let material = rocks.material.as_ref().expect("B5 rock material").clone();
    let mut new_count = 0usize;
    for gz in grid_center.1 - 18..=grid_center.1 + 18 {
        for gx in grid_center.0 - 18..=grid_center.0 + 18 {
            let id = RockId{x:gx,z:gz};
            if hash2(SEED ^ 0xcafe_babe, gx, gz) % 5 == 0 { continue; }
            let default_pos = default_rock_position(id);
            if Vec2::new(default_pos.x-pos.x, default_pos.z-pos.z).length() > 130.0 { continue; }
            if rocks.entities.contains_key(&id) { continue; }
            let transform = rocks.states.get(&id).map_or(default_pos, |saved| saved.position);
            let entity=commands.spawn((
                Mesh3d(mesh.clone()),
                MeshMaterial3d(material.clone()),
                Transform::from_translation(transform),
                id,
            )).id();
            rocks.entities.insert(id,entity);
            new_count += 1;
        }
    }
    if time.elapsed_secs() > 0.0 {
        info!(new_rocks=new_count, resident_rocks=rocks.entities.len(), "B5 130m deterministic rock visual streaming");
    }
}

fn maintain_terrain_colliders(
    mut commands: Commands,
    camera: Query<&Transform, With<Camera3d>>,
    editor: Option<Res<B4EditState>>,
    mut state: ResMut<TerrainColliders>,
) {
    let Some(cam) = camera.iter().next() else { return; };
    let x=(cam.translation.x / COLLIDER_CELL_M as f32).floor() as i32;
    let z=(cam.translation.z / COLLIDER_CELL_M as f32).floor() as i32;
    let mut required=HashSet::new();
    for gz in z-6..=z+6 {
        for gx in x-6..=x+6 {
            let px=gx*COLLIDER_CELL_M+COLLIDER_CELL_M/2;
            let pz=gz*COLLIDER_CELL_M+COLLIDER_CELL_M/2;
            if Vec2::new(px as f32-cam.translation.x,pz as f32-cam.translation.z).length()>COLLIDER_RADIUS_M { continue; }
            for gy in -5..=4 {
                let py=gy*COLLIDER_CELL_M+COLLIDER_CELL_M/2;
                let coord=BlockCoord::from_meter_grid(px as i64, py as i64, pz as i64);
                let revision=editor.as_ref().map_or(0, |ed| ed.world.revision(coord));
                let key=(gx,gy,gz);
                let half=[px*2,py*2,pz*2];
                let density=editor.as_ref().map_or_else(
                    || density_half(SEED,half[0],half[1],half[2]),
                    |ed| ed.world.sample(SEED,half),
                );
                if density>=0.0 { continue; }
                required.insert(key);
                if state.cells.get(&key).is_some_and(|(_,rev)| *rev==revision) { continue; }
                if let Some((old,_))=state.cells.remove(&key) { commands.entity(old).despawn(); }
                let entity=commands.spawn((
                    RigidBody::Static,
                    Collider::cuboid(COLLIDER_CELL_M as f32,COLLIDER_CELL_M as f32,COLLIDER_CELL_M as f32),
                    Transform::from_xyz(px as f32,py as f32,pz as f32),
                )).id();
                state.cells.insert(key,(entity,revision));
            }
        }
    }
    let expired:Vec<_>=state.cells.keys().copied().filter(|key| !required.contains(key)).collect();
    for key in expired {
        if let Some((entity,_))=state.cells.remove(&key) {
            commands.entity(entity).despawn();
        }
    }
}

/// Fraction of the sphere volume submerged under a flat surface.
/// Exact spherical cap fraction avoids the common linear-depth approximation.
fn submerged_fraction(center_y:f32,radius:f32,surface_y:f32)->f32 {
    let h=(surface_y-(center_y-radius)).clamp(0.0,2.0*radius);
    let volume_cap=std::f32::consts::PI*h*h*(radius-h/3.0);
    let sphere=(4.0/3.0)*std::f32::consts::PI*radius*radius*radius;
    volume_cap/sphere
}
fn buoyancy_acceleration(center_y:f32)->f32 {
    9.81 * WATER_DENSITY / ROCK_DENSITY * submerged_fraction(center_y,ROCK_RADIUS,WATER_Y)
}
fn buoyancy_for_rocks(
    time: Res<Time<Fixed>>,
    mut bodies: Query<(&Transform, &mut LinearVelocity), With<RockId>>,
) {
    let dt=time.delta_secs();
    for (transform,mut velocity) in &mut bodies {
        let submerged=submerged_fraction(transform.translation.y,ROCK_RADIUS,WATER_Y);
        if submerged<=0.0 { continue; }
        velocity.0.y+=buoyancy_acceleration(transform.translation.y)*dt;
        // Water drag opposes existing motion relative to a stationary ocean.
        velocity.0*=1.0/(1.0+1.5*submerged*dt);
    }
}
fn save_rock_states(
    time: Res<Time>,
    bodies: Query<(&RockId,&Transform,Option<&LinearVelocity>)>,
    mut rocks: ResMut<RockWorld>,
) {
    if time.elapsed_secs()-rocks.last_save_s < 5.0 { return; }
    rocks.last_save_s=time.elapsed_secs();
    for (id,transform,velocity) in &bodies {
        rocks.states.insert(*id, Snapshot {
            position:transform.translation,
            velocity:velocity.map_or(Vec3::ZERO,|v|v.0),
        });
    }
    if let Err(error)=write_rock_states(&rocks.save_path,&rocks.states) {
        error!(%error,"B5 failed to persist rocks");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn submerged_volume_physics_and_dense_rock_sinks() {
        assert_eq!(submerged_fraction(2.0,0.5,0.0),0.0);
        assert_eq!(submerged_fraction(-2.0,0.5,0.0),1.0);
        assert!((submerged_fraction(0.0,0.5,0.0)-0.5).abs()<1e-6);
        assert!(buoyancy_acceleration(-1.0)<9.81);
    }
    #[test]
    fn seed_based_rock_position_and_save_reopen() {
        let id=RockId{x:-3,z:9};
        assert_eq!(default_rock_position(id),default_rock_position(id));
        let path=std::env::temp_dir().join(format!("b5-rocks-test-{}.txt",std::process::id()));
        let mut state=HashMap::new();
        state.insert(id,Snapshot{position:Vec3::new(-17.0,1.0,76.0),velocity:Vec3::new(0.0,-1.0,0.0)});
        write_rock_states(&path,&state).unwrap();
        let restored=read_rock_states(&path).unwrap();
        assert_eq!(restored[&id].position,state[&id].position);
        assert_eq!(restored[&id].velocity,state[&id].velocity);
        fs::remove_file(path).unwrap();
    }
}
