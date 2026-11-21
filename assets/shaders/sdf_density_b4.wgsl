// B4 GPU density with persistent sphere edits; B1 reference shader is unchanged.
// B1 density: same hash/noise/SDF algebra as sandbox_world_core::density.
// Negative is solid, positive is air. x/y/z are in integer 0.5m units.

struct DensityParams {
    base_x: i32,
    base_y: i32,
    base_z: i32,
    seed: u32,
    step_half: i32,
    dimension: u32,
    count: u32,
    reserved: u32,
    vertex_start: u32,
    vertex_end: u32,
    index_start: u32,
    index_end: u32,
    cells: u32,
    padding0: u32,
    padding1: u32,
    padding2: u32,
}

@group(0) @binding(0) var<uniform> p: DensityParams;
@group(0) @binding(1) var<storage, read_write> samples: array<f32>;

struct EditBrush {
    center_radius: vec4<i32>,
    mode_pad: vec4<i32>,
}
@group(0) @binding(2) var<storage, read> edit_brushes: array<EditBrush>;

fn hash2(seed: u32, x: i32, z: i32) -> u32 {
    var h = seed ^ (bitcast<u32>(x) * 0x9e3779b1u) ^ (bitcast<u32>(z) * 0x85ebca77u);
    h = h ^ (h >> 16u);
    h = h * 0x7feb352du;
    h = h ^ (h >> 15u);
    h = h * 0x846ca68bu;
    return h ^ (h >> 16u);
}
fn hash01(seed: u32, x: i32, z: i32) -> f32 {
    return f32(hash2(seed, x, z) & 1023u) * (1.0 / 1023.0);
}
fn smooth_curve(t: f32) -> f32 {
    return t * t * (3.0 - 2.0 * t);
}
fn lerp(a: f32, b: f32, t: f32) -> f32 {
    return a + (b - a) * t;
}
fn floor_div(a: i32, divisor: i32) -> i32 {
    let q = a / divisor;
    let r = a % divisor;
    if (r < 0) {
        return q - 1;
    }
    return q;
}
fn noise2_half(seed: u32, hx: i32, hz: i32, scale: i32) -> f32 {
    let gx = floor_div(hx, scale);
    let gz = floor_div(hz, scale);
    let tx = smooth_curve(f32(hx - gx * scale) / f32(scale));
    let tz = smooth_curve(f32(hz - gz * scale) / f32(scale));
    let a = lerp(hash01(seed, gx, gz), hash01(seed, gx + 1, gz), tx);
    let b = lerp(hash01(seed, gx, gz + 1), hash01(seed, gx + 1, gz + 1), tx);
    return lerp(a, b, tz);
}
fn terrain_height_half(seed: u32, hx: i32, hz: i32) -> f32 {
    return -3.0
        + 11.0 * noise2_half(seed ^ 0x045d9f3bu, hx, hz, 128)
        + 5.0 * noise2_half(seed ^ 0x9e3779b9u, hx, hz, 32);
}
fn cave_center_y(seed: u32, hx: i32) -> f32 {
    return -7.0 + 2.0 * noise2_half(seed ^ 0x04c11db7u, hx, 0, 128);
}
fn cave_center_z(seed: u32, hx: i32) -> f32 {
    return -3.0 + 6.0 * noise2_half(seed ^ 0x13a5ba1du, hx, 0, 128);
}
fn density_half(seed: u32, hx: i32, hy: i32, hz: i32) -> f32 {
    let y = f32(hy) * 0.5;
    let z = f32(hz) * 0.5;
    let height = terrain_height_half(seed, hx, hz);
    let cy = cave_center_y(seed, hx);
    let cz = cave_center_z(seed, hx);
    let dy = y - cy;
    let dz = z - cz;
    return max(y - height, 2.6 - sqrt(dy * dy + dz * dz));
}
@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let index = gid.x;
    if (index >= p.count) {
        return;
    }
    let d = p.dimension;
    let x = i32(index % d);
    let y = i32((index / d) % d);
    let z = i32(index / (d * d));
    let hx = p.base_x + (x - 1) * p.step_half;
    let hy = p.base_y + (y - 1) * p.step_half;
    let hz = p.base_z + (z - 1) * p.step_half;
    var value = density_half(p.seed, hx, hy, hz);
    // Explicit additive/subtractive CSG; same order as persisted CPU journal.
    for (var brush_index = 0u; brush_index < p.padding0; brush_index += 1u) {
        let brush = edit_brushes[brush_index];
        let delta = vec3f(
            f32(hx - brush.center_radius.x),
            f32(hy - brush.center_radius.y),
            f32(hz - brush.center_radius.z)
        ) * 0.5;
        let sphere = length(delta) - f32(brush.center_radius.w) * 0.5;
        if (brush.mode_pad.x == 0) {
            value = min(value, sphere);
        } else {
            value = max(value, -sphere);
        }
    }
    samples[index] = value;
}
