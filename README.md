# ChatType

[中文说明](README.zh-CN.md)

`ChatType` is a native macOS dictation app for people who want the fastest possible `F5 -> speak -> paste` workflow with ChatGPT on the same Mac.

Public landing page: [longbiao.crowdsensing.cn/chat-type](https://longbiao.crowdsensing.cn/chat-type/)

It is intentionally opinionated:

- global `F5` hotkey
- native menu bar app
- ChatGPT connection through the default browser OAuth flow with app-owned local session storage
- ChatGPT ASR followed by optional AI text polish for long, agent-facing dictation
- conservative paste behavior: only paste when an editable target is detected
- clipboard fallback when paste is not safe, with the latest transcript kept available for manual `Cmd+V`
- Apple Contacts nickname and WeChat remark-name import, plus custom replacements for stronger post-STT alignment
- ChatGPT Auth-only AI text polish for long dictation, without a separate polish API key
- optional advanced recovery route for OpenAI-compatible APIs

## Product Promise

- No extra dictation subscription
- No API key required for the normal ASR path
- Optional ChatGPT Auth text polish when you want long dictation rewritten into concise plans
- No local model download or tuning
- Install once, connect ChatGPT through the default browser, press `F5`, speak, and get text back

## Current Status

`ChatType` `v0.5.1` is the current public release. `./scripts/package_app.sh` expects a stable local signing identity and emits a locally signed, non-notarized `.app` plus GitHub release `.zip` and `.dmg` artifacts.

## How It Works

1. Install `ChatType`
2. Install the packaged app to `/Applications/ChatType.app`, then launch that installed copy
3. Grant microphone permission
4. If microphone access was denied earlier, use `Open Microphone Settings` in `ChatType Settings`
5. If you want auto-paste, use `Guide Accessibility Access` in `ChatType Settings`
6. `ChatType` opens the Accessibility page and shows a drag-to-authorize helper around the packaged app
7. If `ChatType` still does not appear there, click `+` in Accessibility and add `/Applications/ChatType.app`
8. Put the cursor in Notes, Mail, Slack, Codex, or another editable target
9. Press `F5`, speak, press `F5` again
10. `ChatType` uses its own ChatGPT session and private ChatGPT transcription path
11. Optional: import Apple Contacts nicknames or WeChat remarks from Smart Shadow's decrypted contacts in Settings
12. Optional: enable ChatGPT Auth text polish in Settings. It uses ChatType's stored ChatGPT session and does not require a separate polish API key
13. `ChatType` applies terminology alignment, optional AI polish, and a final protective normalization pass
14. The result is pasted into the focused app only when an editable target is detected; otherwise it is left in the clipboard for manual `Cmd+V`
15. Chinese output defaults to Simplified Chinese unless the original speech clearly asks for Traditional Chinese

## Installation

### Downloaded app

1. Build and package:

```bash
./scripts/package_app.sh
```

2. Install the packaged app to `/Applications`:

```bash
./scripts/install_app.sh
```

If you intentionally need an ad-hoc build for throwaway debugging, opt into it explicitly:

```bash
CHATTYPE_ALLOW_ADHOC_SIGNING=1 ./scripts/package_app.sh
```

That fallback is not recommended for normal use. On recent macOS versions it can still leave Accessibility without a toggleable `ChatType` row, which is why the packaged `/Applications/ChatType.app` path matters for the new guided repair flow as well.

3. Launch the installed app:

```bash
open -n /Applications/ChatType.app
```

Do not launch `dist/ChatType.app` directly. The `dist` copy is packaging output only; live permissions and verification must bind to `/Applications/ChatType.app`.

4. If macOS blocks the app on first launch:

```bash
xattr -dr com.apple.quarantine /path/to/ChatType.app
```

### Homebrew Cask metadata

Homebrew packaging metadata lives at:

```text
packaging/homebrew/Casks/chattype.rb
```

This repo does not yet publish a dedicated Homebrew tap, but the cask file is kept current with the release artifact format.

### Release Download

- Releases: [github.com/felixlark/chat-type/releases](https://github.com/felixlark/chat-type/releases)
- Current release page: [v0.5.1](https://github.com/felixlark/chat-type/releases/tag/v0.5.1)

## Support Development

The preferred support path is GitHub Sponsors, but the public sponsor page is not enabled for this account yet. Until that page is live, the best support is to try the release, star the repo, and open issues with setup blockers or workflow feedback.

## Terminology Dictionary

`ChatType` keeps deterministic terminology alignment as the safety layer around optional AI polish:

- import Apple Contacts nicknames through the system Contacts permission
- import only non-empty remark names from Smart Shadow's decrypted WeChat contacts database
- add custom terms and deterministic replacements in Settings
- keep the glossary as ChatType-owned local config
- align tool names, product names, and technical terms before and after the optional text-polish call
- keep hidden `transcription.hintTerms` as exact-only preservation hints for filenames and other critical literals

## AI Text Polish

`v0.5.x` adds an optional post-ASR rewrite engine for long dictation. It is designed for agent-facing prompts: remove filler words, keep later corrections as the final intent, preserve glossary casing, and turn long speech into concise plan-like bullets when useful.

The polish path is intentionally separate from ASR but uses the same ChatType-managed ChatGPT login. Settings exposes the ChatGPT backend Responses endpoint and model for inspection, but no DeepSeek, Kimi, OpenAI, or custom polish API key is stored or used.

Current `main` keeps large dictionaries out of the hot path by indexing entries and matching only transcript-relevant candidates. AI Polish uses `gpt-5.6-terra` with reasoning disabled, a shorter outcome-first prompt, and a glossary clipped to terms actually present in the normalized transcript.

`v0.5.1` fixes the AI Polish request shape for the current ChatGPT-backed Codex Responses endpoint and makes Settings show polish attempts, successes, and failures instead of hiding backend failures.

## Advanced Recovery Route

If the ChatGPT account path is unavailable or you intentionally want a separate endpoint, `ChatType` still includes an advanced recovery route for OpenAI-compatible transcription APIs.

The normal ChatGPT account route does not misclassify a Cloudflare `403` challenge as an expired session. Initial transcription uses the bounded three-attempt policy, while an explicit Retry makes one new attempt. If the private route remains blocked, ChatType preserves the recording and shows a truthful Retry action; it does not silently switch providers.

That route is intentionally not part of the default onboarding. It requires:

- your own endpoint
- your own model choice
- your own API key environment variable

## Build And Verify

```bash
swift build --package-path .
swift test --package-path .
./scripts/check.sh
./script/build_and_run.sh
```

Benchmark the real packaged path with your own sample audio:

```bash
./scripts/benchmark_stt.sh ~/bench/3s.wav ~/bench/10s.wav ~/bench/30s.wav
```

Post a release update to X through the official Chrome plugin using the signed-in X web app or default Chrome profile. Treat it as complete only after opening the profile and finding the new post text plus a fresh `/status/` URL.

## Config

`ChatType` stores runtime config at:

```text
~/Library/Application Support/ChatType/config.json
```

Advanced terminology options:

- import Apple Contacts nicknames or WeChat remarks from Smart Shadow's decrypted contacts
- add custom terms and replacements in Settings
- keep `transcription.hintTerms` for exact-only hidden terms you want preserved even without importing a dictionary

## Permission Repair

`ChatType Settings` now separates first-run prompts from repair actions:

- microphone first-run access still comes from the native macOS prompt when you record for the first time
- if microphone access was denied earlier, use `Open Microphone Settings` to jump straight to `Privacy & Security > Microphone`
- if Accessibility is missing, use `Guide Accessibility Access` to open the correct settings page and show the drag-to-authorize helper for `/Applications/ChatType.app`
- `Open Accessibility Settings` remains available as a simpler fallback when you only want the deeplink
- `Refresh Status` re-checks the live permission state after you return from System Settings

## Risks And Boundaries

`ChatType` V1 deliberately depends on a private backend path plus a ChatType-managed local ChatGPT session.

That means:

- it is fast and simple for existing ChatGPT users
- it may break if upstream ChatGPT Web session or backend behavior changes
- it is not positioned as an enterprise-safe or long-term stable public API integration
- the private backend prompt path is opportunistic and falls back to plain transcription if unsupported
- Cloudflare challenge responses remain an explicit private-backend failure; ChatType preserves the recording instead of silently switching providers

## Docs

- [中文说明](README.zh-CN.md)
- [Architecture](docs/architecture.md)
- [Operations and incident response](docs/operations.md)
- [Release Process](docs/release.md)
- [Release Notes](docs/releases/v0.5.1.md)
- [Performance Notes](docs/performance.md)
- [Product PRD](docs/chattype-v1-prd.md)
- [Promotion Kit](docs/promotion/README.md)

## License

MIT. See [LICENSE](LICENSE).
