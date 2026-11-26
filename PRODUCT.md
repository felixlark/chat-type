# ChatType product contract

ChatType is a native macOS menu bar dictation app. Opening the menu-bar item shows State, readiness and the current model route for live preview, final recognition and enabled polish in processing order. This file owns the current behavior; [architecture](docs/architecture.md) describes implementation, [operations](docs/operations.md) owns diagnosis and acceptance, and [release](docs/release.md) owns packaging and installation.

## Dictation

Press physical F5 to start and again to stop. ESC or the inline close cancels the active task while retaining its recording. On the enrolled development Mac, F5 maps to keycode 79; Doubao IME keeps physical Fn. Other users retain their selected bindings.

Settings → 激活快捷键 records a physical key with optional Command, Option, Control and Shift modifiers. Escape, focus loss and closing Settings cancel capture and restore activation. Save Settings registers the candidate immediately; conflicts or persistence failures keep the previous binding. New recordings and reprocessing apply workflow edits without committing a pending shortcut. Explicit custom bindings survive installation.

The enrolled Mac may independently add a short Fn tap as another ChatType activation event (F18). Native Fn down/up events pass through immediately; the native Doubao input method keeps its own long-press handling. The tap timeout is an explicit local keyboard preference. This does not select ChatType’s recognition or polish provider.

New configurations select Doubao IME for recognition and text organization. Saved selections are preserved. Recognition also supports ChatType-managed ChatGPT login and explicitly configured OpenAI-compatible recovery. Text polish independently supports the approved Doubao, ChatGPT, GLM and Qwen choices. Failure never changes providers automatically.

Live preview has its own source choice in the 录音 workflow stage: follow the recognizer, use Doubao streaming preview, or use Apple SpeechAnalyzer with ChatGPT recognition. Choosing Doubao preview sends recording audio to Doubao even when final recognition uses another selected service; the UI states that destination explicitly. Preview text is provisional and never replaces final recognition.

The complete recording, original route snapshot, stage outputs, final text and errors remain in private local recovery history. History presents one fixed-screen detail: waveform first, 重试原路线 and 按当前流程重跑, clickable stages, then ASR 原文, 对齐后 and 润色输出. The 校正 stage reports the count and sampled words changed after polish. Retry reuses the original selection. Reprocessing with current settings is a distinct history action; partial audio requires an explicit replay decision. Processing failure preserves the attempt and does not paste partial text. Disabled polish intentionally skips that stage.

Recording uses a centered status HUD below the screen's menu-bar/camera safe area, with separate black-and-white captions underneath. Its Listening mark is a compact nine-bar spectrum with a flat bottom baseline: bars grow upward and move independently with input instead of mirroring around a center line. Captions use their own readable typography, a single line showing the latest wrapped phrase; they never depend on the input's caret or font. The session stays on its initial screen when focus changes. Final captions remain readable after verified output; reading time does not delay paste. Preserve existing product icons, menu-bar rendering and status colors.

## Output and settings

Output targets the captured editable control and uses the existing application-specific bridge when available. Report successful output only after its receipt; preserve uncertain output for reconciliation. Without a suitable target, retain the final text in the clipboard.

Settings has four destinations: Account, Workflow, History and Settings. Account reports service installation, credential readiness and local preview support separately from request success, and labels each service by 实时预览, 识别 and 润色 capability. Permissions are not duplicated in Account. Workflow selects recognition, preview source, terminology alignment, text polish and correction behavior. PreferencesDraft owns unsaved edits; asynchronous imports must preserve current edits. History exposes a per-voice workspace with original audio, attempts, intermediate text, output status and recovery actions. Settings owns login items, permissions, sounds, local data and clipboard behavior. Keyboard shortcuts also depend on macOS and the enrolled local keyboard policy. The Settings window defaults to a maximized frame on the built-in display (`CGDisplayIsBuiltin=1`), with fallback to the first available screen when no built-in display exists.

## Data and service boundaries

Audio goes to the selected recognizer and any explicitly selected Doubao preview; relevant text goes to the selected polish service. Credentials stay in Keychain. Doubao IME and the ChatGPT account backend are private, version-sensitive dependencies; neither is a stable public API or a billing guarantee. ChatGPT Auth polish uses the existing ChatGPT account session at `chatgpt.com`; it is not an OpenAI Platform API key call. Account quota and frequency limits remain provider-controlled, and displayed token values are local estimates rather than a bill. Optional compatible/GLM/Qwen routes require independent credentials and billing authorization. Never export browser Cookies or another application's credentials.

Apple Contacts and the supported WeChat names helper can import names into the local vocabulary. Keep imported vocabulary, recordings, credentials and real user history out of source control and cleanup deletions.

## Acceptance

Use the signed app at `/Applications/ChatType.app`. Checks, packaging, installation, live interaction and final running state are separate evidence. The minimum changed journey and the fixed authentication/transcription matrix live in [operations](docs/operations.md); do not duplicate historical acceptance checklists here. Historical proposals and experiment results are evidence for their recorded versions, not current requirements; see [history](docs/history.md).
