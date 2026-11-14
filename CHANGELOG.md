# Changelog

## Next

- Add isolated real-time preview/polish research and an explicit process-local, one-request timeout harness for real Retry acceptance; keep normal startup and production routing unchanged
- Require a writable, focused text control before auto-paste, recheck after restoring the original app, and retain the transcript in the clipboard when focus is unavailable
- Reject incomplete text-polish responses and keep the aligned transcript; refresh account credentials only for a 401, without retrying a 403 challenge
- Preserve known English words and recognized acronyms during fuzzy term alignment, including Provider and MCP server
- Add isolated text-polish evaluation with explicit completed-result timing, requested/reported models and real token usage; keep production model and prompt selection unchanged

- Added an installed-app, read-only Apple Contacts report with private local duplicate candidates, per-card source links, and an offline layered name catalog; live dictation and the existing vocabulary remain unchanged

- Cached derived ASR hint ordering and polish glossary keys without changing the selected model, prompt bytes, vocabulary, or whole-transcript rewrite flow; added per-stage and per-attempt latency observations
- Added optional Beijing Qwen Flash whole-transcript polish with an independent Keychain key, fixed non-thinking streaming request, and paired fidelity/latency acceptance before changing the selected provider
- Kept connection-test results bound to the current provider and request during provider changes

- Added bottom multiline live preview with full-text scrolling and stable manual placement; geometry refresh preserves terminal auto-hide deadlines
- Added the owner-approved optional GLM-4.7-Flash polish route with an independent Keychain API key, fixed destination, and the existing whole-transcript prompt and fallback

- Automatically retry AI Polish once when a successful response is suspiciously truncated, while preserving the normalized transcript if the retry is also incomplete
- Detect microphone-input dropouts during recording and reject long digital-silence tails before transcription, preserving the audio instead of pasting an incomplete result
- Replaced the stale provider-key fallback matrix with explicit polish selection and separate Keychain-backed GLM credentials
- Restored menu-bar-only startup, Settings access, and `Cmd+Q` lifecycle behavior without a Dock icon or an unsolicited launch window
- Moved ChatGPT sign-in to the official device-code flow and surfaced the code, copy action, and user guidance inside ChatType
- Added the OAuth account-context request contract required by the private ChatGPT transcription path and preserved recordings when Cloudflare returns a challenge
- Kept ChatGPT Managed Auth and user-selected OpenAI-Compatible recovery as the two transcription route IDs; managed live recognition on macOS 26+ uses the approved local SpeechAnalyzer path
- Added bounded incident diagnostics, billing/provider policy checks, and an installed-app acceptance matrix
- Restored the approved dynamic menu-bar icon after an unauthorized text-label regression and added visual-ownership regression gates

## 0.5.1

- Fixed AI Polish requests against the ChatGPT-backed Codex Responses endpoint by using the supported streaming, non-stored request shape
- Added visible AI Polish attempt, success, and failure accounting so Settings no longer hides backend failures as ordinary ASR runs
- Updated release metadata for `v0.5.1`

## 0.5.0

- Added a hybrid post-ASR text-polish pipeline for long dictation: ASR output is normalized, optionally rewritten by a configured text model, then normalized again before paste
- Added ChatGPT Auth-only text polish for long dictation, without separate provider API keys
- Reworked Settings into a workflow sidebar with Account, Dictation, AI Polish, Terminology, Paste, and Advanced sections
- Added token-estimate metadata for text polish in Settings and latency logs
- Increased terminology recall for accented Latin ASR drift while continuing to protect technical literals
- Updated release metadata for `v0.5.0`

- Added ChatType-owned ChatGPT sign-in and Keychain-backed local session storage so the default route no longer depends on Codex login state
- Added bounded recovery for private ChatGPT transcription failures: Cloudflare `403` now skips token refresh, tries the private endpoint up to three times, keeps the recorded audio on failure, and exposes a HUD Retry action
- Defaulted `Restore clipboard after paste` to off so the latest transcript stays available for manual `Cmd+V` recovery
- Tightened paste safety so ChatType only reports `Pasted transcript` when an editable focus signal exists; otherwise it leaves the transcript in the clipboard
- Added regression coverage for Codex placeholder artifacts and no-focus clipboard fallback behavior

## 0.1.2

- Added manual TypeWhisper terminology import in Settings and persisted the imported glossary into `~/Library/Application Support/ChatType/config.json`
- Added stronger deterministic post-STT terminology alignment without reintroducing a second AI cleanup pass
- Exposed exact and fuzzy terminology-alignment metrics in the dictation pipeline and test suite
- Updated public docs, release notes, landing page, and packaging metadata for the `v0.1.2` release surface

## 0.1.0

- Established `ChatType` as the launch product name across the app, packaging, and docs
- Made the local ChatGPT account route the default transcription path
- Simplified the main product to a single-stage STT flow instead of a second cleanup pass
- Added fixed transcription prompting plus hidden `transcription.hintTerms` for term preservation
- Added desktop-auth warm caching and per-dictation latency logging
- Added a packaged benchmark path via `scripts/benchmark_stt.sh`
- Added runtime setup states for missing host app, missing ChatGPT login, and missing desktop token
- Reworked Settings into a setup-first onboarding surface with microphone and Accessibility checks
- Moved `OpenAI-Compatible` transcription into an advanced recovery position
- Renamed packaged assets to `dist/ChatType.app`, `dist/ChatType-0.1.0-macos-arm64.zip`, and `dist/ChatType-0.1.0-macos-arm64.dmg`
- Added Homebrew Cask packaging metadata support under `packaging/homebrew/Casks/`

### Recording preservation (2026-10-07)

- Persist original audio from capture start with a private durable journal; refuse capture if storage cannot be prepared.
- Keep audio after cancellation, processing and history display limits; recover unfinished WAV recordings on relaunch.

## 0.5.1 (122) — Control panel

- Consolidate accounts, transcription and text-polish models; add an inspectable six-step processing flow.
- Combine Dictation and polish behavior, merge local preferences into Settings, and support the macOS login item.
- Search and filter a virtualized bilingual terminology library. Keep explicit final-text correction separate from macOS input shortcuts.
- Import WeChat names through the existing read tool, merging into the latest draft. Back up and migrate legacy shortcut rules without retaining shortcut aliases.

- Ship optimized release binaries; reset page scroll on navigation and keep save feedback in one place.
- Normalize imported Chinese name fragments fully in one pass so reloading does not split the library again.
