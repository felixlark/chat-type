# ChatType product contract

ChatType is a native macOS menu bar dictation app. This file owns the current behavior; [architecture](docs/architecture.md) describes implementation, [operations](docs/operations.md) owns diagnosis and acceptance, and [release](docs/release.md) owns packaging and installation.

## Dictation

Press physical F5 to start and again to stop. ESC or the inline close cancels the active task while retaining its recording. On the enrolled development Mac, F5 maps to keycode 79; Doubao IME keeps physical Fn. Other users retain their selected bindings.

New configurations select Doubao IME for recognition and text organization. Saved selections are preserved. Recognition also supports ChatType-managed ChatGPT login and explicitly configured OpenAI-compatible recovery. Text polish independently supports the approved Doubao, ChatGPT, GLM and Qwen choices. Failure never changes providers automatically.

The complete recording, original route snapshot, stage outputs, final text and errors remain in private local recovery history. Retry reuses the original selection. Reprocessing with current settings is a distinct history action; partial audio requires an explicit replay decision. Processing failure preserves the attempt and does not paste partial text. Disabled polish intentionally skips that stage.

Recording uses a centered status HUD below the screen's menu-bar/camera safe area, with separate black-and-white captions underneath. Captions use their own readable typography, normally two lines and expanding to four before scrolling older words; they never depend on the input's caret or font. The session stays on its initial screen when focus changes. Final captions remain readable after verified output; reading time does not delay paste. Preserve existing product icons, menu-bar rendering and status colors.

## Output and settings

Output targets the captured editable control and uses the existing application-specific bridge when available. Report successful output only after its receipt; preserve uncertain output for reconciliation. Without a suitable target, retain the final text in the clipboard.

Settings has four destinations: Account, Workflow, History and Settings. Account reports service installation, credential readiness and local preview support separately from request success. Workflow selects recognition, terminology alignment, text polish and correction behavior. PreferencesDraft owns unsaved edits; asynchronous imports must preserve current edits. History exposes recordings, attempts and stage evidence. Settings owns login items, permissions, sounds and clipboard behavior. Keyboard shortcuts also depend on macOS and the enrolled local keyboard policy.

## Data and service boundaries

Audio goes to the selected recognizer; relevant text goes to the selected polish service. Credentials stay in Keychain. Doubao IME and the ChatGPT account backend are private, version-sensitive dependencies; neither is a stable public API or a billing guarantee. Optional compatible/GLM/Qwen routes require independent credentials and billing authorization. Never export browser Cookies or another application's credentials.

Apple Contacts and the supported WeChat names helper can import names into the local vocabulary. Keep imported vocabulary, recordings, credentials and real user history out of source control and cleanup deletions.

## Acceptance

Use the signed app at `/Applications/ChatType.app`. Checks, packaging, installation, live interaction and final running state are separate evidence. The minimum changed journey and the fixed authentication/transcription matrix live in [operations](docs/operations.md); do not duplicate historical acceptance checklists here. Historical proposals and experiment results are evidence for their recorded versions, not current requirements; see [history](docs/history.md).
