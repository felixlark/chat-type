# Recording readiness and same-source acceptance — build133

`AVAudioRecorder.prepareToRecord` can briefly open and close the input device
before `record()` produces a progressing recording. Device-is-running is not a
reliable recording-ready or stop signal. The old private comparison controller
mistook that pulse for a complete recording: a failed cue-disabled trial never
played the source at all. That trial is retained as invalid, not evidence that
disabling the start cue fixes recognition.

The product now returns from AudioRecorder startup after its recording clock is
positive, with a valid active session. Permission ordering, PCM16 capture, Opus,
provider selection, raw audit and the original ChatGPT path remain unchanged.
Cancellation before ready stops the local input and preserves its reservation.
Late cancellation cannot reset a newer F5 session; an old startup's archive
failure is reported without changing the new session's HUD. There is no startup
timeout, background mic prewarm, keyword replacement, or new sound/brand design.

The public recording clock is an observation, not proof of waveform fidelity.
See Apple's [currentTime](https://developer.apple.com/documentation/avfaudio/avaudiorecorder/currenttime)
and [isRecording](https://developer.apple.com/documentation/avfaudio/avaudiorecorder/isrecording).
Real input/output acceptance remains necessary before claiming recovered words.

## Reusable installed-app comparison

Compile the read-only observer under an already authorized tool identity:

```sh
mkdir -p "$HOME/Library/Caches/ChatType/acceptance"
xcrun swiftc scripts/same_audio_observer.swift \
  -o "$HOME/Library/Caches/ChatType/acceptance/same-audio-observer"
python3 scripts/compare_installed_audio.py \
  --audio /absolute/path/to/approved-source.wav \
  --output "$HOME/Library/Logs/ChatType/acceptance/new-trial" \
  --observer "$HOME/Library/Caches/ChatType/acceptance/same-audio-observer" \
  --target-title same-audio-133.txt
```

The output directory must be new and private. Start the normal installed app
through LaunchServices; prepare and focus the exact empty TextEdit document
with official Computer Use before asking for the two physical F5 presses. On
this enrolled Mac, F5 maps to internal79; pass another `--key-code` explicitly
for a different enrolled mapping. The observer only listens to F5/Esc, checks
the exact document title, and never logs other documents' text or sends keys.
It exits without prompting if existing Accessibility/HID observation is absent.

Playback requires all of: an actual F5 start, the correct editable target, a new
recording attempt with its expected provider snapshot, and positive PCM frames
that advance after the first journal observation. A preallocated WAV or the
initial journal reservation does not qualify. Microphone prepare pulses remain
observations only. The previous0.7s stimulus delay is retained as the explicit
`--playback-delay` test option, not a product gate or a cure for audio loss.

After the source-end cue, the second physical F5 supplies the stop clock. A
successful receipt also requires the same attempt, its pasted outcome, matching
observed field/stage text, and matching raw-audio audit hash. Source changes,
early stop, cancel, transport failure, clipboard fallback, or another attempt
do not produce an accepted result. The helper does not retry or inject text.
Physical stop to AX last-absent/first-present polls bounds the observed insertion;
do not substitute file-worker timing for this GUI measurement.

## Native observation and interpretation

The approved16.778s source was also fed digitally through an existing local
virtual input to native1.1.0, with real Fn start/stop and a producer completion
receipt. Its final text retained 小米电视, Smart Tube and 配置. The feeder kept
silence running after the source so a virtual output-device close could not be
mistaken for the user's stop. Native input selection was restored to Automatic
(builtin microphone). No new driver was installed; the temporary aggregate
experiment was removed. The default system input remained unchanged.

This establishes the native same-source observation, not byte identity of its
internal post-conversion PCM or attribution to its private cloud/local model.
Native still had its saved automatic offline setting. A separate real-time
ChatType clean-source worker trial exhausted three507 service-discovery
attempts; it remains a failed availability trial, not a fast or accurate result.
An accepted independent clean-source protocol probe retained all target words.
No CER or overall accuracy claim is made without an audited reference corpus.

Candidate installed-F5 quality, raw waveform and final timing must be appended
to the delivery receipt; if opening/configuration errors remain, continue the
capture investigation. Preserve raw originals and failed trials throughout.
