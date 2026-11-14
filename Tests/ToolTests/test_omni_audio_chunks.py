import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
import wave
import json
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("evaluate_omni", Path(__file__).resolve().parents[2] / "scripts/evaluate_omni.py")
evaluation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluation)


class AudioChunkTests(unittest.TestCase):
    def test_long_file_chunks_preserve_every_sample_in_order(self):
        source = b"\x10\x00" * (16000 * 80)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "long.wav"
            with wave.open(str(path), "wb") as audio:
                audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(source)
            restored = b""
            duration = 0
            for encoded, seconds in evaluation.wav_chunks(path):
                with wave.open(io.BytesIO(encoded)) as audio:
                    restored += audio.readframes(audio.getnframes())
                duration += seconds
            self.assertEqual(restored, source)
            self.assertEqual(duration, 80)

    def test_noncanonical_sample_rate_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "source.wav"
            with wave.open(str(path), "wb") as audio:
                audio.setparams((1, 2, 24000, 0, "NONE", "not compressed"))
                audio.writeframes(b"\0\0" * 24000)
            with self.assertRaises(ValueError):
                list(evaluation.wav_chunks(path))

    def test_truncated_wav_cannot_claim_full_recording_coverage(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "truncated.wav"
            with wave.open(str(path), "wb") as audio:
                audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(b"\0\0" * 32000)
            path.write_bytes(path.read_bytes()[:-100])
            with self.assertRaises(ValueError):
                list(evaluation.wav_chunks(path))

    def test_model_preparation_failures_preserve_each_case_and_model(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            models = [{"id": "qwen3-asr-a", "revision": "one"}, {"id": "qwen3-asr-b", "revision": "two"}]
            for model in models:
                directory = root / "models" / model["id"] / model["revision"]
                directory.mkdir(parents=True)
                (directory / "verified-manifest.json").write_text("{}")
            (root / "manifest.json").write_text(json.dumps({"models": models}))
            (root / "suite.json").write_text(json.dumps({"cases": [{"id": "case", "audio": "missing.wav", "kind": "synthetic", "durationSeconds": 1, "reference": "test"}]}))
            output = root / "result.jsonl"
            arguments = ["evaluate", "--suite", str(root / "suite.json"), "--runtime", str(root), "--manifest", str(root / "manifest.json"), "--models-root", str(root / "models"), "--output", str(output), "--rounds", "2"]
            with patch("sys.argv", arguments), patch.object(evaluation, "NativeSpeechServer", side_effect=RuntimeError("model preparation failed")):
                evaluation.main()
            rows = [json.loads(line) for line in output.read_text().splitlines()]
            self.assertEqual(len(rows), 4)
            self.assertTrue(all(row["status"] == "failed" and row["errorType"] == "RuntimeError" for row in rows))
            self.assertEqual({row["model"] for row in rows}, {"qwen3-asr-a", "qwen3-asr-b"})


if __name__ == "__main__":
    unittest.main()
