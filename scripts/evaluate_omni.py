#!/usr/bin/env python3
"""Measure pinned local ASR models against a frozen WAV/reference suite."""

import argparse
import contextlib
import io
import json
import math
import os
from pathlib import Path
import queue
import re
import secrets
import subprocess
import threading
import time
import unicodedata
import urllib.error
import urllib.request
import wave


class NativeSpeechServer:
    def __init__(self, binary: Path, model_directory: Path, model_id: str, log: Path, audio_layout: str = "voxt_swift"):
        self.audio_layout = audio_layout
        self.secret = secrets.token_hex(32)
        self.log = log.open("ab")
        self.process = subprocess.Popen(
            [str(binary), "--supervised", "--host", "127.0.0.1", "--port", "0",
             "--model-path", str(model_directory), "--model-name", model_id,
             "--model-kind", "qwen3_asr", "--cache-limit-mb", "512"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
        )
        self.process.stdin.write((json.dumps({"session_secret": self.secret}) + "\n").encode())
        self.process.stdin.flush()
        events = queue.Queue()

        def read_events():
            for line in self.process.stdout:
                try:
                    events.put(json.loads(line))
                except json.JSONDecodeError:
                    continue
            events.put({"event": "exited"})

        threading.Thread(target=read_events, daemon=True).start()
        try:
            ready = events.get(timeout=90)
            if ready.get("event") != "ready" or ready.get("host") != "127.0.0.1" or ready.get("server_pid") != self.process.pid:
                raise RuntimeError("Native model did not report a valid ready event")
            self.endpoint = f"http://127.0.0.1:{int(ready['port'])}"
            self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirects())
        except BaseException:
            self.close()
            raise

    def close(self):
        if self.process.poll() is None:
            with contextlib.suppress(BrokenPipeError, OSError):
                self.process.stdin.write(b'{"command":"shutdown"}\n')
                self.process.stdin.flush()
                self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.log.close()

    def transcribe(self, wav_bytes: bytes, language: str, hints: list[str], duration_seconds: float) -> str:
        boundary = "ChatType" + secrets.token_hex(12)
        fields = {"language": language, "prompt": "\n".join(hints), "audio_layout": self.audio_layout,
                  "max_new_tokens": str(min(8192, max(256, math.ceil(duration_seconds * 28) + 64))),
                  "stop_at_end_of_text": "true", "stop_on_token_loop": "true",
                  "stream": "true", "include_generation_metadata": "true"}
        body = bytearray()
        for name, value in fields.items():
            body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
        body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode())
        body.extend(wav_bytes)
        body.extend(f'\r\n--{boundary}--\r\n'.encode())
        request = urllib.request.Request(self.endpoint + "/v1/audio/transcriptions", data=body,
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}", "X-ChatType-Session": self.secret})
        result = None
        completed = False
        with self.opener.open(request, timeout=180) as response:
            for line in response:
                if not line.startswith(b"data:"):
                    continue
                value = line[5:].strip()
                if value == b"[DONE]":
                    completed = True
                    break
                event = json.loads(value)
                if "text" in event:
                    result = event
                if "error" in event:
                    raise RuntimeError("Native transcription returned an error")
        if not completed or result is None or result.get("finish_reason") == "length":
            raise RuntimeError("Native transcription ended without a complete result")
        return result["text"]


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        raise RuntimeError("Local ASR redirects are forbidden")


def wav_chunks(path: Path):
    with wave.open(str(path), "rb") as audio:
        if (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) != (16000, 1, 2):
            raise ValueError("Evaluation requires 16kHz mono PCM16 WAV")
        expected_frames = audio.getnframes()
        frames = audio.readframes(expected_frames)
        if len(frames) != expected_frames * 2:
            raise ValueError("Evaluation WAV is truncated")
    total = len(frames) // 2
    start = 0
    while start < total:
        end = min(total, start + 60 * 16000)
        if total - start > 65 * 16000:
            # Match the file policy's quiet cut; production live pieces have their own quality pass.
            best = None
            for at in range(end - 5 * 16000, end + 5 * 16000, 800):
                energy = sum(int.from_bytes(frames[p:p + 2], "little", signed=True) ** 2
                             for p in range(at * 2, (at + 1600) * 2, 2))
                if best is None or energy < best[0]:
                    best = (energy, at + 800)
            end = best[1]
        elif total - start <= 65 * 16000:
            end = total
        samples = frames[start * 2:end * 2]
        if len(samples) < 32000:
            samples += b"\0" * (32000 - len(samples))
        output = io.BytesIO()
        with wave.open(output, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(16000)
            wav.writeframes(samples)
        yield output.getvalue(), (end - start) / 16000
        start = end


def tokens(text: str) -> list[str]:
    return re.findall(r"[\u3400-\u9fff]|[a-z]+(?:'[a-z]+)?|[0-9]+", unicodedata.normalize("NFKC", text).lower())


def edit_count(reference: list[str], hypothesis: list[str]) -> int:
    previous = list(range(len(hypothesis) + 1))
    for index, expected in enumerate(reference, 1):
        current = [index]
        for column, actual in enumerate(hypothesis, 1):
            current.append(min(current[-1] + 1, previous[column] + 1, previous[column - 1] + (expected != actual)))
        previous = current
    return previous[-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, default=Path(__file__).resolve().parents[1] / "Sources/ChatType/Resources/Omni/models.json")
    parser.add_argument("--models-root", type=Path, default=Path.home() / "Library/Application Support/ChatType/Models")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--model", action="append")
    parser.add_argument("--case", action="append")
    parser.add_argument("--audio-layout", choices=["reference", "voxt_swift"], default="voxt_swift")
    arguments = parser.parse_args()
    suite = json.loads(arguments.suite.read_text())
    models = [model for model in json.loads(arguments.manifest.read_text())["models"]
              if model["id"].startswith("qwen3-asr") and (not arguments.model or model["id"] in arguments.model)]
    cases = [case for case in suite["cases"] if not arguments.case or case["id"] in arguments.case]
    os.umask(0o077)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    with arguments.output.open("a") as output:
        for run in range(1, arguments.rounds + 1):
            for case_index, case in enumerate(cases):
                for model in models if (run + case_index) % 2 else reversed(models):
                    directory = arguments.models_root / model["id"] / model["revision"]
                    if not (directory / "verified-manifest.json").exists():
                        raise RuntimeError("Download and verify the model before evaluating")
                    row = {"case": case["id"], "model": model["id"], "revision": model["revision"], "run": run, "mode": "file-raw-asr", "schedule": "per-file-paired", "audioLayout": arguments.audio_layout, "kind": case["kind"], "durationSeconds": case["durationSeconds"]}
                    server = None
                    try:
                        started = time.monotonic()
                        try:
                            server = NativeSpeechServer(arguments.runtime / "bin/qwen3_asr_server", directory, model["id"], arguments.output.with_suffix(".runtime.log"), arguments.audio_layout)
                            row["modelStartupMs"] = round((time.monotonic() - started) * 1000)
                            started = time.monotonic()
                            hints = case.get("hints", suite.get("hints", []))
                            if model["id"] == "qwen3-asr-0.6b-4bit":
                                hints = hints[:30]
                            audio_path = arguments.suite.parent / case["audio"]
                            with wave.open(str(audio_path), "rb") as audio:
                                input_frames = audio.getnframes()
                            row["audioCoverage"] = {"inputFrames": input_frames, "coveredFrames": 0}
                            parts = []
                            for chunk, seconds in wav_chunks(audio_path):
                                parts.append(server.transcribe(chunk, suite.get("mainLanguage", "zh"), hints, seconds))
                                row["audioCoverage"]["coveredFrames"] += round(seconds * 16000)
                            text = " ".join(parts)
                            row.update(status="success", text=text, parts=len(parts), transcriptionCompleted=True)
                            reference_text = case.get("verbatimReference", case.get("reference"))
                            review = case.get("referenceAudit", {}).get("raw", "unreviewed")
                            row["referenceStatus"] = review
                            if reference_text and review in {"source-verified", "user-confirmed", "human-audited"}:
                                reference = tokens(reference_text)
                                row.update(edits=edit_count(reference, tokens(text)), referenceTokens=len(reference))
                        except (RuntimeError, ValueError, OSError, urllib.error.URLError, queue.Empty) as error:
                            row.update(status="failed", errorType=type(error).__name__)
                        row["asrMs"] = round((time.monotonic() - started) * 1000)
                        output.write(json.dumps(row, ensure_ascii=False) + "\n")
                        output.flush()
                        print(json.dumps({key: row[key] for key in ("case", "model", "run", "status", "asrMs")}), flush=True)
                    finally:
                        if server is not None:
                            server.close()


if __name__ == "__main__":
    main()
