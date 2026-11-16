#!/usr/bin/env python3
"""Install a signed ChatType candidate, optionally collect a private read check.

The operator must first establish that the installed app is idle. This script
does not infer recording/processing state from process existence.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from build_identity import check_info, resolve_profile


def command(args, *, check=True):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True)
    if check and result.returncode:
        raise RuntimeError(f"Install command failed: {Path(args[0]).name}")
    return result


def bundle_identity(app, run=command):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    result = run(["/usr/bin/codesign", "-d", "-r-", app])
    requirement = next(line for line in (result.stdout + "\n" + result.stderr).splitlines()
                       if line.startswith("designated => "))
    with tempfile.TemporaryDirectory(prefix="ChatType-install-cert-") as directory:
        prefix = Path(directory) / "cert"
        run(["/usr/bin/codesign", "-d", f"--extract-certificates={prefix}", app], check=False)
        leaf = Path(str(prefix) + "0")
        if leaf.is_file():
            certificate = hashlib.sha1(leaf.read_bytes()).hexdigest()
        else:
            details = run(["/usr/bin/codesign", "-dv", "--verbose=4", app])
            if "Signature=adhoc" not in (details.stdout + "\n" + details.stderr).splitlines():
                raise ValueError("Verified candidate has no signing certificate")
            # Preserve explicitly requested fresh ad-hoc development installs.
            # None never matches an existing stable certificate or a profile.
            certificate = None
    return info["CFBundleIdentifier"], requirement, certificate


def installed_pids(target, run=command):
    result = run(["/usr/bin/pgrep", "-x", "ChatType"], check=False)
    if result.returncode not in (0, 1):
        raise RuntimeError("Could not identify installed ChatType processes")
    executable = target / "Contents/MacOS/ChatType"
    pids = []
    for value in result.stdout.split():
        if not value.isdecimal():
            raise RuntimeError("Invalid installed process identifier")
        process = run(["/bin/ps", "-p", value, "-o", "comm="], check=False)
        if process.returncode == 0 and process.stdout.strip() == str(executable):
            pids.append(value)
    return pids


def stop_installed(target, run=command, sleep=time.sleep):
    for pid in installed_pids(target, run):
        run(["/bin/kill", "-TERM", pid])
    for _ in range(100):
        if not installed_pids(target, run):
            return
        sleep(0.1)
    raise RuntimeError("Installed ChatType did not stop; original installation retained")


def launch_normal(root, target, run=command):
    result = run(["/usr/bin/swift", root / "scripts/launch_installed_app.swift", target])
    receipt = json.loads(result.stdout)
    if type(receipt.get("pid")) is not int or receipt["pid"] <= 0 or receipt.get("path") != str(target):
        raise RuntimeError("Normal installed ChatType launch receipt mismatch")


def validate_output_destination(output):
    if not output.is_absolute():
        raise ValueError("Credential check output requires an absolute private path")
    parent = output.parent.resolve(strict=True)
    attributes = parent.stat()
    if not parent.is_dir() or attributes.st_uid != os.getuid() or stat.S_IMODE(attributes.st_mode) & 0o077:
        raise ValueError("Credential check output directory must be current-user private")
    if output.exists() or output.is_symlink():
        raise ValueError("Credential check output already exists; original result retained")


def validate_read_report(output, info):
    attributes = output.lstat()
    if not stat.S_ISREG(attributes.st_mode) or attributes.st_uid != os.getuid() or stat.S_IMODE(attributes.st_mode) != 0o600:
        raise ValueError("Credential check result is not a private regular file")
    report = json.loads(output.read_text())
    if set(report) != {"schemaVersion", "appVersion", "appBuild", "results"} or report["schemaVersion"] != 1:
        raise ValueError("Credential check report schema mismatch")
    if report["appVersion"] != info["CFBundleShortVersionString"] or report["appBuild"] != info["CFBundleVersion"]:
        raise ValueError("Credential check report version mismatch")
    results = report["results"]
    if not isinstance(results, list) or len(results) != 4:
        raise ValueError("Credential check report requires four logical services")
    if {entry.get("service") for entry in results} != {"chatGPTSession", "doubao", "glm", "qwen"}:
        raise ValueError("Credential check report logical services mismatch")
    for entry in results:
        if set(entry) != {"service", "state", "osStatus"} or type(entry["osStatus"]) is not int:
            raise ValueError("Credential check result fields mismatch")
        if (entry["state"], entry["osStatus"]) in (("readable", 0), ("notFound", -25300)):
            continue
        if entry["state"] != "OSStatus" or entry["osStatus"] in (0, -25300):
            raise ValueError("Credential check result status mismatch")
    return report


def install(root, source, target, backup_root, output=None, run=command, sleep=time.sleep, identity=None):
    if source.resolve() == target.resolve():
        raise ValueError("Install source cannot be the running app")
    if output is not None:
        validate_output_destination(output)
    candidate_identity = bundle_identity(source, run)
    info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    if identity is not None:
        check_info(info, identity)
        if identity["signingIdentity"] and (candidate_identity[2] or "").upper() != identity["signingIdentity"]:
            raise ValueError("Candidate certificate differs from explicit identity profile")
    had_installation = target.exists()
    original_identity = bundle_identity(target, run) if had_installation else None
    if had_installation and candidate_identity != original_identity:
        raise ValueError("Candidate identity/signature differs; original installation retained")
    backup_root.mkdir(parents=True, mode=0o700, exist_ok=True)
    backup = backup_root / uuid.uuid4().hex
    backup.mkdir(mode=0o700)
    if had_installation:
        run(["/usr/bin/ditto", target, backup / "ChatType.app"])
        if bundle_identity(backup / "ChatType.app", run) != original_identity:
            raise ValueError("Backup identity verification failed; original installation retained")
    work = Path(tempfile.mkdtemp(prefix=".ChatType-install-", dir=target.parent))
    staged, previous = work / "ChatType.app", work / "Previous.app"
    replaced = completed = False
    try:
        run(["/usr/bin/ditto", source, staged])
        run(["/usr/bin/xattr", "-cr", staged])
        if bundle_identity(staged, run) != candidate_identity:
            raise ValueError("Staged candidate identity mismatch")
        run(["/usr/bin/env", "python3", root / "scripts/preserve_local_keyboard.py"])
        stop_installed(target, run, sleep)
        if had_installation:
            os.replace(target, previous)
        try:
            os.replace(staged, target)
            replaced = True
        except BaseException:
            if had_installation:
                os.replace(previous, target)
            raise
        if bundle_identity(target, run) != candidate_identity:
            raise ValueError("Installed candidate identity mismatch")
        if output is not None:
            # -n keeps diagnostic arguments out of a normal existing instance.
            # The app exits this branch before NSApplication/AppDelegate.
            run(["/usr/bin/open", "-n", "-g", "-W", "-a", target, "--args",
                 "credential-read-check", "--output", output])
            validate_read_report(output, info)
        launch_normal(root, target, run)
        completed = True
    except BaseException:
        if replaced:
            stop_installed(target, run, sleep)
            # Restore by rename first. Recursive cleanup must never stand
            # between the original bundle and its normal running path.
            os.replace(target, work / "Rejected.app")
            if had_installation:
                os.replace(previous, target)
        if had_installation:
            launch_normal(root, target, run)
        raise
    finally:
        # Never delete the original if rollback itself failed.
        if completed or not previous.exists():
            try:
                shutil.rmtree(work)
            except OSError:
                print(f"Install cleanup deferred; retained {work}", file=sys.stderr)
    print(f"Installed {target}; normal app running; backup retained at {backup}")
    return backup


def update_editor_package(target):
    editor = Path("/Applications/Sublime Text.app")
    if editor.is_dir():
        package = Path.home() / "Library/Application Support/Sublime Text/Packages/ChatType"
        package.mkdir(parents=True, exist_ok=True)
        shutil.copy2(target / "Contents/Resources/Sublime/ChatType.py", package / "ChatType.py")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--credential-read-check", type=Path, metavar="PRIVATE_RESULT_JSON")
    parser.add_argument("--identity-profile", type=Path, default=os.environ.get("CHATTYPE_IDENTITY_PROFILE"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    identity = resolve_profile(args.identity_profile)
    source = Path(os.environ.get("CHATTYPE_DIST_PATH", root / "dist")) / "ChatType.app"
    if not source.is_dir():
        package = ["/bin/bash", root / "scripts/package_app.sh"]
        if args.identity_profile:
            package += ["--identity-profile", args.identity_profile]
        command(package)
    install(root, source, Path("/Applications/ChatType.app"),
            Path.home() / "Library/Caches/chat-type/install-backups", args.credential_read_check, identity=identity)
    update_editor_package(Path("/Applications/ChatType.app"))


if __name__ == "__main__":
    main()
