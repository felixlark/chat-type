# ChatType architecture

The current behavior is defined by the [product contract](../PRODUCT.md). This document owns module boundaries and data flow.

## Runtime

`AppDelegate` resolves explicit launch modes; normal launch remains a menu bar application. `AppCoordinator` owns recording, processing, cancellation and Retry. Session identity isolates obsolete asynchronous tasks; attempt identity records stages. Recording to processing retains its attempt, whereas Retry and history replay create a new attempt. These identities have distinct responsibilities.

`AudioRecorder` persists the original WAV. The selected Doubao route uses `DoubaoLiveRecognition`; the supported ChatGPT preview route can use `LocalSpeechRecorder` on macOS 26+. Preview is not a substitute for the selected final transcription route.

`DictationServiceFactory` constructs the selected transcriber and optional polisher with the configured terminology/correction switches. The normal coordinator and explicit timeout acceptance use this same factory. `AcceptanceTranscriptionDeadline` only injects a one-shot deadline into the audited ChatGPT HTTP transport; it cannot claim to fault-inject Doubao's WebSocket.

`DictationPipeline` performs recognition, local terminology alignment, optional whole-transcript polish, final alignment, explicit corrections and formatting. It seals stage audit data before output. Processing failure throws with evidence and never silently substitutes partial text. A deliberate provider safety decision retaining the original text is recorded separately from a transport failure.

`LiveTextInput` captures the original target and UTF-16 selection; it no longer presents draft text. `TextInjector`, `FocusedElementInspector` and `SublimeEditorBridge` own verified final output. `OverlayController` owns the top status HUD and `OverlayCaptionPanel`; `TopOverlayLayout` places both below the selected screen's live menu-bar/camera safe area. `OverlayCaptionText` selects and wraps the latest sentence, and a versioned drawing receipt starts the final reading interval after injection. No input caret/font reads are needed for captions. The old input-attached renderer and bottom/drag placement have been retired.

## Services and persistence

- `ChatGPTAuthManager`, `BrowserAuthBridge` and `ChatGPTSessionStore`: app-owned account login and Keychain session persistence. A browser callback, ready login and successful business request are separate facts.
- `ChatGPTTranscriber.selectedRoute`: explicit Doubao, ChatGPT or compatible recognition selection. ChatGPT OAuth is restricted to audited official account hosts.
- `OpenAICompatibleTextPolisher` and `DoubaoTextOrganizer`: independently selected polish service, with fixed approved destinations and credential ownership.
- `TerminologyNormalizer`, `VocabularyIndex` and `TerminologyPolicy`: deterministic local alignment, vocabulary lookup and import policy. `TerminologyEditor` edits the shared draft.
- `RecoveryStore`: original recordings, per-attempt snapshots, stage outputs and errors. `TranscriptionHistoryRecorder` serves displayed text history; `LatencyRecorder` serves diagnostics. These have different consumers and are retained.
- `ConfigStore`: decodes historical configurations without changing saved provider choices. Retired browser-setting fields are ignored rather than exposing controls that never affected authentication.

## Settings ownership

`PreferencesWindowController` manages the native window. `PreferencesView` remains the single SwiftUI root and owns the draft reference, page selection, import flags and asynchronous provider/usage/history resources. Account, Workflow, History and shared component files are extensions of that same view; splitting files does not create new resource owners or change view identity. `PreferencesDraft` remains the only unsaved configuration source. `LoginItemController` reads and updates the actual SMAppService registration.

## Tools and delivery

The retained `process`, contacts report, quality, polish and streaming evaluation commands serve explicit development/reporting use. Streaming evaluation exercises recovery snapshots and real-time audio pacing, and does not replace microphone, physical F5 or target-output acceptance. Omni tools remain isolated research tooling, with no production route or bundled model download. Failed incremental/cloud-prefix/local-editing research entry points have been retired; fixed source and results remain available through [history](history.md).

Use `scripts/check.sh --source` for the same non-GUI checks locally and in CI. The default `scripts/check.sh` additionally packages and checks the resulting app. `scripts/package_app.sh` produces the app and release archives once; `scripts/check_packaged_app.sh --existing` validates that candidate without rebuilding. Install through `scripts/install_app.sh`, launch through LaunchServices and verify `/Applications/ChatType.app`. Build products live outside Documents; user state and reusable caches are not cleanup targets. See [release](release.md) for exact commands.
