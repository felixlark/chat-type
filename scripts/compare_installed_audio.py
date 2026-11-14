#!/usr/bin/env python3
"""Explicit physical-F5 acceptance, never a microphone/paste simulator.

The caller prepares/focuses an owned TextEdit document before asking the user
to press F5. Device activity alone is not recording readiness: prepareToRecord
can open, close, and reopen the microphone before actual capture begins.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import threading
import time


def pcm_frames(path):
    """Read actual growing PCM bytes; the RIFF/data lengths may still be zero."""
    try:
        with Path(path).open("rb") as f:
            size = os.fstat(f.fileno()).st_size
            h = f.read(12)
            if len(h) != 12 or h[:4] != b"RIFF" or h[8:] != b"WAVE":
                return 0
            align = None
            while f.tell() + 8 <= size:
                tag, length = struct.unpack("<4sI", f.read(8))
                offset = f.tell()
                if tag == b"fmt ":
                    fmt = f.read(16)
                    if length < 16 or len(fmt) < 16:
                        return 0
                    code, channels, rate, _, block, bits = struct.unpack("<HHIIHH", fmt)
                    if code != 1 or channels < 1 or rate == 0 or bits != 16 or block != channels * 2:
                        return 0
                    align = block
                elif tag == b"data":
                    return (size - offset) // align if align else 0
                f.seek(offset + length + length % 2)
    except (OSError, struct.error):
        pass
    return 0


def recording_ready(record, frames, provider):
    attempts = record.get("attempts", [])
    return bool(record.get("outcome") == "recording"
                and record.get("appBundleIdentifier") == "com.apple.TextEdit"
                and attempts and attempts[-1].get("id")
                and attempts[-1].get("outcome") == "recording"
                and attempts[-1].get("snapshot", {}).get("provider") == provider
                and frames > 0)


class PlaybackGate:
    """No clocks or microphone pulses can substitute for a real start key."""
    def __init__(self):
        self.started = False
        self.stopped = False
        self.claimed = False
        self.source_complete = False
        self.first_frames = None

    def start(self):
        self.started = True

    def stop(self):
        self.stopped = True

    def claim(self, ready, target):
        if self.started and not self.stopped and not self.claimed and ready and target:
            self.claimed = True
            return True
        return False

    def observe_capture(self, record, frames, provider):
        if not recording_ready(record, frames, provider):
            return False
        if self.first_frames is None:
            self.first_frames = frames
            return False
        return frames > self.first_frames

    @property
    def valid_stop(self):
        return self.stopped and self.claimed and self.source_complete


def run(args):
    os.umask(0o077)
    root = args.output.resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    recovery = args.recovery.resolve()
    records = recovery / "Records"
    existing = {p.name for p in records.glob("*.json")}
    gate = PlaybackGate()
    lock = threading.RLock()
    state = {"phase": "ready", "frontmost": "", "field": {}}
    keys = {}
    record_path = None
    attempt_id = None
    player = None
    field_changed = 0
    last_own_field = {}
    source_hash = hashlib.sha256(args.audio.read_bytes()).hexdigest()

    def emit(kind, **values):
        row = dict(kind=kind, tickNs=time.clock_gettime_ns(time.CLOCK_UPTIME_RAW), **values)
        with lock:
            with (root / "events.jsonl").open("a") as f:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
            tmp = root / "status-next.json"
            tmp.write_text(json.dumps(dict(state, **row), ensure_ascii=False, indent=2))
            tmp.replace(root / "status.json")
        return row

    def target_valid():
        return state["frontmost"] == "com.apple.TextEdit" and state["field"].get("valid", False)

    def finish(phase):
        state["phase"] = phase
        emit("phase", phase=phase)
        if phase in terminal or phase.startswith("app-"):
            terminated.set()
            if observer and observer.poll() is None:
                observer.terminate()

    def play():
        nonlocal player
        # Existing comparison protocol delay, configurable and not product policy.
        time.sleep(args.playback_delay)
        with lock:
            if gate.stopped or state["phase"] != "recording" or not target_valid():
                finish("invalid-before-playback")
                return
            if hashlib.sha256(args.audio.read_bytes()).hexdigest() != source_hash:
                finish("source-changed")
                return
            emit("source-start", sourceSHA256=source_hash)
            player = subprocess.Popen(["/usr/bin/afplay", str(args.audio)])
        code = player.wait()
        with lock:
            gate.source_complete = code == 0 and not gate.stopped
            emit("source-end", returncode=code, complete=gate.source_complete)
            if gate.source_complete:
                subprocess.Popen(["/usr/bin/afplay", "/System/Library/Sounds/Glass.aiff"])
            elif not gate.stopped:
                gate.stop(); finish("playback-failed")

    def journal():
        nonlocal record_path
        if record_path is None:
            for p in records.glob("*.json"):
                if p.name in existing:
                    continue
                try:
                    d = json.loads(p.read_text())
                except (OSError, ValueError):
                    continue
                if d.get("appBundleIdentifier") == "com.apple.TextEdit" and d.get("attempts"):
                    record_path = p
                    emit("record", recordID=d["id"])
                    break
        if record_path:
            try:
                return json.loads(record_path.read_text())
            except (OSError, ValueError):
                pass
        return None

    def poll():
        nonlocal attempt_id
        while not terminated.is_set():
            time.sleep(0.05)
            with lock:
                if not gate.started or state["phase"] in terminal or state["phase"].startswith("app-"):
                    continue
                d = journal()
                if not d:
                    continue
                wav = recovery / "Audio" / Path(d["audioFileName"]).name
                ready = gate.observe_capture(d, pcm_frames(wav), args.provider)
                if gate.claim(ready, target_valid()):
                    attempt_id = d["attempts"][-1]["id"]
                    emit("capture-progress", recordID=d["id"], attemptID=attempt_id,
                         firstFrames=gate.first_frames, capturedFrames=pcm_frames(wav))
                    finish("recording")
                    threading.Thread(target=play, daemon=True).start()
                if d.get("outcome") in ["cancelled", "error", "clipboard", "outputUnknown"]:
                    gate.stop()
                    if player and player.poll() is None:
                        player.terminate()
                    finish("app-" + d["outcome"])
                if gate.valid_stop and d.get("outcome") == "pasted":
                    if d["attempts"][-1]["id"] != attempt_id:
                        finish("attempt-changed")
                        continue
                    text = d.get("attempts", [{}])[-1].get("stages", {}).get("finalText")
                    field = last_own_field
                    now = time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)
                    if text and field.get("text", "").strip() == text.strip() and now - max(field_changed, keys["stop"]["tickNs"]) > 3_000_000_000:
                        actual_hash = hashlib.sha256(wav.read_bytes()).hexdigest()
                        if not d.get("audioSHA256") or actual_hash != d["audioSHA256"]:
                            finish("audit-hash-mismatch")
                            continue
                        receipt = dict(recordID=d["id"], audioSHA256=d.get("audioSHA256"), sourceSHA256=source_hash,
                                       keys=keys, field=field, stages=d["attempts"][-1]["stages"],
                                       provider=args.provider, attemptID=attempt_id,
                                       polishProvider=d["attempts"][-1]["snapshot"].get("textPolish", {}).get("provider"),
                                       actualAudioSHA256=actual_hash)
                        (root / "result.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2))
                        finish("accepted")

    terminal = {"accepted", "early-stop", "cancelled", "invalid-before-playback", "invalid-start",
                "playback-failed", "observer-unavailable", "attempt-changed", "audit-hash-mismatch", "source-changed"}
    terminated = threading.Event()
    observer = None
    def terminate(*_):
        terminated.set()
        if observer and observer.poll() is None:
            observer.terminate()
    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    emit("setup", sourceSHA256=source_hash)
    observer = subprocess.Popen([str(args.observer), args.target_title], stdout=subprocess.PIPE, text=True)
    threading.Thread(target=poll, daemon=True).start()
    try:
        for line in observer.stdout:
            if terminated.is_set():
                break
            event = json.loads(line)
            with lock:
                with (root / "observer.jsonl").open("a") as f:
                    f.write(line)
                if event["kind"] == "preflight" and not (event.get("AXTrusted") and event.get("HIDTapAvailable")):
                    finish("observer-unavailable")
                elif event["kind"] == "frontmost":
                    state["frontmost"] = event["bundleID"]
                elif event["kind"] == "field":
                    state["field"] = event
                    if event.get("valid") and event.get("frontmost"):
                        last_own_field = event
                        field_changed = event["tickNs"]
                elif event["kind"] == "key" and event["eventType"] == 10 and not event.get("repeat"):
                    if state["phase"] in terminal or state["phase"].startswith("app-"):
                        continue
                    key = event["keyCode"]
                    if key == 53 and gate.started:
                        gate.stop(); finish("cancelled")
                    elif key == args.key_code:
                        if not gate.started:
                            if not target_valid() or state["field"].get("text", ""):
                                finish("invalid-start")
                            else:
                                keys["start"] = event; gate.start(); finish("awaiting-capture")
                        elif not gate.stopped:
                            keys["stop"] = event; gate.stop()
                            finish("stopped" if gate.valid_stop else "early-stop")
                # Microphone active/inactive events are evidence, never a trigger.
                if gate.stopped and player and player.poll() is None:
                    player.terminate()
    finally:
        terminated.set()
        observer.terminate()
        if player and player.poll() is None:
            player.terminate()
        emit("controller-stopped")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--audio", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--observer", type=Path, required=True)
    p.add_argument("--target-title", required=True)
    p.add_argument("--provider", default="doubaoIME")
    p.add_argument("--key-code", type=int, default=79)
    p.add_argument("--playback-delay", type=float, default=0.7)
    p.add_argument("--recovery", type=Path, default=Path.home() / "Library/Application Support/ChatType/Recovery")
    run(p.parse_args())
