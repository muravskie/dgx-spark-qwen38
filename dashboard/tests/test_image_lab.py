"""ComfyUI telemetry is truthful and never sends prompt text to the browser."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import image_lab


class ImageLabTests(unittest.TestCase):
    def test_snapshot_reports_running_model_and_sanitized_recent_result(self):
        graph = {"1": {"class_type": "UNETLoader", "inputs": {
            "unet_name": "qwen_image_edit_2511_fp8mixed.safetensors"}},
                 "2": {"class_type": "CLIPTextEncode", "inputs": {
                     "text": "a private prompt that must not reach the browser"}}}
        entry = [1, "id", graph, {"create_time": 1000}, ["2"]]
        sources = {
            "/queue": {"queue_running": [entry], "queue_pending": [entry, entry]},
            "/history?max_items=12": {"id": {"prompt": entry,
                "status": {"status_str": "success", "messages": [
                    ["execution_start", {"timestamp": 1000}],
                    ["execution_success", {"timestamp": 53500}]]}}},
        }
        def controller(_method, _path, timeout):
            return 200, {"models": [{"id": image_lab.MODEL_ID,
                                     "ownership": "managed", "runtime": "running",
                                     "healthy": True}]}
        result = image_lab.snapshot(controller, "http://127.0.0.1:8188",
                                    lambda _base, path: sources[path])
        self.assertEqual(result["queue"], {"running": 1, "pending": 2,
                                            "running_model": "qwen_image_edit_2511_fp8mixed.safetensors"})
        self.assertEqual(result["history"]["last"]["duration_seconds"], 52.5)
        self.assertEqual(result["history"]["successful"], 1)
        self.assertNotIn("private prompt", str(result))

    def test_one_unavailable_source_does_not_hide_controller_or_queue(self):
        def controller(_method, _path, timeout):
            return 200, {"models": [{"id": image_lab.MODEL_ID,
                                     "ownership": "managed", "runtime": "running"}]}
        def get_json(_base, path):
            if path.startswith("/history"):
                raise OSError("history unavailable")
            return {"queue_running": [], "queue_pending": []}
        result = image_lab.snapshot(controller, "http://127.0.0.1:8188", get_json)
        self.assertEqual(result["queue"]["running"], 0)
        self.assertIsNone(result["history"])
        self.assertIn("history unavailable", result["history_error"])


if __name__ == "__main__":
    unittest.main()
