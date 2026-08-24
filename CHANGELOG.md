# Changelog

## Next

- Removed the stale provider-key fallback matrix from shipped config and Settings; AI Polish is ChatGPT Auth only
- Restored menu-bar-only startup, Settings access, and `Cmd+Q` lifecycle behavior without a Dock icon or an unsolicited launch window
- Moved ChatGPT sign-in to the official device-code flow and surfaced the code, copy action, and user guidance inside ChatType
- Added the OAuth account-context request contract required by the private ChatGPT transcription path and preserved recordings when Cloudflare returns a challenge
- Removed the unapproved macOS Speech fallback so the product retains only ChatGPT Managed Auth and user-selected OpenAI-Compatible recovery
- Added bounded incident diagnostics, billing/provider policy checks, and an installed-app acceptance matrix

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
