//! World coordinate definitions independent of Bevy and rendering.

pub const BLOCK_EDGE_METERS: i64 = 16;

pub mod density;
pub mod collision;
pub mod edits;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct BlockCoord {
    pub x: i64,
    pub y: i64,
    pub z: i64,
}

impl BlockCoord {
    /// Maps integer world-space meters to logical chunks, including negative coordinates.
    pub fn from_meter_grid(x: i64, y: i64, z: i64) -> Self {
        Self {
            x: x.div_euclid(BLOCK_EDGE_METERS),
            y: y.div_euclid(BLOCK_EDGE_METERS),
            z: z.div_euclid(BLOCK_EDGE_METERS),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn negative_chunk_boundary_is_not_truncated_toward_zero() {
        assert_eq!(BlockCoord::from_meter_grid(-1, 0, 15).x, -1);
        assert_eq!(BlockCoord::from_meter_grid(-16, 0, 15).x, -1);
        assert_eq!(BlockCoord::from_meter_grid(-17, 0, 15).x, -2);
        assert_eq!(BlockCoord::from_meter_grid(15, 0, 15).x, 0);
        assert_eq!(BlockCoord::from_meter_grid(16, 0, 15).x, 1);
    }
}
