//! B4 deterministic, renderer-independent SDF brushes and durable edit journal.
//! Positions/radii are integer half-meter units to match CPU/WGSL grid sampling.
use crate::{BlockCoord, density::DensityGrid};
use std::{collections::HashMap, fs, io, path::Path};

const BLOCK_HALF: i64 = 32;
const MAX_BRUSHES: usize = 4096;
pub const MAX_GPU_BRUSHES_PER_BLOCK: usize = 32;
const MAX_RADIUS_HALF: i32 = 16;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EditMode {
    Add,
    Subtract,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Brush {
    pub center_half: [i32; 3],
    pub radius_half: i32,
    pub mode: EditMode,
}

impl Brush {
    pub fn sample(self, original: f32, half: [i32; 3]) -> f32 {
        let dx = (half[0] as f32 - self.center_half[0] as f32) * 0.5;
        let dy = (half[1] as f32 - self.center_half[1] as f32) * 0.5;
        let dz = (half[2] as f32 - self.center_half[2] as f32) * 0.5;
        let sphere = (dx * dx + dy * dy + dz * dz).sqrt() - self.radius_half as f32 * 0.5;
        match self.mode {
            EditMode::Add => original.min(sphere),
            EditMode::Subtract => original.max(-sphere),
        }
    }

    fn affects(self, block: BlockCoord) -> bool {
        // LOD0/1/2 share a one-cell halo; include the maximum LOD2 2m halo.
        let indices = [block.x, block.y, block.z];
        indices.iter().enumerate().all(|(axis, &b)| {
            let min = b * BLOCK_HALF - 4;
            let max = (b + 1) * BLOCK_HALF + 4;
            (self.center_half[axis] as i64 + self.radius_half as i64) >= min
                && (self.center_half[axis] as i64 - self.radius_half as i64) <= max
        })
    }

    pub fn intersects_grid(self, grid: DensityGrid) -> bool {
        (0..3).all(|axis| {
            let lo = grid.base_half[axis] as i64 - grid.step_half as i64;
            let hi = grid.base_half[axis] as i64
                + (grid.cells as i64 + 1) * grid.step_half as i64;
            self.center_half[axis] as i64 + self.radius_half as i64 >= lo
                && self.center_half[axis] as i64 - self.radius_half as i64 <= hi
        })
    }

    fn affected_blocks(self) -> Vec<BlockCoord> {
        let axes = self.center_half.map(|v| {
            let a = v as i64;
            (
                (a - self.radius_half as i64 - 4).div_euclid(BLOCK_HALF),
                (a + self.radius_half as i64 + 4).div_euclid(BLOCK_HALF),
            )
        });
        let mut result = Vec::new();
        for z in axes[2].0..=axes[2].1 {
            for y in axes[1].0..=axes[1].1 {
                for x in axes[0].0..=axes[0].1 {
                    let block = BlockCoord { x, y, z };
                    if self.affects(block) {
                        result.push(block);
                    }
                }
            }
        }
        result
    }
}

#[derive(Debug, Default, Clone)]
pub struct WorldEdits {
    brushes: Vec<Brush>,
    revisions: HashMap<BlockCoord, u64>,
    generation: u64,
}

impl WorldEdits {
    pub fn len(&self) -> usize { self.brushes.len() }
    pub fn is_empty(&self) -> bool { self.brushes.is_empty() }
    pub fn revision(&self, coord: BlockCoord) -> u64 {
        self.revisions.get(&coord).copied().unwrap_or(0)
    }
    pub fn brushes_for_grid(&self, grid: DensityGrid) -> Vec<Brush> {
        self.brushes.iter().copied().filter(|brush| brush.intersects_grid(grid)).collect()
    }
    pub fn sample(&self, seed: u32, half: [i32; 3]) -> f32 {
        self.brushes.iter().copied().fold(
            crate::density::density_half(seed, half[0], half[1], half[2]),
            |value, brush| brush.sample(value, half),
        )
    }
    pub fn apply(&mut self, brush: Brush) -> Result<Vec<BlockCoord>, &'static str> {
        if !(1..=MAX_RADIUS_HALF).contains(&brush.radius_half) {
            return Err("B4 brush radius must be 0.5m to 8m");
        }
        if self.brushes.len() >= MAX_BRUSHES {
            return Err("B4 world edit journal full");
        }
        let affected = brush.affected_blocks();
        if affected.iter().any(|&block| self.brushes.iter().filter(|b| b.affects(block)).count() >= MAX_GPU_BRUSHES_PER_BLOCK) {
            return Err("B4 GPU brush capacity reached; refusing silent truncation");
        }
        self.generation = self.generation.checked_add(1).ok_or("B4 revision overflow")?;
        self.brushes.push(brush);
        for &block in &affected {
            self.revisions.insert(block, self.generation);
        }
        Ok(affected)
    }
    pub fn save_to(&self, path: &Path) -> io::Result<()> {
        let mut contents = String::from("SB4 1\n");
        for brush in &self.brushes {
            let mode = match brush.mode { EditMode::Add => "A", EditMode::Subtract => "S" };
            contents.push_str(&format!("{} {} {} {} {}\n",
                brush.center_half[0], brush.center_half[1], brush.center_half[2], brush.radius_half, mode));
        }
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() { fs::create_dir_all(parent)?; }
        }
        let temporary = path.with_extension("b4tmp");
        fs::write(&temporary, contents)?;
        fs::rename(&temporary, path)
    }
    pub fn load_from(path: &Path) -> io::Result<Self> {
        let content = match fs::read_to_string(path) {
            Ok(s) => s,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Self::default()),
            Err(e) => return Err(e),
        };
        if content.len() > 1024 * 1024 {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "B4 journal too large"));
        }
        let mut lines = content.lines();
        if lines.next() != Some("SB4 1") {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "B4 journal version mismatch"));
        }
        let mut world = Self::default();
        for line in lines {
            let words: Vec<&str> = line.split_ascii_whitespace().collect();
            if words.len() != 5 {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "B4 malformed edit record"));
            }
            let integer = |index: usize| -> io::Result<i32> {
                words[index].parse().map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "B4 invalid number"))
            };
            let mode = match words[4] {
                "A" => EditMode::Add,
                "S" => EditMode::Subtract,
                _ => return Err(io::Error::new(io::ErrorKind::InvalidData, "B4 invalid brush mode")),
            };
            world.apply(Brush {
                center_half: [integer(0)?, integer(1)?, integer(2)?],
                radius_half: integer(3)?,
                mode,
            }).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        }
        Ok(world)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn brush(mode: EditMode) -> Brush {
        Brush { center_half: [-1, -4, 1], radius_half: 4, mode }
    }
    #[test]
    fn deterministic_add_subtract_and_shared_halo_at_negative_boundary() {
        let mut world = WorldEdits::default();
        let block = BlockCoord { x: -1, y: -1, z: 0 };
        let baseline = world.sample(42, [-1, -4, 1]);
        let touched = world.apply(brush(EditMode::Add)).unwrap();
        assert!(touched.contains(&block));
        assert!(world.revision(block) > 0);
        assert!(world.sample(42, [-1, -4, 1]) <= baseline);
        world.apply(brush(EditMode::Subtract)).unwrap();
        assert!(world.sample(42, [-1, -4, 1]) >= 0.0);
        let grid = DensityGrid::new(block, 2).unwrap();
        assert_eq!(world.brushes_for_grid(grid).len(), 2);
    }
    #[test]
    fn journal_save_load_and_corruption_rejection() {
        let unique = format!("sandbox-b4-{}-{}", std::process::id(), 448899_u64);
        let path = std::env::temp_dir().join(unique);
        let mut world = WorldEdits::default();
        world.apply(brush(EditMode::Subtract)).unwrap();
        world.save_to(&path).unwrap();
        let reopened = WorldEdits::load_from(&path).unwrap();
        assert_eq!(reopened.len(), 1);
        let coord = BlockCoord { x: -1, y: -1, z: 0 };
        assert_eq!(reopened.revision(coord), world.revision(coord));
        let sample = [-1, -4, 1];
        assert_eq!(reopened.sample(42, sample), world.sample(42, sample));
        fs::write(&path, "SB4 1\n1 2 3 bad A\n").unwrap();
        assert!(WorldEdits::load_from(&path).is_err());
        fs::remove_file(path).unwrap();
    }
    #[test]
    fn zero_and_excessive_radius_rejected_without_mutation() {
        let mut world = WorldEdits::default();
        for radius in [0, -1, 17] {
            assert!(world.apply(Brush {center_half:[0,0,0], radius_half:radius, mode:EditMode::Add}).is_err());
        }
        assert!(world.is_empty());
    }
    #[test]
    fn brush_gpu_capacity_is_explicit() {
        let mut world = WorldEdits::default();
        for _ in 0..MAX_GPU_BRUSHES_PER_BLOCK {
            world.apply(brush(EditMode::Add)).unwrap();
        }
        assert!(world.apply(brush(EditMode::Subtract)).is_err());
        assert_eq!(world.len(), MAX_GPU_BRUSHES_PER_BLOCK);
    }
}
