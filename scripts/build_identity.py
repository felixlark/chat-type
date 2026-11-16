#!/usr/bin/env python3
"""Resolve and verify ChatType's nonsecret package identity, never credentials."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re

DEFAULT_BUNDLE_ID = "io.github.felixlark.ChatType"
SERVICE_FIELDS = {
    "chatGPTSession": "ChatTypeChatGPTSessionService",
    "doubao": "ChatTypeDoubaoService",
    "glm": "ChatTypeGLMService",
    "qwen": "ChatTypeQwenService",
}
DEFAULT_SERVICES = dict(zip(SERVICE_FIELDS, (DEFAULT_BUNDLE_ID + "." + suffix
                       for suffix in ("chatgpt-session", "doubao", "glm", "qwen"))))


def nonempty(value):
    return isinstance(value, str) and bool(value.strip())


def resolve_profile(path=None):
    if path is None:
        return {"schemaVersion": 1, "bundleId": DEFAULT_BUNDLE_ID,
                "signingIdentity": "", "keychainServices": DEFAULT_SERVICES.copy()}
    path = Path(path)
    if not path.is_absolute():
        raise ValueError("Identity profile requires an absolute path")
    value = json.loads(path.read_text())
    if not isinstance(value, dict) or type(value.get("schemaVersion")) is not int or value["schemaVersion"] != 1:
        raise ValueError("Identity profile schemaVersion must be 1")
    if not nonempty(value.get("bundleId")) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", value["bundleId"]):
        raise ValueError("Identity profile bundleId is invalid")
    selector = value.get("signingIdentity")
    if not isinstance(selector, str) or not re.fullmatch(r"[A-Fa-f0-9]{40}", selector):
        raise ValueError("Identity profile requires a certificate SHA-1 selector")
    services = value.get("keychainServices")
    if not isinstance(services, dict) or any(not nonempty(services.get(key)) for key in SERVICE_FIELDS):
        raise ValueError("Identity profile requires all four nonempty service names")
    return {"schemaVersion": 1, "bundleId": value["bundleId"], "signingIdentity": selector.upper(),
            "keychainServices": {key: services[key] for key in SERVICE_FIELDS}}


def inject_info(info, identity):
    info = dict(info)
    info["CFBundleIdentifier"] = identity["bundleId"]
    for key, field in SERVICE_FIELDS.items():
        info[field] = identity["keychainServices"][key]
    return info


def check_info(info, identity):
    expected = inject_info({}, identity)
    if any(info.get(key) != value for key, value in expected.items()):
        raise ValueError("Packaged identity does not match the selected public/default or explicit profile")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("resolve", "inject", "check"))
    parser.add_argument("--profile", type=Path)
    parser.add_argument("--identity", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--plist", type=Path)
    args = parser.parse_args()
    identity = json.loads(args.identity.read_text()) if args.identity else resolve_profile(args.profile)
    if args.action == "resolve":
        if not args.output:
            parser.error("resolve requires --output")
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as file:
            json.dump(identity, file)
            file.write("\n")
    else:
        if not args.plist:
            parser.error("inject/check requires --plist")
        info = plistlib.loads(args.plist.read_bytes())
        if args.action == "inject":
            args.plist.write_bytes(plistlib.dumps(inject_info(info, identity)))
        else:
            check_info(info, identity)


if __name__ == "__main__":
    main()
