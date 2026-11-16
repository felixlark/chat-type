# Doubao recognition fidelity correction — build132

> Historical evidence for the date/build recorded below. Current requirements: [PRODUCT](../PRODUCT.md).

The initial adapter used libopus VOIP with its automatic bitrate and VBR defaults. Native 1.1.0's raw speech_opus encoder uses AUDIO, CBR and an explicit bitrate; its default64kbps matches the public Mac settings compression ratio4 for mono PCM16/16kHz. Actual adapter speech packets in the affected acoustic replay carried roughly14kbps, so sharing a service host did not provide equivalent audio fidelity.

Build132 configures bundled libopus AUDIO/CBR at64000bps through a small C variadic ABI bridge, validates each control call and cleans up initialization failures. It preserves the existing supported20ms frame cadence, capture framework, original WAV, immutable attempt snapshots and all ChatGPT/compatible routes. StartSession aligns compression ratio4 and single-toggle input_mode=shortcut_single with the recovered native contract. Those request-field changes alone did not repair recognition in the controlled tests; the codec combination is the demonstrated fix.

## Evidence and limits

The same approved16.778s spoken fixture was replayed through the same speaker/microphone. A counterbalanced legacy AVAudioRecorder / AVCaptureAudioDataOutput study found that both capture APIs could lose Tube under the old encoder. We therefore retained the production recorder instead of replacing it on an unproved framework hypothesis.

Two sealed recordings, one from each capture API, were then replayed byte-for-byte with old and corrected encoding. Both old-codec results lost Tube; both corrected-codec results retained Smart Tube, Xiaomi TV and the directional-key/next-video instruction. An independent20ms AUDIO/CBR64 replay on the legacy capture, still using the old request fields, also recovered Smart Tube. This supports the encoder combination, without separately attributing the improvement to any one encoder control or claiming native always runs these exact dynamic settings.

A more degraded earlier recording remained incorrect with corrected encoding, rawPCM, and an independent ChatGPT ASR probe. Encoding cannot guarantee restoration of every uncertain speech signal. No keyword-specific substitution was added, and no CER or population accuracy is claimed without an independently audited transcript. All service507 failures are retained separately and never counted as successful quality results.

Native extra/context and entity learning were also examined. The minimal recovered hotword context did not restore the degraded clip in the accepted probe, and native runtime word-class/settings coverage remains unknown. Build132 does not upload a new vocabulary payload or add an unverified context feature. Existing terminology processing is preserved.

## Verification contract

- Real libopus output checks cover50 alternating silent/voiced20ms frames plus a partial tail: every encoded frame is160bytes at64kbps; input PCM remains unchanged. This catches variadic-ABI, bitrate and VBR regressions.
- Injected-socket integration asserts emitted compression/mode fields, frame count, encoded byte count and unchanged source WAV, without Keychain/network/microphone/GUI access.
- Candidate-bound file/live-worker replay, signed installation and physical-F5 acceptance are separate required receipts. CLI/worker measurements do not replace the installed editable-target flow.
- Preserve the user's saved provider choices. Fresh configurations retain the approved Doubao default; never switch providers after failure. Original audio, unsuccessful attempts and stage audit remain private locally.

The fidelity target increases compressed audio from roughly1.7KB/s in the affected default-encoder sample to8KB/s, with the same data destination. It is a codec setting rather than a new resource admission cap. Existing private-protocol, availability and billing caveats remain.
