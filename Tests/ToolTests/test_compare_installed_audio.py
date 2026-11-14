import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "compare_audio", Path(__file__).resolve().parents[2] / "scripts/compare_installed_audio.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def journal():
    return dict(outcome="recording", appBundleIdentifier="com.apple.TextEdit",
                attempts=[dict(id="attempt", outcome="recording", snapshot=dict(provider="doubaoIME"))])


class RecordingReadinessTests(unittest.TestCase):
    def test_prepare_pulses_cannot_start_or_end_playback(self):
        gate = module.PlaybackGate()
        gate.start()
        # A reservation, then the active journal, can precede the actual PCM.
        for record, frames in [(dict(outcome="recording"), 0), (journal(), 0), (journal(), 0)]:
            self.assertFalse(gate.claim(module.recording_ready(record, frames, "doubaoIME"), True))
            self.assertFalse(gate.stopped)
        self.assertTrue(gate.claim(True, True))
        self.assertFalse(gate.claim(True, True))
        self.assertFalse(gate.stopped)

    def test_physical_start_snapshot_and_frames_are_all_required(self):
        gate = module.PlaybackGate()
        self.assertFalse(gate.claim(True, True))
        gate.start()
        d = journal()
        self.assertFalse(module.recording_ready(d, 0, "doubaoIME"))
        self.assertFalse(gate.claim(True, False))
        self.assertFalse(module.recording_ready(dict(outcome="recording"), 20, "doubaoIME"))
        self.assertFalse(module.recording_ready(d, 20, "chatGPTManagedAuth"))
        self.assertTrue(module.recording_ready(d, 20, "doubaoIME"))

    def test_early_stop_or_cancel_never_launches_a_late_source(self):
        for ready in [False, True]:
            gate = module.PlaybackGate(); gate.start(); gate.stop()
            self.assertFalse(gate.claim(ready, True))
            self.assertFalse(gate.valid_stop)

    def test_only_completed_source_followed_by_stop_is_valid(self):
        gate = module.PlaybackGate(); gate.start()
        self.assertTrue(gate.claim(True, True))
        self.assertFalse(gate.valid_stop)
        gate.source_complete = True
        self.assertFalse(gate.valid_stop)
        gate.stop()
        self.assertTrue(gate.valid_stop)

    def test_terminal_journal_or_different_target_is_not_ready(self):
        for outcome in ["cancelled", "error", "processing", "recorded"]:
            d = journal(); d["outcome"] = outcome
            self.assertFalse(module.recording_ready(d, 20, "doubaoIME"))
        d = journal(); d["appBundleIdentifier"] = "other.app"
        self.assertFalse(module.recording_ready(d, 20, "doubaoIME"))

    def test_preallocated_pcm_without_capture_progress_is_not_ready(self):
        gate = module.PlaybackGate(); gate.start()
        for count in [0, 2048, 2048, 2048]:
            self.assertFalse(gate.observe_capture(journal(), count, "doubaoIME"))
        self.assertTrue(gate.observe_capture(journal(), 2368, "doubaoIME"))

    def test_wav_uses_captured_frames_not_placeholder_lengths_or_headers(self):
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory) / "growing.wav"
            fmt = struct.pack("<HHIIHH", 1, 1, 16000, 32000, 2, 16)
            header = b"RIFF" + struct.pack("<I", 0) + b"WAVE"
            header += b"fmt " + struct.pack("<I", 16) + fmt
            header += b"JUNK" + struct.pack("<I", 3) + b"abc\0"
            header += b"data" + struct.pack("<I", 0)
            p.write_bytes(header)
            self.assertEqual(module.pcm_frames(p), 0)
            p.write_bytes(header + b"\1")
            self.assertEqual(module.pcm_frames(p), 0)
            p.write_bytes(header + b"\1\2")
            self.assertEqual(module.pcm_frames(p), 1)
            self.assertEqual(p.read_bytes(), header + b"\1\2")
            p.write_bytes(b"truncated")
            self.assertEqual(module.pcm_frames(p), 0)


if __name__ == "__main__":
    unittest.main()
