#!/usr/bin/env python3
"""Verify frozen audio/source provenance; keep acoustic and intent reviews explicit."""

import argparse
import hashlib
import io
import json
from pathlib import Path
import wave

import numpy as np
import pyarrow.parquet as parquet
import soundfile


def pcm(data):
    with wave.open(data, "rb") as audio:
        if (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) != (16000, 1, 2):
            raise ValueError("Expected canonical 16 kHz mono PCM16")
        return audio.readframes(audio.getnframes())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", type=Path, required=True)
    parser.add_argument("--public-parquet", type=Path, required=True)
    parser.add_argument("--public-source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError("Preserve the previous audit; choose a new output")
    suite = json.loads(args.suite.read_text())
    source = json.loads(args.public_source.read_text())
    published = {row["id"]: row for row in parquet.read_table(args.public_parquet).to_pylist()}
    result = {"suiteSHA256": hashlib.sha256(args.suite.read_bytes()).hexdigest(),
              "publicSource": source, "publicParquetSHA256": hashlib.sha256(args.public_parquet.read_bytes()).hexdigest(),
              "cases": [], "adoption": "not evaluated by provenance audit"}
    used = set()
    for case in suite["cases"]:
        path = args.suite.parent / case["audio"]
        frame_bytes = pcm(str(path))
        duration = len(frame_bytes) / 32000
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        row = {"id": case["id"], "kind": case["kind"], "durationSeconds": duration,
               "audioSHA256": digest, "matchesRecordedHash": digest == case.get("sha256"),
               "durationMatches": abs(duration - case["durationSeconds"]) < 1 / 16000,
               "verbatimReferenceField": "verbatimReference" if "verbatimReference" in case else "reference",
               "finalReferenceReview": "pending independent intent review"}
        if case.get("sourceClipIDs"):
            identifiers = case["sourceClipIDs"]
            expected_text = " ".join(published[key]["text"] for key in identifiers)
            chunks = []
            for index, key in enumerate(identifiers):
                used.add(key)
                samples, rate = soundfile.read(io.BytesIO(published[key]["audio"]["bytes"]), dtype="float32")
                if rate != 16000 or samples.ndim != 1:
                    raise ValueError("Unexpected public source audio format")
                if index:
                    chunks.append(np.zeros(6400, dtype="float32"))
                chunks.append(samples)
            reconstructed = io.BytesIO()
            soundfile.write(reconstructed, np.concatenate(chunks), 16000, format="WAV", subtype="PCM_16")
            reconstructed.seek(0)
            row.update(referenceMatchesPublished=expected_text == case.get("verbatimReference", case.get("reference")),
                       audioMatchesPublished=frame_bytes == pcm(reconstructed))
            row["verbatimReferenceReview"] = "source-verified" if row["referenceMatchesPublished"] and row["audioMatchesPublished"] else "failed"
            if row["verbatimReferenceReview"] == "source-verified" and case.get("finalIntentReference") == expected_text:
                row["finalReferenceReview"] = "source-verified"
        elif case["kind"] == "local-Tingting-TTS":
            original = path.with_suffix(".txt")
            row["matchesSynthesisInput"] = original.read_text() == case["reference"]
            row["verbatimReferenceReview"] = "pending human acoustic review; synthesis input is not audio ground truth"
        else:
            row["verbatimReferenceReview"] = "requires provenance review"
        result["cases"].append(row)
    result["distinctPublicSourceClips"] = len(used)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"cases": len(result["cases"]), "sourceVerified": sum(r["verbatimReferenceReview"] == "source-verified" for r in result["cases"]),
                      "audioHashMismatches": sum(not r["matchesRecordedHash"] for r in result["cases"]),
                      "distinctPublicSourceClips": len(used)}))


if __name__ == "__main__":
    main()
