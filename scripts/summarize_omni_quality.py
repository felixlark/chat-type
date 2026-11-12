#!/usr/bin/env python3
"""Report file quality, complete denominators and explicit critical-term failures.

Token normalization follows Voxt's character/word scoring convention
(sgl-project/sglang-omni, Voxt/internal/eval/score.go, Apache-2.0).
"""

import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import re
import unicodedata

CHINESE_DIGITS = dict(zip("零〇一二两三四五六七八九", [0, 0, 1, 2, 2, 3, 4, 5, 6, 7, 8, 9]))
CHINESE_UNITS = {"十": 10, "百": 100, "千": 1000, "万": 10000}
ENGLISH_NUMBERS = dict(zip("zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split(), range(20)))
ENGLISH_NUMBERS.update(dict(zip("twenty thirty forty fifty sixty seventy eighty ninety hundred thousand".split(), [20, 30, 40, 50, 60, 70, 80, 90, 100, 1000])))


def chinese_number(match):
    text = match.group()
    if not any(value in CHINESE_UNITS for value in text):
        return "".join(str(CHINESE_DIGITS[value]) for value in text)
    total = section = digit = 0
    for value in text:
        unit = CHINESE_UNITS.get(value, 0)
        if unit == 10000:
            total += (section + digit) * unit
            section = digit = 0
        elif unit:
            section += (digit or 1) * unit
            digit = 0
        else:
            digit = CHINESE_DIGITS[value]
    return str(total + section + digit)


def normalize(text):
    text = unicodedata.normalize("NFKC", text).casefold().replace("’", "'")
    text = re.sub(r"(?<=\d),(?=\d{3}(?:\D|$))", "", text)
    return re.sub(r"[零〇一二两三四五六七八九十百千万]+", chinese_number, text)


def tokens(text):
    values = re.findall(r"[\u3400-\u9fff]|[a-z]+(?:'[a-z]+)?|[0-9]+", normalize(text))
    output = []
    index = 0
    fillers = {"嗯", "呃", "额", "啊", "唔", "um", "uh", "er", "erm", "ah", "hmm", "percent"}
    while index < len(values):
        word = values[index]
        if word in fillers:
            index += 1
            continue
        if word not in ENGLISH_NUMBERS:
            output.append(word)
            index += 1
            continue
        total = section = 0
        while index < len(values) and values[index] in ENGLISH_NUMBERS:
            number = ENGLISH_NUMBERS[values[index]]
            if number == 100:
                section = (section or 1) * 100
            elif number == 1000:
                total += (section or 1) * 1000
                section = 0
            else:
                section += number
            index += 1
            if index + 1 < len(values) and values[index] == "and" and values[index + 1] in ENGLISH_NUMBERS:
                index += 1
        output.append(str(total + section))
    return output


def alignment(reference, hypothesis):
    matrix = [list(range(len(hypothesis) + 1))]
    for index, expected in enumerate(reference, 1):
        row = [index]
        for column, actual in enumerate(hypothesis, 1):
            row.append(min(row[-1] + 1, matrix[-1][column] + 1, matrix[-1][column - 1] + (expected != actual)))
        matrix.append(row)
    substitution = deletion = insertion = 0
    i, j = len(reference), len(hypothesis)
    while i or j:
        if i and j and reference[i - 1] == hypothesis[j - 1] and matrix[i][j] == matrix[i - 1][j - 1]:
            i, j = i - 1, j - 1
        elif i and j and matrix[i][j] == matrix[i - 1][j - 1] + 1:
            substitution += 1
            i, j = i - 1, j - 1
        elif i and matrix[i][j] == matrix[i - 1][j] + 1:
            deletion += 1
            i -= 1
        else:
            insertion += 1
            j -= 1
    return substitution, deletion, insertion


def stage_summary(fixtures, successes, stage):
    totals = defaultdict(lambda: [0, 0, 0, 0, 0])
    language_totals = defaultdict(lambda: [0, 0, 0, 0, 0])
    missing_text, missing_reference, unapproved_reference, clause_failures, misses = [], [], [], [], []
    no_speech = {"samples": 0, "passed": 0, "failures": []}
    for (identifier, run), row in successes.items():
        key = {"case": identifier, "run": run}
        case = fixtures[identifier]
        text = row.get("rawText", row.get("text")) if stage == "raw" else row.get("finalText")
        expects_silence = case.get("expectedOutcome") == "no-speech"
        if not isinstance(text, str) or (not text.strip() and not expects_silence):
            missing_text.append(key)
            continue
        reference_text = case.get("verbatimReference", case.get("reference")) if stage == "raw" else case.get("finalIntentReference")
        if not isinstance(reference_text, str) or (not reference_text.strip() and not expects_silence):
            missing_reference.append(key)
            continue
        review = case.get("referenceAudit", {}).get(stage, "unreviewed")
        if review not in {"source-verified", "user-confirmed", "human-audited"}:
            unapproved_reference.append({**key, "review": review})
        if expects_silence:
            no_speech["samples"] += 1
            coverage = row.get("audioCoverage") or {}
            frames = case.get("frameCount")
            reasons = []
            if reference_text.strip():
                reasons.append("no-speech reference must be empty")
            if text.strip():
                reasons.append("unexpected text on no-speech input")
            if row.get("transcriptionCompleted") is not True:
                reasons.append("transcription completion not proved")
            if (type(frames) is not int or frames <= 0
                    or coverage.get("inputFrames") != frames or coverage.get("coveredFrames") != frames):
                reasons.append("complete source frame coverage not proved")
            if reasons:
                no_speech["failures"].append({**key, "reasons": reasons})
            else:
                no_speech["passed"] += 1
            continue
        reference, hypothesis = tokens(reference_text), tokens(text)
        edits = alignment(reference, hypothesis)
        for group in {"all", case.get("layer", "screening"), case["kind"]}:
            values = totals[group]
            for index, value in enumerate((len(reference), *edits, 1)):
                values[index] += value
        language = case.get("language", "unspecified")
        if language == "zh":
            reference, hypothesis = list("".join(reference)), list("".join(hypothesis))
        values = language_totals[(language, case.get("layer", "screening"))]
        for index, value in enumerate((len(reference), *alignment(reference, hypothesis), 1)):
            values[index] += value
        literal_specs = ([{"text": term, "count": reference_text.count(term)} for term in case.get("rawCriticalTerms", [])]
                         if stage == "raw" else case.get("exactFinalLiterals", []))
        for literal in literal_specs:
            term, expected = literal["text"], literal.get("count", 1)
            compared = text if literal.get("caseSensitive", True) else text.casefold()
            actual = compared.count(term if literal.get("caseSensitive", True) else term.casefold())
            if actual != expected:
                misses.append({**key, "term": term, "expected": expected, "actual": actual})
        if stage == "final":
            flattened = "".join(tokens(text))
            for clause in case.get("requiredFinalClauses", []):
                contains = lambda phrase: "".join(tokens(phrase)) in flattened
                if (not all(contains(value) for value in clause.get("allOf", []))
                        or (clause.get("anyOf") and not any(contains(value) for value in clause["anyOf"]))):
                    clause_failures.append({**key, "clause": clause["id"], "reason": "required clause missing"})
            for decision in case.get("forbiddenFinalDecisions", []):
                if "".join(tokens(decision)) in flattened:
                    clause_failures.append({**key, "decision": decision, "reason": "superseded decision retained"})

    def metric(values, name):
        n, substitution, deletion, insertion, count = values
        return {"referenceTokens": n, "substitutions": substitution, "deletions": deletion,
                "insertions": insertion, "samples": count, name: 100 * (substitution + deletion + insertion) / max(n, 1)}

    return {"metrics": {key: metric(value, "mixedTokenErrorPercent") for key, value in totals.items()},
            "languageDurationMetrics": [{"language": language, "layer": layer,
                **metric(value, "characterErrorPercent" if language == "zh" else "wordErrorPercent" if language == "en" else "mixedTokenErrorPercent")}
                for (language, layer), value in sorted(language_totals.items())],
            "missingStageText": missing_text, "missingStageReference": missing_reference,
            "unapprovedReferences": unapproved_reference, "criticalTermMisses": misses,
            "clauseFailures": clause_failures,
            "noSpeech": no_speech,
            "polishFallbacks": sum(bool(row.get("polishFallback")) for row in successes.values()) if stage == "final" else None}


def summarize(suite, rows, rounds):
    fixtures = {case["id"]: case for case in suite["cases"]}
    successes = {}
    duplicate_successes = []
    for row in rows:
        if row.get("status") == "success":
            key = row["case"], row["run"]
            if key in successes:
                duplicate_successes.append({"case": key[0], "run": key[1]})
            successes.setdefault(key, row)
    expected = {(identifier, run) for identifier in fixtures for run in range(1, rounds + 1)}
    return {"attempts": len(rows), "failedAttempts": sum(row.get("status") != "success" for row in rows),
            "uniqueSuccesses": len(successes), "expectedSuccesses": len(expected),
            "missingSuccessfulResults": [{"case": key[0], "run": key[1]} for key in sorted(expected - successes.keys())],
            "duplicateSuccesses": duplicate_successes,
            "stages": {stage: stage_summary(fixtures, successes, stage) for stage in ("raw", "final")},
            "adoption": "requires reference approval, semantic review, coverage and installed-path gates"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", type=Path, required=True)
    parser.add_argument("--result", action="append", required=True, help="LABEL=JSONL_PATH; repeat to combine attempts without overwriting")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=3)
    arguments = parser.parse_args()
    suite = json.loads(arguments.suite.read_text())
    fixtures = {case["id"]: case for case in suite["cases"]}
    groups = defaultdict(list)
    sources = []
    unformed_inputs = []
    for item in arguments.result:
        label, path = item.split("=", 1)
        source = {"label": label, "file": path, "readRows": 0, "acceptedRows": 0}
        for line in Path(path).read_text().splitlines():
            row = json.loads(line)
            source["readRows"] += 1
            if row["case"] in fixtures:
                groups[(label, row["model"])].append(row)
                source["acceptedRows"] += 1
        source["status"] = "records-formed" if source["acceptedRows"] else "no-candidate-results"
        sources.append(source)
        if not source["acceptedRows"]:
            unformed_inputs.append({"label": label, "file": path, "model": None,
                "status": "no-candidate-results", "expectedCaseRuns": len(fixtures) * arguments.rounds,
                "missingSuccessfulResults": [{"case": identifier, "run": run}
                    for identifier in sorted(fixtures) for run in range(1, arguments.rounds + 1)]})
    report = {"scope": "file quality and postprocess replay; no installed stop-to-insert claim",
              "suiteSHA256": hashlib.sha256(arguments.suite.read_bytes()).hexdigest(),
              "sources": sources, "unformedInputs": unformed_inputs, "groups": []}
    for (label, model), rows in groups.items():
        group = {"label": label, "model": model, **summarize(suite, rows, arguments.rounds)}
        report["groups"].append(group)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    if arguments.output.exists():
        raise FileExistsError("Choose a new report path to preserve prior evidence")
    arguments.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    for group in report["groups"]:
        print(json.dumps({"label": group["label"], "model": group["model"], "successes": group["uniqueSuccesses"], "attempts": group["attempts"], "finalMetric": group["stages"]["final"]["metrics"].get("all"), "finalCriticalMisses": len(group["stages"]["final"]["criticalTermMisses"])}))


if __name__ == "__main__":
    main()
