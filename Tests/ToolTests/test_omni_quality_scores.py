import importlib.util
from pathlib import Path
import unittest
import contextlib
import io
import json
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("summarize_omni_quality", Path(__file__).resolve().parents[2] / "scripts/summarize_omni_quality.py")
scores = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scores)


class QualityScoreTests(unittest.TestCase):
    def test_numbers_compare_by_value(self):
        self.assertEqual(scores.tokens("预算三千五百元"), scores.tokens("预算3500元"))
        self.assertEqual(scores.tokens("three hundred and fifty"), scores.tokens("350"))

    def test_negation_and_scope_are_retained(self):
        self.assertEqual(scores.alignment(scores.tokens("只改设置页"), scores.tokens("改设置页")), (0, 1, 0))
        self.assertNotEqual(scores.tokens("先不要发布"), scores.tokens("先发布"))

    def test_literal_numeric_change_counts_as_error(self):
        self.assertNotEqual(scores.tokens("0.015"), scores.tokens("0.15"))

    def test_alignment_separates_substitution_deletion_and_insertion(self):
        self.assertEqual(scores.alignment(["a", "b", "c"], ["a", "x", "c", "d"]), (1, 0, 1))

    def test_final_uses_independent_intent_reference_after_self_correction(self):
        suite = {"cases": [{"id": "one", "kind": "controlled", "language": "zh", "layer": "short",
            "verbatimReference": "会议周二，不对，改周三", "finalIntentReference": "会议周三",
            "referenceAudit": {"raw": "human-audited", "final": "human-audited"},
            "forbiddenFinalDecisions": ["周二"]}]}
        report = scores.summarize(suite, [{"case": "one", "run": 1, "status": "success",
            "rawText": "会议周二，不对，改周三", "finalText": "会议周三"}], 1)
        self.assertEqual(report["stages"]["final"]["metrics"]["all"]["mixedTokenErrorPercent"], 0)
        self.assertEqual(report["stages"]["final"]["clauseFailures"], [])

    def test_failures_missing_rows_and_missing_final_remain_visible(self):
        suite = {"cases": [{"id": name, "kind": "controlled", "language": "en", "reference": "hello"}
                            for name in ["one", "two"]]}
        report = scores.summarize(suite, [{"case": "one", "run": 1, "status": "success", "text": "hello"},
            {"case": "one", "run": 2, "status": "failed"}], 2)
        self.assertEqual(report["expectedSuccesses"], 4)
        self.assertEqual(report["failedAttempts"], 1)
        self.assertEqual(len(report["missingSuccessfulResults"]), 3)
        self.assertEqual(report["stages"]["final"]["missingStageText"], [{"case": "one", "run": 1}])

    def test_final_never_falls_back_to_verbatim_reference(self):
        suite = {"cases": [{"id": "one", "kind": "controlled", "reference": "old words"}]}
        report = scores.summarize(suite, [{"case": "one", "run": 1, "status": "success",
            "rawText": "old words", "finalText": "new words"}], 1)
        self.assertEqual(report["stages"]["final"]["metrics"], {})
        self.assertEqual(report["stages"]["final"]["missingStageReference"], [{"case": "one", "run": 1}])

    def test_scope_requirements_and_final_literal_counts_are_independent_of_raw(self):
        suite = {"cases": [{"id": "one", "kind": "controlled", "language": "zh", "layer": "long",
            "verbatimReference": "SmartShadow SmartShadow 只改设置页", "finalIntentReference": "SmartShadow 只改设置页",
            "exactFinalLiterals": [{"text": "SmartShadow", "count": 1}],
            "requiredFinalClauses": [{"id": "settings-only", "anyOf": ["只改设置页", "仅修改设置页"]}]}]}
        report = scores.summarize(suite, [{"case": "one", "run": 1, "status": "success",
            "rawText": "SmartShadow SmartShadow 只改设置页", "finalText": "SmartShadow 改设置页"}], 1)
        final = report["stages"]["final"]
        self.assertEqual(final["criticalTermMisses"], [])
        self.assertEqual(final["clauseFailures"][0]["clause"], "settings-only")
        self.assertEqual(final["languageDurationMetrics"][0]["layer"], "long")
        self.assertIn("characterErrorPercent", final["languageDurationMetrics"][0])
        self.assertEqual(len(final["unapprovedReferences"]), 1)

    def test_empty_input_preserves_the_missing_candidate_denominator(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            suite = root / "suite.json"
            suite.write_text(json.dumps({"cases": [{"id": "one", "kind": "controlled", "reference": "hello"}]}))
            empty = root / "empty.jsonl"
            empty.write_text("")
            output = root / "report.json"
            with patch("sys.argv", ["score", "--suite", str(suite), "--result", f"candidate={empty}", "--output", str(output)]), contextlib.redirect_stdout(io.StringIO()):
                scores.main()
            report = json.loads(output.read_text())
            self.assertEqual(report["sources"][0]["status"], "no-candidate-results")
            self.assertEqual(report["sources"][0]["readRows"], 0)
            self.assertEqual(report["unformedInputs"][0]["expectedCaseRuns"], 3)
            self.assertEqual(len(report["unformedInputs"][0]["missingSuccessfulResults"]), 3)

    def test_explicit_silence_requires_empty_text_completed_request_and_all_frames(self):
        suite = {"cases": [{"id": "silence", "kind": "silence-boundary", "expectedOutcome": "no-speech",
            "frameCount": 32000, "verbatimReference": "", "finalIntentReference": "",
            "referenceAudit": {"raw": "source-verified", "final": "source-verified"}}]}
        valid = {"case": "silence", "run": 1, "status": "success", "rawText": "", "finalText": "",
            "transcriptionCompleted": True, "audioCoverage": {"inputFrames": 32000, "coveredFrames": 32000}}
        report = scores.summarize(suite, [valid], 1)
        for stage in report["stages"].values():
            self.assertEqual(stage["missingStageText"], [])
            self.assertEqual(stage["missingStageReference"], [])
            self.assertEqual(stage["metrics"], {})
            self.assertEqual(stage["noSpeech"], {"samples": 1, "passed": 1, "failures": []})
        for change in ({"rawText": "invented", "finalText": "invented"},
                       {"transcriptionCompleted": False},
                       {"audioCoverage": {"inputFrames": 32000, "coveredFrames": 16000}},
                       {"audioCoverage": {}}):
            with self.subTest(change=change):
                result = scores.summarize(suite, [{**valid, **change}], 1)
                self.assertEqual(result["stages"]["raw"]["noSpeech"]["passed"], 0)
                self.assertEqual(len(result["stages"]["raw"]["noSpeech"]["failures"]), 1)
        failed = scores.summarize(suite, [{**valid, "status": "failed"}], 1)
        self.assertEqual(failed["uniqueSuccesses"], 0)
        self.assertEqual(len(failed["missingSuccessfulResults"]), 1)

    def test_absent_text_is_not_silence(self):
        suite = {"cases": [{"id": "silence", "kind": "silence-boundary", "expectedOutcome": "no-speech",
            "frameCount": 32000, "verbatimReference": "", "finalIntentReference": ""}]}
        report = scores.summarize(suite, [{"case": "silence", "run": 1, "status": "success"}], 1)
        self.assertEqual(report["stages"]["raw"]["missingStageText"], [{"case": "silence", "run": 1}])
        self.assertEqual(report["stages"]["raw"]["noSpeech"]["passed"], 0)


if __name__ == "__main__":
    unittest.main()
