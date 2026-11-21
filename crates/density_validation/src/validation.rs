//! B1 validation. GPU readback is permitted ONLY in this small, ignored
//! test harness; runtime B2 mesh generation must not read bulk data back.

use sandbox_world_core::{
    BlockCoord,
    density::{DensityBlock, DensityGrid},
};
use std::{
    future::Future,
    task::{Context, Poll, Waker},
    time::Duration,
};

#[test]
fn b4_density_shader_parses_and_validates() {
    let shader = include_str!("../../../assets/shaders/sdf_density_b4.wgsl");
    let module = naga::front::wgsl::parse_str(shader)
        .unwrap_or_else(|e| panic!("B4 shader parse: {}", e.emit_to_string(shader)));
    naga::valid::Validator::new(
        naga::valid::ValidationFlags::all(),
        naga::valid::Capabilities::all(),
    ).validate(&module).expect("B4 shader validation failed");
    assert!(module.entry_points.iter().any(|e| e.name == "main"));
}

const SHADER: &str = include_str!("../../../assets/shaders/sdf_density.wgsl");

#[test]
fn b3_adaptive_transition_shader_parses_and_validates() {
    let shader = include_str!("../../../assets/shaders/lod_transition.wgsl");
    let module = naga::front::wgsl::parse_str(shader)
        .unwrap_or_else(|e| panic!("B3 adaptive dual WGSL parse: {}", e.emit_to_string(shader)));
    let mut validator = naga::valid::Validator::new(
        naga::valid::ValidationFlags::all(),
        naga::valid::Capabilities::all(),
    );
    validator
        .validate(&module)
        .expect("B3 adaptive dual WGSL validation failed");
    assert!(
        module
            .entry_points
            .iter()
            .any(|e| e.name == "emit_transition")
    );
}

#[test]
fn b2_surface_nets_shader_parses_and_validates() {
    let shader = include_str!("../../../assets/shaders/surface_nets.wgsl");
    let module = naga::front::wgsl::parse_str(shader)
        .unwrap_or_else(|error| panic!("B2 shader parse: {}", error.emit_to_string(shader)));
    let mut validator = naga::valid::Validator::new(
        naga::valid::ValidationFlags::all(),
        naga::valid::Capabilities::all(),
    );
    validator
        .validate(&module)
        .expect("B2 Surface Nets WGSL validation failed");
    assert!(
        module
            .entry_points
            .iter()
            .any(|e| e.name == "emit_vertices")
    );
    assert!(module.entry_points.iter().any(|e| e.name == "emit_indices"));
}

#[test]
fn b1_shader_is_valid_wgsl_and_has_expected_entry_point() {
    let module = naga::front::wgsl::parse_str(SHADER)
        .unwrap_or_else(|e| panic!("WGSL parse error: {}", e.emit_to_string(SHADER)));
    let mut validator = naga::valid::Validator::new(
        naga::valid::ValidationFlags::all(),
        naga::valid::Capabilities::all(),
    );
    validator
        .validate(&module)
        .expect("B1 WGSL validation failed");
    assert!(module.entry_points.iter().any(|e| e.name == "main"));
}

fn block_on<T>(future: impl Future<Output = T>) -> T {
    let mut future = Box::pin(future);
    let mut context = Context::from_waker(Waker::noop());
    loop {
        match future.as_mut().poll(&mut context) {
            Poll::Ready(value) => return value,
            Poll::Pending => std::thread::sleep(Duration::from_millis(2)),
        }
    }
}

fn gpu_samples(grid: DensityGrid, seed: u32) -> Result<Vec<f32>, String> {
    use wgpu::util::DeviceExt;

    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
        backends: wgpu::Backends::VULKAN,
        ..wgpu::InstanceDescriptor::new_without_display_handle()
    });
    let adapter = block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        ..Default::default()
    }))
    .map_err(|e| format!("GPU adapter unavailable: {e}"))?;
    let info = adapter.get_info();
    println!(
        "B1 selected Vulkan adapter: {} ({:?})",
        info.name, info.device_type
    );
    if !matches!(
        info.device_type,
        wgpu::DeviceType::DiscreteGpu | wgpu::DeviceType::IntegratedGpu
    ) {
        return Err(format!(
            "B1 real GPU parity requires hardware Vulkan adapter, got {:?}",
            info.device_type
        ));
    }
    let (device, queue) = block_on(adapter.request_device(&wgpu::DeviceDescriptor::default()))
        .map_err(|e| format!("GPU device unavailable: {e}"))?;

    let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("B1 density parity shader"),
        source: wgpu::ShaderSource::Wgsl(SHADER.into()),
    });
    let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
        label: Some("B1 density parity compute"),
        layout: None,
        module: &shader,
        entry_point: Some("main"),
        compilation_options: Default::default(),
        cache: None,
    });

    let mut params = Vec::with_capacity(32);
    for word in grid.uniform_words(seed) {
        params.extend_from_slice(&word.to_le_bytes());
    }
    let uniform = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("B1 density params"),
        contents: &params,
        usage: wgpu::BufferUsages::UNIFORM,
    });
    let size = (grid.len() * std::mem::size_of::<f32>()) as u64;
    let storage = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("B1 density output"),
        size,
        usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC,
        mapped_at_creation: false,
    });
    let staging = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("B1 test-only readback"),
        size,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });
    let binding = pipeline.get_bind_group_layout(0);
    let group = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("B1 density uniform/output"),
        layout: &binding,
        entries: &[
            wgpu::BindGroupEntry {
                binding: 0,
                resource: uniform.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 1,
                resource: storage.as_entire_binding(),
            },
        ],
    });
    let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
        label: Some("B1 density parity encoder"),
    });
    {
        let mut pass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
            label: Some("B1 density parity pass"),
            timestamp_writes: None,
        });
        pass.set_pipeline(&pipeline);
        pass.set_bind_group(0, &group, &[]);
        pass.dispatch_workgroups((grid.len() as u32).div_ceil(64), 1, 1);
    }
    encoder.copy_buffer_to_buffer(&storage, 0, &staging, 0, size);
    queue.submit(Some(encoder.finish()));

    let slice = staging.slice(..);
    let (sender, receiver) = std::sync::mpsc::channel();
    slice.map_async(wgpu::MapMode::Read, move |value| {
        let _ = sender.send(value);
    });
    device
        .poll(wgpu::PollType::Wait {
            submission_index: None,
            timeout: Some(Duration::from_secs(30)),
        })
        .map_err(|e| format!("GPU poll failed: {e}"))?;
    receiver
        .recv_timeout(Duration::from_secs(5))
        .map_err(|e| format!("GPU readback callback missing: {e}"))?
        .map_err(|e| format!("GPU readback failed: {e}"))?;

    let mapping = staging
        .get_mapped_range(..)
        .map_err(|e| format!("GPU mapped range failed: {e}"))?;
    let out: Vec<f32> = mapping
        .chunks_exact(4)
        .map(|chunk| f32::from_le_bytes(chunk.try_into().unwrap()))
        .collect();
    drop(mapping);
    staging.unmap();
    Ok(out)
}

#[test]
#[ignore = "Requires a Vulkan/DX12 compute adapter; run explicitly on the GPU machine"]
fn b1_cpu_gpu_density_parity_lod_seed_negative_coordinates_and_cave() {
    for (seed, coord, lod) in [
        (
            42,
            BlockCoord {
                x: -2,
                y: -1,
                z: -1,
            },
            0,
        ),
        (0xabcdef12, BlockCoord { x: 0, y: 0, z: 0 }, 1),
        (0x12345678, BlockCoord { x: 5, y: -1, z: 4 }, 2),
    ] {
        let cpu = DensityBlock::generate(seed, coord, lod).unwrap();
        let gpu = gpu_samples(cpu.grid, seed).expect("GPU SDF compute failed");
        assert_eq!(gpu.len(), cpu.samples.len());
        let mut max_error = 0.0_f32;
        for (index, (a, b)) in cpu.samples.iter().zip(&gpu).enumerate() {
            let delta = (a - b).abs();
            assert!(
                delta <= 0.03,
                "CPU/GPU mismatch seed={seed} coord={coord:?} lod={lod} sample={index} cpu={a} gpu={b} delta={delta}"
            );
            max_error = max_error.max(delta);
        }
        println!(
            "B1 GPU parity PASS seed={seed} lod={lod} samples={} max_error={max_error:.6}m",
            cpu.samples.len()
        );
    }
}
