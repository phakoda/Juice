import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("evidence", ROOT / "scripts/juice_runtime_evidence.py")
evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evidence)

def sample():
    # Synthetic unit-test data, not a device benchmark or compatibility claim.
    return {"schema_version": 1,
            "workload": {"id": "synthetic-test", "version": "test", "architecture": "x86_64", "resolution": [1280, 720]},
            "environment": {"device": "test-only", "os": "test-only", "installation": "test-only",
                "measurement_source": "synthetic unit test", "juice_commit": "a"*40, "runtime_sha256": "b"*64},
            "runs": [{"id": "1", "phase": "warm", "outcome": "pass",
                "checks": {"launch": "pass", "ui": "pass", "file_io": "pass", "exit": "pass"},
                "launch_ms": 100, "frame_ms": [10, 20, 30, 40], "peak_rss_bytes": 123,
                "thermal_state": "nominal"}]}

class EvidenceTests(unittest.TestCase):
    def test_statistics(self):
        got = evidence.summarize(sample())["phases"]["warm"]
        self.assertEqual(got["frame_ms"]["median"], 25)
        self.assertEqual(got["frame_ms"]["p95"], 40)
        self.assertEqual(got["mean_fps"], 40)
    def test_empty_is_not_zero(self):
        value = sample(); value["runs"] = []
        self.assertIsNone(evidence.summarize(value)["phases"]["warm"]["frame_ms"])
    def test_failed_run_excluded(self):
        value = sample(); value["runs"][0]["outcome"] = "fail"
        value["runs"][0]["checks"]["exit"] = "fail"
        self.assertIsNone(evidence.summarize(value)["phases"]["warm"]["frame_ms"])
    def test_incomplete_not_pass(self):
        value = sample(); value["runs"][0]["checks"]["ui"] = "untested"
        with self.assertRaises(evidence.EvidenceError): evidence.validate(value)
    def test_duplicate_id(self):
        value = sample(); value["runs"].append(copy.deepcopy(value["runs"][0]))
        with self.assertRaises(evidence.EvidenceError): evidence.validate(value)
    def test_nonfinite_and_boolean(self):
        for bad in (float("nan"), float("inf"), -1, 0, True, "10", 10**1000):
            value = sample(); value["runs"][0]["frame_ms"] = [bad]
            with self.assertRaises(evidence.EvidenceError): evidence.validate(value)
    def test_bad_provenance(self):
        value = sample(); value["environment"]["juice_commit"] = "main"
        with self.assertRaises(evidence.EvidenceError): evidence.validate(value)
    def test_workload_mismatch(self):
        other = sample(); other["workload"]["version"] = "different"
        with self.assertRaises(evidence.EvidenceError): evidence.compare(sample(), other)
    def test_device_mismatch(self):
        other = sample(); other["environment"]["device"] = "different"
        with self.assertRaises(evidence.EvidenceError): evidence.compare(sample(), other)
        self.assertTrue(evidence.compare(sample(), other, True)["differences"])
    def test_phase_isolation(self):
        value = sample(); cold = copy.deepcopy(value["runs"][0])
        cold.update(id="cold", phase="cold", launch_ms=900)
        value["runs"].append(cold)
        report = evidence.summarize(value)
        self.assertEqual(report["phases"]["cold"]["launch_ms"]["median"], 900)
        self.assertEqual(report["phases"]["warm"]["launch_ms"]["median"], 100)
    def test_comparison(self):
        candidate = sample(); candidate["runs"][0]["launch_ms"] = 50
        report = evidence.compare(sample(), candidate)
        self.assertEqual(report["comparison"]["warm"]["launch_ms_median"]["latency_reduction_percent"], 50)
        self.assertIsNone(report["comparison"]["cold"]["launch_ms_median"]["latency_reduction_percent"])
    def test_bounded_load(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "bad.json"
            with path.open("wb") as f: f.truncate(evidence.MAX_FILE_BYTES + 1)
            with self.assertRaises(evidence.EvidenceError): evidence.load(path)
    def test_round_trip(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "test.json"; path.write_text(json.dumps(sample()), encoding="utf-8")
            self.assertEqual(evidence.load(path), sample())
    def test_invalid_memory_and_resolution(self):
        value = sample(); value["runs"][0]["peak_rss_bytes"] = True
        with self.assertRaises(evidence.EvidenceError): evidence.validate(value)
        value = sample(); value["workload"]["resolution"] = [0, 720]
        with self.assertRaises(evidence.EvidenceError): evidence.validate(value)
    def test_outcome_consistency(self):
        for outcome in ("fail", "untested"):
            value = sample(); value["runs"][0]["outcome"] = outcome
            with self.assertRaises(evidence.EvidenceError): evidence.validate(value)
    def test_invalid_thermal_type(self):
        for bad in ([], {}, True, 7, None):
            value = sample(); value["runs"][0]["thermal_state"] = bad
            with self.assertRaises(evidence.EvidenceError): evidence.validate(value)
    def test_extreme_finite_observations(self):
        for bad in (1e308, 5e-324, evidence.MAX_MILLISECONDS+1):
            value = sample(); value["runs"][0]["frame_ms"] = [bad]
            with self.assertRaises(evidence.EvidenceError): evidence.validate(value)
    def test_duplicate_json_keys_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/"duplicate.json"
            path.write_text('{"schema_version":1,"schema_version":1}')
            with self.assertRaises(evidence.EvidenceError): evidence.load(path)
    def test_utf16_is_not_utf8_evidence(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/"utf16.json"
            path.write_bytes(json.dumps(sample()).encode("utf-16"))
            with self.assertRaises(evidence.EvidenceError): evidence.load(path)
    def test_extreme_summary_serializes(self):
        value=sample(); value["runs"][0]["frame_ms"]=[evidence.MIN_FRAME_MILLISECONDS,evidence.MAX_MILLISECONDS]
        json.dumps(evidence.summarize(value),allow_nan=False)

if __name__ == "__main__":
    unittest.main()
