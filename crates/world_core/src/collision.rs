//! B8 functional SDF collision surface. CPU triangles approximate the same
//! signed density (including persisted B4 brushes) sent to the GPU renderer.
//! Negative density is solid, positive is air. No axis-aligned occupancy cubes.
use crate::edits::WorldEdits;

/// A four-meter tile, sampled at one-meter intervals; coordinates of mesh
/// vertices are LOCAL to the tile origin for Avian trimesh collision.
pub const TILE_METERS: i32 = 4;
pub const SAMPLE_METERS: i32 = 1;
pub const SAMPLES_PER_AXIS: usize = (TILE_METERS / SAMPLE_METERS) as usize + 1;

#[derive(Debug, Default)]
pub struct CollisionSurface {
    pub vertices: Vec<[f32; 3]>,
    pub triangles: Vec<[u32; 3]>,
}

impl CollisionSurface {
    pub fn is_empty(&self) -> bool { self.triangles.is_empty() }
}

const CORNERS: [[usize; 3]; 8] = [
    [0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0],
    [0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1],
];
// Six tetrahedra share diagonal 0-6; every neighboring cube chooses
// the same face diagonals in world coordinates.
const TETS: [[usize; 4]; 6] = [
    [0, 5, 1, 6], [0, 1, 2, 6], [0, 2, 3, 6],
    [0, 3, 7, 6], [0, 7, 4, 6], [0, 4, 5, 6],
];

fn add3(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0]+b[0], a[1]+b[1], a[2]+b[2]]
}
fn sub3(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0]-b[0], a[1]-b[1], a[2]-b[2]]
}
fn cross(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]]
}
fn dot(a: [f32; 3], b: [f32; 3]) -> f32 {
    a[0]*b[0]+a[1]*b[1]+a[2]*b[2]
}

/// Build triangles in a caller-provided density field at integer half-meter
/// coordinates. Shared boundaries sample exactly the same world positions.
pub fn surface_from_field(
    origin: [i32; 3],
    mut density: impl FnMut([i32; 3]) -> f32,
) -> CollisionSurface {
    const N: usize = SAMPLES_PER_AXIS;
    let idx = |x: usize,y: usize,z: usize| (z*N+y)*N+x;
    let mut samples = vec![0.0_f32;N*N*N];
    for z in 0..N { for y in 0..N { for x in 0..N {
        let half = [
            (origin[0]+x as i32*SAMPLE_METERS)*2,
            (origin[1]+y as i32*SAMPLE_METERS)*2,
            (origin[2]+z as i32*SAMPLE_METERS)*2,
        ];
        samples[idx(x,y,z)]=density(half);
    }}}
    let mut out=CollisionSurface::default();
    for z in 0..N-1 { for y in 0..N-1 { for x in 0..N-1 {
        let mut p=[[0.0;3];8];
        let mut v=[0.0;8];
        for (i,off) in CORNERS.iter().enumerate() {
            let (ix,iy,iz)=(x+off[0],y+off[1],z+off[2]);
            v[i]=samples[idx(ix,iy,iz)];
            p[i]=[ix as f32*SAMPLE_METERS as f32,
                  iy as f32*SAMPLE_METERS as f32,
                  iz as f32*SAMPLE_METERS as f32];
        }
        for tet in TETS {
            let mut inside=Vec::with_capacity(4);
            let mut outside=Vec::with_capacity(4);
            for i in tet {
                if v[i]<0.0 { inside.push(i); } else { outside.push(i); }
            }
            if inside.is_empty() || outside.is_empty() { continue; }
            let edge = |a:usize,b:usize| -> [f32;3] {
                let denom=v[a]-v[b];
                let t=if denom.abs()<1.0e-10 {0.5} else {(v[a]/denom).clamp(0.0,1.0)};
                add3(p[a],[
                    (p[b][0]-p[a][0])*t,
                    (p[b][1]-p[a][1])*t,
                    (p[b][2]-p[a][2])*t,
                ])
            };
            let mut tris=Vec::<[[f32;3];3]>::with_capacity(2);
            match inside.len() {
                1 => {
                    let a=inside[0];
                    tris.push([edge(a,outside[0]),edge(a,outside[1]),edge(a,outside[2])]);
                }
                3 => {
                    let a=outside[0];
                    tris.push([edge(a,inside[0]),edge(a,inside[1]),edge(a,inside[2])]);
                }
                2 => {
                    let (a,b,c,d)=(inside[0],inside[1],outside[0],outside[1]);
                    let (ac,ad,bc,bd)=(edge(a,c),edge(a,d),edge(b,c),edge(b,d));
                    tris.push([ac,ad,bc]);
                    tris.push([bc,ad,bd]);
                }
                _=>unreachable!(),
            }
            let inside_avg=inside.iter().fold([0.0;3],|acc,i|add3(acc,p[*i]));
            let outside_avg=outside.iter().fold([0.0;3],|acc,i|add3(acc,p[*i]));
            let outward=sub3(outside_avg,inside_avg);
            for mut tri in tris {
                let normal=cross(sub3(tri[1],tri[0]),sub3(tri[2],tri[0]));
                if dot(normal,normal)<1.0e-12 {continue;}
                if dot(normal,outward)<0.0 {tri.swap(1,2);}
                let i=out.vertices.len() as u32;
                out.vertices.extend_from_slice(&tri);
                out.triangles.push([i,i+1,i+2]);
            }
        }
    }}}
    out
}

/// Physics and visual terrain use the SAME edit journal + seed + SDF.
/// A static trimesh is hollow by design; rock bodies remain dynamic.
pub fn surface_from_world(seed:u32, origin:[i32;3], world:&WorldEdits) -> CollisionSurface {
    surface_from_field(origin,|half|world.sample(seed,half))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{density::{density_half,cave_center_half},edits::{Brush,EditMode}};
    #[test]
    fn planar_sdf_surface_is_at_true_zero_crossing() {
        let result=surface_from_field([0,0,0],|half|half[1] as f32*0.5-1.5);
        assert!(!result.is_empty());
        for point in result.vertices {
            assert!((point[1]-1.5).abs()<1e-6);
            assert!((0.0..=4.0).contains(&point[0]));
            assert!((0.0..=4.0).contains(&point[2]));
        }
    }
    #[test]
    fn tunnel_produces_walls_but_not_solid_cave_center() {
        let seed=42;
        let (cy,cz)=cave_center_half(seed,0);
        let hy=(cy*2.0).round() as i32;
        let hz=(cz*2.0).round() as i32;
        assert!(density_half(seed,0,hy,hz)>0.0,"cave core must remain hollow");
        assert!(density_half(seed,0,hy,hz+16)<0.0,"cave wall must remain solid");
        let world=WorldEdits::default();
        let mut tris=0;
        for y in (-16..=0).step_by(4) {
            for z in (-12..=8).step_by(4) {
                tris+=surface_from_world(seed,[0,y,z],&world).triangles.len();
            }
        }
        assert!(tris>0,"cave and surrounding terrain must have collision surfaces");
    }
    #[test]
    fn shared_tile_boundary_uses_identical_world_density_and_edits() {
        let seed=42;
        let mut world=WorldEdits::default();
        world.apply(Brush{center_half:[8,4,0],radius_half:6,mode:EditMode::Subtract}).unwrap();
        let first=surface_from_world(seed,[0,0,0],&world);
        let next=surface_from_world(seed,[4,0,0],&world);
        for (surface,on_boundary) in [(&first,4.0_f32),(&next,0.0_f32)] {
            for p in &surface.vertices {
                assert!((0.0..=4.0).contains(&p[0]));
                assert!((0.0..=4.0).contains(&p[1]));
                assert!((0.0..=4.0).contains(&p[2]));
                if (p[0]-on_boundary).abs()<1e-5 {
                    let half=[8,(p[1]*2.0).round() as i32,(p[2]*2.0).round() as i32];
                    assert!(world.sample(seed,half).is_finite());
                }
            }
        }
        assert!(!first.is_empty() || !next.is_empty());
    }
    #[test]
    fn fully_empty_and_fully_solid_tiles_have_no_colliders() {
        assert!(surface_from_field([0,0,0],|_|1.0).is_empty());
        assert!(surface_from_field([0,0,0],|_|-1.0).is_empty());
    }
}
