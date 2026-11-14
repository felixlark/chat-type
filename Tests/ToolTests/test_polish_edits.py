import importlib.util
from pathlib import Path
import unittest
import json

spec = importlib.util.spec_from_file_location("evaluate_local_polish", Path(__file__).resolve().parents[2] / "scripts/evaluate_local_polish.py")
evaluation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluation)


class PolishEditPlacementTests(unittest.TestCase):
    def test_unicode_self_correction_preserves_other_scope(self):
        source = "📝先不发布，周五，不对，周六。"
        result, count = evaluation.apply_edit_patch(source, json.dumps([
            {"old": "周五，不对，周六", "new": "周六"}], ensure_ascii=False))
        self.assertEqual(result, "📝先不发布，周六。")
        self.assertEqual(count, 1)

    def test_ambiguous_missing_empty_and_overlapping_edits_are_rejected(self):
        for source, edits in [
            ("会话 会话", [{"old": "会话", "new": "session"}]),
            ("abc", [{"old": "missing", "new": "x"}]),
            ("abc", [{"old": "", "new": "x"}]),
            ("abc", [{"old": "abc", "new": "x"}, {"old": "bc", "new": "y"}]),
            ("abc", [{"old": "a", "new": "x", "execute": "never"}]),
        ]:
            with self.subTest(source=source, edits=edits), self.assertRaises(ValueError):
                evaluation.apply_edit_patch(source, json.dumps(edits))

    def test_replacements_do_not_recursively_rewrite_new_text(self):
        result, count = evaluation.apply_edit_patch("A B", '[{"old":"A","new":"B"},{"old":"B","new":"C"}]')
        self.assertEqual(result, "B C")
        self.assertEqual(count, 2)

    def test_overlapping_occurrences_are_ambiguous(self):
        with self.assertRaises(ValueError):
            evaluation.apply_edit_patch("aaa", '[{"old":"aa","new":"b"}]')

    def test_duplicate_json_keys_are_rejected(self):
        with self.assertRaises(ValueError):
            evaluation.apply_edit_patch("A B", '[{"old":"A","old":"B","new":"C"}]')

    def test_empty_edit_array_is_unchanged_text_not_proof_of_good_polish(self):
        self.assertEqual(evaluation.apply_edit_patch("保留原句", "[]"), ("保留原句", 0))

    def test_word_deletion_keeps_unicode_gaps_and_original_english(self):
        parts = ["📝", "周五", "，", "不对", "，", "周六", " full access", "。"]
        source = "".join(parts)
        self.assertEqual(evaluation.apply_deletion_ranges(source, parts, "[[1,4]]"),
                         ("📝周六 full access。", 1))
        self.assertEqual(evaluation.apply_deletion_ranges(source, parts, "[]"), (source, 0))

    def test_invalid_or_nonatomic_word_deletions_are_rejected(self):
        for serialized in ["{}", "[[true,1]]", "[[0.0,1]]", "[[1,0]]", "[[-1,0]]",
                           "[[0,3]]", "[[0,1],[1,2]]", "[[2,2],[0,0]]", "[[0,2]]", "[[0]]"]:
            with self.subTest(serialized=serialized), self.assertRaises(ValueError):
                evaluation.apply_deletion_ranges("甲乙丙", ["甲", "乙", "丙"], serialized)
        with self.assertRaises(ValueError):
            evaluation.apply_deletion_ranges("甲乙", ["甲", "丙"], "[]")


if __name__ == "__main__":
    unittest.main()
