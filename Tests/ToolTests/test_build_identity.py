import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/build_identity.py"
SPEC = importlib.util.spec_from_file_location("build_identity_contract", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class BuildIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.profile = self.directory / "synthetic-profile.json"
        self.identity = {"schemaVersion": 1, "bundleId": "example.synthetic.ChatType",
                         "signingIdentity": "A1" * 20,
                         "keychainServices": {"chatGPTSession": "Example.Session.MixedCase", "doubao": "example.speech",
                                              "glm": "EXAMPLE.GLM", "qwen": "Example.Qwen",
                                              "markpipe": "Example.Markpipe"}}

    def write_profile(self, value):
        self.profile.write_text(json.dumps(value))
        return self.profile

    def test_public_defaults_and_synthetic_private_values_are_distinct(self):
        public = MODULE.resolve_profile()
        self.assertEqual(public["bundleId"], "io.github.felixlark.ChatType")
        self.assertEqual(public["keychainServices"]["chatGPTSession"], "io.github.felixlark.ChatType.chatgpt-session")
        self.assertEqual(public["keychainServices"]["markpipe"], "io.github.felixlark.ChatType.markpipe")
        private = MODULE.resolve_profile(self.write_profile(self.identity))
        self.assertEqual(private, self.identity)
        self.assertNotEqual(private, public)

    def test_partial_or_malformed_profiles_never_fall_back(self):
        cases = []
        for key in ("schemaVersion", "bundleId", "signingIdentity", "keychainServices"):
            value = copy.deepcopy(self.identity)
            del value[key]
            cases.append(value)
        for key in MODULE.SERVICE_FIELDS:
            value = copy.deepcopy(self.identity)
            del value["keychainServices"][key]
            cases.append(value)
        for bad in ("", "   ", None, 42):
            value = copy.deepcopy(self.identity)
            value["keychainServices"]["doubao"] = bad
            cases.append(value)
        for value in cases:
            with self.subTest(value=value), self.assertRaises(ValueError):
                MODULE.resolve_profile(self.write_profile(value))
        with self.assertRaisesRegex(ValueError, "absolute"):
            MODULE.resolve_profile(Path("relative-profile.json"))

    def test_injection_preserves_brand_and_exact_five_services(self):
        original = {"CFBundleName": "ChatType", "CFBundleDisplayName": "ChatType", "LSUIElement": True,
                    "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"}
        resolved = MODULE.resolve_profile(self.write_profile(self.identity))
        info = MODULE.inject_info(original, resolved)
        self.assertEqual({key: info[key] for key in original}, original)
        MODULE.check_info(info, resolved)
        for key, field in MODULE.SERVICE_FIELDS.items():
            self.assertEqual(info[field], self.identity["keychainServices"][key])
        info[MODULE.SERVICE_FIELDS["glm"]] = info[MODULE.SERVICE_FIELDS["glm"]].lower()
        with self.assertRaises(ValueError):
            MODULE.check_info(info, resolved)

    def test_cli_resolve_inject_check_has_no_profile_stdout(self):
        self.write_profile(self.identity)
        manifest = self.directory / "identity.json"
        result = subprocess.run(["python3", str(SCRIPT), "resolve", "--profile", str(self.profile),
                                 "--output", str(manifest)], capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout, "")
        self.assertEqual(manifest.stat().st_mode & 0o777, 0o600)
        plist = self.directory / "Info.plist"
        plist.write_bytes(plistlib.dumps({"CFBundleName": "ChatType"}))
        for action in ("inject", "check"):
            result = subprocess.run(["python3", str(SCRIPT), action, "--identity", str(manifest),
                                     "--plist", str(plist)], capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout, "")
        self.assertEqual(plistlib.loads(plist.read_bytes())["CFBundleIdentifier"], self.identity["bundleId"])

    def test_invalid_profile_cannot_replace_existing_package_or_start_compiler(self):
        self.write_profile({"schemaVersion": 1})
        dist = self.directory / "dist"
        dist.mkdir()
        sentinel = dist / "ChatType.app"
        sentinel.mkdir()
        (sentinel / "keep").write_text("existing candidate")
        binary_dir = self.directory / "bin"
        binary_dir.mkdir()
        compiler_marker = self.directory / "compiler-invoked"
        swift = binary_dir / "swift"
        swift.write_text('#!/bin/sh\ntouch "' + str(compiler_marker) + '"\nexit 99\n')
        swift.chmod(0o700)
        env = os.environ.copy()
        env.update({"CHATTYPE_DIST_PATH": str(dist), "PATH": str(binary_dir) + ":" + env["PATH"]})
        result = subprocess.run(["bash", str(SCRIPT.parent / "package_app.sh"), "--identity-profile", str(self.profile)],
                                capture_output=True, text=True, env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((sentinel / "keep").read_text(), "existing candidate")
        self.assertFalse(compiler_marker.exists())


if __name__ == "__main__":
    unittest.main()
