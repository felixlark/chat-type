#!/usr/bin/env python3
"""Restore an explicitly enrolled local F5/Fn binding during app installation."""

import json
import os
from pathlib import Path
import tempfile


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
    config.setdefault("transcription", {})["hotkeyKeyCode"] = 79  # F18, from physical F5.
    write_changed(karabiner_path, karabiner)
    write_changed(config_path, config)
    return True


if __name__ == "__main__":
    if preserve(Path.home()):
        print("Preserved local keyboard binding: ChatType F5 (internal F18), Doubao Fn unchanged")
