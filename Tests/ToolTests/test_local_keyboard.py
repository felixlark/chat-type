import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/preserve_local_keyboard.py"
SPEC = importlib.util.spec_from_file_location("local_keyboard", SCRIPT)
keyboard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(keyboard)


class LocalKeyboardTests(unittest.TestCase):
    def test_reinstall_restores_binding_without_resetting_other_settings(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            directory = home / "Library/Application Support/ChatType"
            directory.mkdir(parents=True)
            (directory / "keyboard-binding.json").write_text(json.dumps({
                "version": 1, "policy": "doubao-fn-chattype-f5", "karabinerProfile": "Default profile",
            }))
            config_path = directory / "config.json"
            original_config = {"transcription": {"hotkeyKeyCode": 96, "provider": "chatGPTManagedAuth", "hintTerms": ["keep"]}, "injection": {"preserveClipboard": True}}
            config_path.write_text(json.dumps(original_config))
            karabiner_path = home / ".config/karabiner/karabiner.json"
            karabiner_path.parent.mkdir(parents=True)
            f6 = {"from": {"key_code": "f6"}, "to": [{"key_code": "f6"}]}
            other_profile = {"name": "Other", "fn_function_keys": []}
            original_karabiner = {"profiles": [{"name": "Default profile", "selected": True, "fn_function_keys": [f6, {"from": {"key_code": "f5"}, "to": [{"key_code": "f5"}]}]}, other_profile]}
            karabiner_path.write_text(json.dumps(original_karabiner))

            self.assertTrue(keyboard.preserve(home))
            restored = json.loads(config_path.read_text())
            original_config["transcription"]["hotkeyKeyCode"] = 79
            self.assertEqual(restored, original_config)
            mappings = json.loads(karabiner_path.read_text())["profiles"]
            self.assertEqual(mappings[0]["fn_function_keys"], [f6, {"from": {"key_code": "f5"}, "to": [{"key_code": "f18"}]}])
            self.assertEqual(mappings[1], other_profile)
            before = (config_path.stat().st_mtime_ns, karabiner_path.stat().st_mtime_ns)
            keyboard.preserve(home)
            self.assertEqual(before, (config_path.stat().st_mtime_ns, karabiner_path.stat().st_mtime_ns))
            config_path.unlink()
            keyboard.preserve(home)
            fresh = json.loads(config_path.read_text())["transcription"]
            self.assertEqual(fresh["hotkeyKeyCode"], 79)
            self.assertEqual(fresh["provider"], "doubaoIME")

            fresh["hotkeyKeyCode"] = 40
            fresh["hotkeyModifiers"] = 768
            fresh["hotkeyIsCustomized"] = True
            config_path.write_text(json.dumps({"transcription": fresh}))
            keyboard.preserve(home)
            self.assertEqual(json.loads(config_path.read_text())["transcription"], fresh)

    def test_unenrolled_install_does_not_change_keyboard_preferences(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            self.assertFalse(keyboard.preserve(home))
            self.assertEqual(list(home.iterdir()), [])

    def test_opted_in_fn_tap_preserves_native_fn_and_is_idempotent(self):
        other_rule = {"description": "keep", "manipulators": []}
        profile = {"complex_modifications": {"rules": [other_rule, {"description": keyboard.RETIRED_FN_RULE}]}}
        binding = {"fnTap": {"timeoutMilliseconds": 300}}
        keyboard.apply_fn_tap(profile, binding)
        first = json.dumps(profile)
        keyboard.apply_fn_tap(profile, binding)
        self.assertEqual(json.dumps(profile), first)
        rules = profile["complex_modifications"]["rules"]
        self.assertEqual(rules[1], other_rule)
        rule = rules[0]["manipulators"][0]
        self.assertEqual(rule["to"], [{"key_code": "fn"}])
        self.assertNotIn("to_if_held_down", rule)
        self.assertEqual(rule["to_if_alone"], [{"key_code": "f18"}])
        self.assertEqual(set(rule["parameters"].values()), {300})
        keyboard.apply_fn_tap(profile, {})
        self.assertEqual(json.dumps(profile), first)
        binding["fnTap"]["timeoutMilliseconds"] = 200
        keyboard.apply_fn_tap(profile, binding)
        self.assertEqual(len(profile["complex_modifications"]["rules"]), 2)
        self.assertEqual(profile["complex_modifications"]["rules"][0]["manipulators"][0]["parameters"], {"basic.to_if_alone_timeout_milliseconds": 200})

    def test_invalid_fn_option_does_not_mutate_profile(self):
        profile = {"complex_modifications": {"rules": []}}
        for timeout in [0, -1, True, "300"]:
            with self.assertRaises(ValueError):
                keyboard.apply_fn_tap(profile, {"fnTap": {"timeoutMilliseconds": timeout}})
            self.assertEqual(profile, {"complex_modifications": {"rules": []}})
