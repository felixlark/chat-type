import importlib.util
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("install_app", SCRIPTS / "install_app.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
sys.path.pop(0)


class FakeSystem:
    """Synthetic bundles/processes only; never execute a native tool or app."""
    def __init__(self, target):
        self.target = target
        self.running = True
        self.calls = []
        self.fail_diagnostic = False
        self.fail_normal_once = False
        self.refuse_stop = False
        self.adhoc_candidate = False

    def run(self, args, *, check=True):
        args = [str(arg) for arg in args]
        self.calls.append(args)
        output = ""
        if args[0] == "/usr/bin/codesign":
            if "-r-" in args:
                output = 'designated => identifier "example.ChatType"\n'
            adhoc = self.adhoc_candidate and (Path(args[-1]) / "Contents/MacOS/ChatType").read_text() == "candidate"
            if "-dv" in args and adhoc:
                output = "Signature=adhoc\n"
            for arg in args:
                if arg.startswith("--extract-certificates="):
                    if not adhoc:
                        Path(arg.split("=", 1)[1] + "0").write_bytes(b"synthetic signing certificate")
        elif args[0] == "/usr/bin/ditto":
            shutil.copytree(args[1], args[2])
        elif args[0] == "/usr/bin/pgrep":
            output = "101\n999\n" if self.running else "999\n"
        elif args[0] == "/bin/ps":
            output = str(self.target / "Contents/MacOS/ChatType") if args[2] == "101" else "/elsewhere/ChatType"
        elif args[0] == "/bin/kill":
            if args[-1] != "101":
                raise AssertionError("Attempted to stop a different app path")
            if not self.refuse_stop:
                self.running = False
        elif args[0] == "/usr/bin/open":
            if "-n" in args:
                if self.fail_diagnostic:
                    raise RuntimeError("Synthetic diagnostic launch failure")
                output_path = Path(args[-1])
                report = {"schemaVersion": 1, "appVersion": "1.0", "appBuild": "1", "results": [
                    {"service": key, "state": "notFound", "osStatus": -25300}
                    for key in ("chatGPTSession", "doubao", "glm", "qwen", "markpipe")]}
                output_path.write_text(json.dumps(report))
                output_path.chmod(0o600)
        elif args[0] == "/usr/bin/swift" and args[1].endswith("/scripts/launch_installed_app.swift"):
            if self.fail_normal_once:
                self.fail_normal_once = False
                raise RuntimeError("Synthetic normal launch failure")
            self.running = True
            output = json.dumps({"pid": 101, "path": str(self.target)})
        elif args[0] not in ("/usr/bin/xattr", "/usr/bin/env"):
            raise AssertionError(f"Unexpected native command: {args[0]}")
        return subprocess.CompletedProcess(args, 0, stdout=output, stderr="")


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source/ChatType.app"
        self.target = self.root / "Applications/ChatType.app"
        for app, marker in ((self.source, "candidate"), (self.target, "original")):
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/MacOS/ChatType").write_text(marker)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "example.ChatType", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"}))
        self.private = self.root / "private"
        self.private.mkdir(mode=0o700)
        self.output = self.private / "read-check.json"
        self.system = FakeSystem(self.target)

    def install(self):
        return MODULE.install(self.root, self.source, self.target, self.private / "backups",
                              self.output, run=self.system.run, sleep=lambda _: None)

    def marker(self):
        return (self.target / "Contents/MacOS/ChatType").read_text()

    def test_read_check_is_launchservices_only_then_normal_runtime_and_backup(self):
        backup = self.install()
        self.assertEqual(self.marker(), "candidate")
        self.assertTrue(self.system.running)
        self.assertEqual((backup / "ChatType.app/Contents/MacOS/ChatType").read_text(), "original")
        launches = [args for args in self.system.calls if args[0] == "/usr/bin/open"]
        self.assertEqual(launches[0], ["/usr/bin/open", "-n", "-g", "-W", "-a", str(self.target),
                                      "--args", "credential-read-check", "--output", str(self.output)])
        self.assertEqual(len(launches), 1)
        normal = [args for args in self.system.calls if args[0] == "/usr/bin/swift"]
        self.assertEqual(normal, [["/usr/bin/swift", str(self.root / "scripts/launch_installed_app.swift"), str(self.target)]])
        self.assertFalse(any(args[0].endswith("Contents/MacOS/ChatType") for args in self.system.calls))
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o600)

    def test_identity_mismatch_fails_before_stop_or_keyboard_changes(self):
        info = plistlib.loads((self.source / "Contents/Info.plist").read_bytes())
        info["CFBundleIdentifier"] = "example.Different"
        (self.source / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, "identity/signature differs"):
            self.install()
        self.assertEqual(self.marker(), "original")
        self.assertFalse(any(args[0] in ("/bin/kill", "/usr/bin/env", "/usr/bin/open") for args in self.system.calls))

    def test_diagnostic_failure_restores_original_and_normal_runtime(self):
        self.system.fail_diagnostic = True
        with self.assertRaisesRegex(RuntimeError, "diagnostic"):
            self.install()
        self.assertEqual(self.marker(), "original")
        self.assertTrue(self.system.running)
        self.assertFalse(list(self.target.parent.glob(".ChatType-install-*")))

    def test_normal_launch_failure_restores_original_and_relaunches_it(self):
        self.system.fail_normal_once = True
        with self.assertRaisesRegex(RuntimeError, "normal launch"):
            self.install()
        self.assertEqual(self.marker(), "original")
        self.assertTrue(self.system.running)

    def test_cleanup_failure_cannot_block_original_bundle_or_normal_runtime(self):
        self.system.fail_diagnostic = True
        original_rmtree = shutil.rmtree
        def fail_candidate_cleanup(path, *args, **kwargs):
            if Path(path).name.startswith(".ChatType-install-"):
                raise OSError("synthetic cleanup failure")
            return original_rmtree(path, *args, **kwargs)
        with mock.patch.object(MODULE.shutil, "rmtree", side_effect=fail_candidate_cleanup):
            with self.assertRaisesRegex(RuntimeError, "diagnostic"):
                self.install()
        self.assertEqual(self.marker(), "original")
        self.assertTrue(self.system.running)
        work = next(self.target.parent.glob(".ChatType-install-*"))
        self.assertTrue((work / "Rejected.app").is_dir())
        self.assertFalse((work / "Previous.app").exists())

    def test_refused_stop_never_replaces_original(self):
        self.system.refuse_stop = True
        def cancel_wait(_):
            raise InterruptedError("synthetic operator interruption")
        with self.assertRaisesRegex(InterruptedError, "operator interruption"):
            MODULE.install(self.root, self.source, self.target, self.private / "backups", self.output,
                           run=self.system.run, sleep=cancel_wait)
        self.assertEqual(self.marker(), "original")
        self.assertTrue(self.system.running)
        self.assertFalse(any("KILL" in arg for args in self.system.calls for arg in args))

    def test_existing_output_is_retained_before_native_actions(self):
        self.output.write_text("existing result")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.install()
        self.assertEqual(self.system.calls, [])
        self.assertEqual(self.output.read_text(), "existing result")

    def test_complete_profile_fields_and_certificate_are_checked_before_stop(self):
        identity = {"schemaVersion": 1, "bundleId": "example.ChatType",
                    "signingIdentity": hashlib.sha1(b"synthetic signing certificate").hexdigest().upper(),
                    "keychainServices": {"chatGPTSession": "Example.Session", "doubao": "example.speech",
                                         "glm": "EXAMPLE.GLM", "qwen": "Example.Qwen",
                                         "markpipe": "Example.Markpipe"}}
        info_path = self.source / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        from build_identity import inject_info
        info_path.write_bytes(plistlib.dumps(inject_info(info, identity)))
        wrong = dict(identity, signingIdentity="F0" * 20)
        with self.assertRaisesRegex(ValueError, "certificate differs"):
            MODULE.install(self.root, self.source, self.target, self.private / "backups", self.output,
                           run=self.system.run, sleep=lambda _: None, identity=wrong)
        self.assertFalse(any(args[0] in ("/bin/kill", "/usr/bin/env", "/usr/bin/open") for args in self.system.calls))
        self.system.calls.clear()
        info["ChatTypeGLMService"] = "wrong-case-or-domain"
        info_path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, "Packaged identity"):
            MODULE.install(self.root, self.source, self.target, self.private / "backups", self.output,
                           run=self.system.run, sleep=lambda _: None, identity=identity)
        self.assertFalse(any(args[0] == "/bin/kill" for args in self.system.calls))

    def test_main_forwards_the_same_explicit_profile_to_missing_package_and_install(self):
        profile = self.private / "synthetic-profile.json"
        identity = {"schemaVersion": 1, "bundleId": "example.ChatType", "signingIdentity": "A1" * 20,
                    "keychainServices": {"chatGPTSession": "Example.Session", "doubao": "example.speech",
                                         "glm": "EXAMPLE.GLM", "qwen": "Example.Qwen",
                                         "markpipe": "Example.Markpipe"}}
        profile.write_text(json.dumps(identity))
        missing = self.root / "not-packaged"
        with mock.patch.object(sys, "argv", ["install_app.py", "--identity-profile", str(profile)]), \
             mock.patch.dict(os.environ, {"CHATTYPE_DIST_PATH": str(missing)}), \
             mock.patch.object(MODULE, "command") as package, \
             mock.patch.object(MODULE, "install") as installer, \
             mock.patch.object(MODULE, "update_editor_package"):
            MODULE.main()
        self.assertEqual(package.call_args.args[0][-2:], ["--identity-profile", profile])
        self.assertEqual(installer.call_args.kwargs["identity"], identity)

    def test_explicit_fresh_adhoc_candidate_can_install_without_inventing_a_certificate(self):
        shutil.rmtree(self.target)
        self.system.running = False
        self.system.adhoc_candidate = True
        MODULE.install(self.root, self.source, self.target, self.private / "backups",
                       run=self.system.run, sleep=lambda _: None)
        self.assertEqual(self.marker(), "candidate")
        self.assertTrue(self.system.running)

    def test_adhoc_candidate_cannot_replace_existing_stable_certificate(self):
        self.system.adhoc_candidate = True
        with self.assertRaisesRegex(ValueError, "identity/signature differs"):
            self.install()
        self.assertEqual(self.marker(), "original")
        self.assertFalse(any(args[0] == "/bin/kill" for args in self.system.calls))


if __name__ == "__main__":
    unittest.main()
