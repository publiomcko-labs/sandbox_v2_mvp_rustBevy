import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("cmp", ROOT / "scripts" / "comparison-v1-compare.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def result(engine="godot_voxel_tools", profile="cold", mode="interactive"):
    metrics = {key: 16.5 for key in mod.KEYS}
    return {
        "schema": "sandbox_comparison_result_v1",
        "contract_id": "survey46-six-edits-v1",
        "contract_sha256": "x" * 64,
        "environment": {
            "engine": engine, "profile": profile, "render_mode": mode,
            "hostname": "ONE-PC", "resolution": "1920x1080",
            "cpu": ["same cpu"], "gpu": ["same gpu / driver"]
        },
        "comparability": {"identical_scene_complexity": False},
        "frames": metrics
    }


class ComparisonAggregatorTests(unittest.TestCase):
    def test_three_matched_repetitions(self):
        res = mod.compare([result()] * 3, [result("rust_bevy")] * 3)
        self.assertEqual(res["status"], "MATCHED_HARDWARE_DIAGNOSTIC")
        self.assertFalse(res["present_time_qualified"])
        self.assertFalse(res["scene_equivalence"])

    def test_headless_rejected_even_exploratory(self):
        with self.assertRaisesRegex(ValueError, "headless"):
            mod.compare([result(mode="cpu_headless")], [result("rust_bevy")], exploratory=True)

    def test_cross_machine_and_profile_rejected(self):
        other = result("rust_bevy", profile="warm")
        with self.assertRaisesRegex(ValueError, "profile"):
            mod.compare([result()], [other], exploratory=True)
        other = result("rust_bevy")
        other["environment"]["hostname"] = "OTHER-PC"
        with self.assertRaisesRegex(ValueError, "hostname"):
            mod.compare([result()], [other], exploratory=True)

    def test_inadequate_repetitions_rejected(self):
        with self.assertRaisesRegex(ValueError, "three repetitions"):
            mod.compare([result()], [result("rust_bevy")])


if __name__ == "__main__":
    unittest.main()
