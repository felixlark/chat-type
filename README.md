# ChatType

[中文](README.zh-CN.md) · [Product contract](PRODUCT.md) · [Build and release](docs/release.md)

A native macOS menu bar dictation app. Press **F5** to record, press **F5** again to finish, and send the final text to the captured editable target. Without a suitable target, the text stays in the clipboard.

![Installed ChatType status HUD and single-line captions](docs/images/top-captions-installed-142.png)

## Current behavior

New configurations use **Doubao IME recognition and text organization**. Existing service choices are preserved. Recognition also supports the ChatType-managed ChatGPT account route and advanced OpenAI-compatible recovery; text polish independently supports the approved Doubao, ChatGPT, GLM and Qwen choices. Failures never automatically change services.

Doubao IME and the ChatGPT account backend are private, version-sensitive services. Credentials stay in Keychain; ChatType does not export browser Cookies or installed IME credentials. Audio goes to the selected recognizer and relevant text to the selected polisher. Successful tests do not guarantee future availability or billing. Optional compatible, GLM and Qwen routes need their own credentials and applicable billing authorization.

The app preserves recordings, route snapshots, stage outputs and errors in private local history. Processing failure does not paste a partial result. Retry reuses the original route; history can explicitly reprocess with current settings. ESC and the inline close cancel the active task while retaining the recording.

Settings has four destinations: **Account, Workflow, History and Settings**. Account separates installed services, credential readiness and local-preview support from actual request success. Workflow independently configures recognition, terminology alignment, polish and correction. Local vocabulary supports custom terms, replacement rules and optional Contacts/WeChat name imports. History retains recordings and per-attempt evidence.

In **Settings → 激活快捷键**, click **录入快捷键**, press a key or modifier combination, then **Save Settings**. Escape cancels capture. The previous binding stays active until saving succeeds; custom shortcuts survive reinstalling. See the [installed shortcut settings](docs/activation-shortcut-143.md).

This Mac’s enrolled arrangement uses physical F5 for ChatType; an optional short Fn tap activates ChatType while native Doubao retains its own held-Fn behavior. Installation preserves enrolled choices; other users keep their own choices. The installed status HUD stays below the initial screen's menu/camera safe area; independent single-line captions continue after focus changes. Full text remains in recovery history and is delivered once.

## Install

Download an available package from [GitHub Releases](https://github.com/felixlark/chat-type/releases), extract it and install **ChatType.app in /Applications**. Open the installed app and grant the required Microphone and Accessibility permissions through its first-run/repair flow. Public release assets may precede the current source candidate; verify the version you install. Signature validity and Apple notarization are separate properties.

For a locally built candidate:

```bash
./scripts/check.sh --source
./scripts/package_app.sh
./scripts/check_packaged_app.sh --existing
./scripts/install_app.sh
open -g /Applications/ChatType.app
```

Keep a stable Apple signing identity. Run only the installed app for permission and interaction verification. See [release instructions](docs/release.md) for signing, packaging, acceptance and rollback. Homebrew cask metadata lives in [packaging](packaging/homebrew/Casks/chattype.rb); it is not a claim that a public tap is available.

## Use and recovery

1. Place the cursor in an editable field and press F5.
2. Dictate, then press F5 again. The app processes the complete recording using your selections.
3. Observe confirmed output in the captured target, or paste the retained clipboard text manually.
4. If processing fails, use Retry or review the saved attempt in History. Partial/interrupted audio requires an explicit replay decision.

ChatGPT login is required when you select a ChatGPT stage. Advanced compatible recognition requires your endpoint, model and API-key environment variable. A ChatGPT OAuth session does not authorize or pay for OpenAI Platform requests. No service switch occurs as a hidden recovery action.

Configuration and private history live under `~/Library/Application Support/ChatType/`; credentials stay in Keychain. Keep recordings, contacts, vocabulary and secrets out of the repository. Use the app's permission repair flow at the installed path; [doctor](scripts/doctor.sh) provides bounded, read-only diagnostic metadata.

## Development and evidence

```bash
./scripts/check.sh --source
./script/build_and_run.sh
```

The default `./scripts/check.sh` additionally packages and checks one candidate. CI uses the same source-check phase. Installed interaction through official Computer Use is separate from unit/integration checks and demo screenshots. Leave the normal installed app running after delivery.

- [Architecture](docs/architecture.md): runtime, services, persistence and settings ownership.
- [Operations](docs/operations.md): diagnosis, provider boundaries and installed acceptance.
- [Public examples](docs/privacy-fixtures.md): fictional fixtures and anonymized historical summaries.
- [Cleanup plan and disposition](docs/cleanup-2026-11-16.md): evidence, retained capabilities and delivery status.
- [Historical evidence](docs/history.md): immutable prior designs and retained experimental results.
- [Changelog](CHANGELOG.md): version history.

[MIT License](LICENSE).
