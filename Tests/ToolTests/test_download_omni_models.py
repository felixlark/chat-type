import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request

spec = importlib.util.spec_from_file_location("download_omni_models", Path(__file__).resolve().parents[2] / "scripts/download_omni_models.py")
downloader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(downloader)


class Response(io.BytesIO):
    status = 200


class ModelDownloadsTests(unittest.TestCase):
    def exercise(self, partial_bytes, responses):
        payload = b"pinned-model"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / "models/test/revision"
            directory.mkdir(parents=True)
            partial = directory / "model.partial"
            partial.write_bytes(partial_bytes)
            manifest = {"schemaVersion": 1, "source": "fixture", "models": [{"id": "test", "repo": "org/test", "revision": "revision", "files": [{"name": "model", "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}]}]}
            (root / "manifest.json").write_text(json.dumps(manifest))
            with patch("sys.argv", ["download", "--manifest", str(root / "manifest.json"), "--models-root", str(root / "models"), "--receipt", str(root / "receipt.json")]), patch.object(downloader.urllib.request, "build_opener") as factory:
                factory.return_value.open.side_effect = responses
                downloader.main()
                count = factory.return_value.open.call_count
            self.assertEqual((directory / "model").read_bytes(), payload)
            self.assertFalse(partial.exists())
            self.assertTrue((directory / "verified-manifest.json").exists())
            return count

    def test_completed_partial_is_verified_without_network(self):
        self.assertEqual(self.exercise(b"pinned-model", []), 0)

    def test_corrupt_complete_partial_downloads_fresh(self):
        self.assertEqual(self.exercise(b"broken-model", [Response(b"pinned-model")]), 1)

    def test_range_rejection_restarts_owned_partial(self):
        error = urllib.error.HTTPError("https://huggingface.co/model", 416, "range", {}, None)
        self.assertEqual(self.exercise(b"pinned", [error, Response(b"pinned-model")]), 2)

    def test_redirect_to_unapproved_host_is_rejected(self):
        with self.assertRaises(ValueError):
            downloader.PublicModelRedirects().redirect_request(urllib.request.Request("https://huggingface.co/model"), None, 302, "redirect", {}, "https://example.com/model")


if __name__ == "__main__":
    unittest.main()
