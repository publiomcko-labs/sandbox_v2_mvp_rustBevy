import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("comparison_reduce", ROOT / "scripts" / "comparison-v1-reduce.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
CONTRACT = ROOT / "benchmarks" / "comparison-v1.json"


class ComparisonContractTests(unittest.TestCase):
    def test_contract_route_and_edits(self):
        c = json.loads(CONTRACT.read_text(encoding="utf-8"))
        self.assertEqual((c["warmup_s"], c["duration_s"], c["requested_speed_mps"]), (12, 46, 18))
        self.assertEqual([(s["start_s"], s["end_s"]) for s in c["segments"]], [(0, 12), (12, 30), (30, 46)])
        self.assertEqual(c["edits"]["seconds"], [25, 28, 31, 34, 37, 40])
        self.assertEqual(c["edits"]["modes"], ["subtract", "add"] * 3)
        self.assertFalse(c["methodology"]["scene_content_equivalent"])

    def test_percentiles_and_low_frames(self):
        self.assertEqual(mod.percentile([20, 10, 30, 40], .95), 40)
        self.assertAlmostEqual(mod.low_fps([10.0] * 99 + [100.0], .01), 10.0)

    def test_reducer_never_qualifies_graphics(self):
        frames = [(12.0 + i * .016, 16.0) for i in range(2130)]
        frames[-1] = (45.99, 16.0)
        meta = {"engine": "rust_bevy", "scenario_id": "survey46-six-edits-v1", "render_mode": "gpu_headless"}
        result = mod.reduce_trace(frames, CONTRACT, meta)
        self.assertFalse(result["comparability"]["graphics_frame_intervals_comparable"])
        self.assertFalse(result["comparability"]["strict_perf60_qualified"])
        self.assertFalse(result["comparability"]["edit_first_correct_pixel_measured"])

    def test_incomplete_and_corrupt_traces_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "trace.csv"
            path.write_text("t_s,interval_ms\n12.1,16\n12.0,16\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                mod.parse_csv(path, minimum=2)
            path.write_text("t_s,interval_ms\n12.1,0\n12.2,16\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                mod.parse_csv(path, minimum=2)


if __name__ == "__main__":
    unittest.main()
