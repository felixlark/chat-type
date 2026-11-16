#!/usr/bin/env python3
"""Preserve explicitly enrolled local shortcuts during app installation."""

import json
import os
from pathlib import Path
import tempfile


FN_TAP_RULE = "ChatType local keyboard: Fn tap activates ChatType"
RETIRED_FN_RULE = "ChatType local keyboard: Fn tap ChatGPT, hold Doubao"


def apply_fn_tap(profile, binding):
    tap = binding.get("fnTap")
    if tap is None:
        return
    tap_ms = tap["timeoutMilliseconds"]
    if not isinstance(tap_ms, int) or isinstance(tap_ms, bool) or tap_ms <= 0:
        raise ValueError("Fn tap timeout must be a positive number of milliseconds")
    # Pass native Fn down/up through immediately. Only a short solitary tap
    # adds F18, the enrolled physical F5/ChatType activation event. Doubao owns
    # held-Fn behavior; do not delay Fn or add to_if_held_down.
    # https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/to-if-alone/
    rule = {"description": FN_TAP_RULE, "manipulators": [{
        "type": "basic",
        "from": {"key_code": "fn", "modifiers": {"optional": ["caps_lock"]}},
        "to": [{"key_code": "fn"}],
        "to_if_alone": [{"key_code": "f18"}],
        "parameters": {
            "basic.to_if_alone_timeout_milliseconds": tap_ms,
        },
    }]}
    rules = profile.setdefault("complex_modifications", {}).setdefault("rules", [])
    rules[:] = [existing for existing in rules if existing.get("description") not in (FN_TAP_RULE, RETIRED_FN_RULE)]
    rules.insert(0, rule)


def write_changed(path, value):
    if path.exists() and json.loads(path.read_text()) == value:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".")
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=4)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def preserve(home):
    directory = home / "Library/Application Support/ChatType"
    pin = directory / "keyboard-binding.json"
    if not pin.exists():
        return False  # Other users retain their own keyboard choices.
    binding = json.loads(pin.read_text())
    if binding.get("policy") != "doubao-fn-chattype-f5" or binding.get("version") != 1:
        raise ValueError("Unsupported local keyboard binding; keep the saved policy intact")

    karabiner_path = home / ".config/karabiner/karabiner.json"
    karabiner = json.loads(karabiner_path.read_text())
    profile = next(p for p in karabiner["profiles"] if p["name"] == binding["karabinerProfile"])
    apply_fn_tap(profile, binding)
    mappings = profile.setdefault("fn_function_keys", [])
    mappings[:] = [m for m in mappings if m.get("from", {}).get("key_code") != "f5"]
    mappings.append({"from": {"key_code": "f5"}, "to": [{"key_code": "f18"}]})
    # The old launcher alias must not intercept the physical F5 path.
    for rule in profile.get("complex_modifications", {}).get("rules", []):
        rule["manipulators"] = [
            m for m in rule["manipulators"]
            if not (m.get("from", {}).get("key_code") == "f5"
                    and any("Codex Plus.app" in event.get("shell_command", "")
                            for event in m.get("to", [])))
        ]

    config_path = directory / "config.json"
    if config_path.exists():
        config = json.loads(config_path.read_text())
    else:
        # Match fresh-install provider choices; a partial legacy JSON would use ChatGPT.
        config = {"transcription": {"provider": "doubaoIME", "textPolish": {"provider": "doubaoIME"}}}
    transcription = config.setdefault("transcription", {})
    if not transcription.get("hotkeyIsCustomized", False):
        transcription["hotkeyKeyCode"] = 79  # F18, from physical F5.
    write_changed(karabiner_path, karabiner)
    write_changed(config_path, config)
    return True


if __name__ == "__main__":
    if preserve(Path.home()):
        print("Preserved enrolled local keyboard mappings and saved custom ChatType shortcut")
