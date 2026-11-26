# Package identity and local compatibility

Current source uses the public project identity `felixlark`. A default source package has Bundle ID `io.github.felixlark.ChatType` and five separate Keychain services under that prefix. The signed package records their exact values in these Info fields:

| Logical service | Info field | Public default suffix |
| --- | --- | --- |
| ChatGPT session | `ChatTypeChatGPTSessionService` | `.chatgpt-session` |
| Doubao configuration | `ChatTypeDoubaoService` | `.doubao` |
| GLM key | `ChatTypeGLMService` | `.glm` |
| Qwen key | `ChatTypeQwenService` | `.qwen` |
| DeepSeek API key | `ChatTypeMarkpipeService` | `.markpipe` |

Service names are case-sensitive independent values. The app retains each store's existing fixed account and read/write semantics. Logging uses the actual installed Bundle ID. Product branding, data directories, saved history/vocabulary and enrolled keyboard policy remain unchanged.

## Existing local installations

Changing a Bundle ID or signing certificate can change permission and Keychain access. An existing installation requires a compatible candidate: the installer compares the Bundle ID, designated signing requirement and leaf certificate before stopping the app. An incompatible public default does not replace an older local installation.

A maintained local installation can use an explicit version-1 JSON profile outside the repository. It contains only `schemaVersion`, `bundleId`, a certificate SHA-1 `signingIdentity` selector and all five `keychainServices` entries (`chatGPTSession`, `doubao`, `glm`, `qwen`, `markpipe`). Capture those nonsecret values from the existing installation and its known source before changing identity. Keep the profile local with file mode `0600`; never put credentials, tokens, private keys or private recordings in it. Missing or invalid fields fail before building, without mixing public defaults into a partial profile.

Use the same explicit profile for packaging, checking and installation:

```bash
export CHATTYPE_IDENTITY_PROFILE="$HOME/Library/Application Support/ChatType/identity/local-compatibility.json"
export CHATTYPE_DIST_PATH="$HOME/Library/Caches/chat-type/local-identity/dist"
./scripts/package_app.sh --identity-profile "$CHATTYPE_IDENTITY_PROFILE"
./scripts/check_packaged_app.sh --existing --identity-profile "$CHATTYPE_IDENTITY_PROFILE"
./scripts/install_app.sh --identity-profile "$CHATTYPE_IDENTITY_PROFILE"
```

The installer forwards the same profile if packaging is needed. It verifies a staged candidate and retains a private original-app backup before replacement. Failure restores the original by rename and restarts it before cleaning up the failed candidate. Normal launch uses LaunchServices without activation, verifies the returned process's exact installation path, and reuses an already-running exact instance without a reopen event. Process existence and usable Ready state are separate acceptance checks.

The operator must establish that no recording, processing or input delivery is in progress before installing. This command does not infer idle from process existence. Installation preserves explicitly enrolled physical F5/keycode 79 and native Fn choices.

## Read-only credential compatibility check

The installed app has an internal `credential-read-check --output /absolute/private/result.json` branch before its normal app lifecycle. The formal installer can run it through LaunchServices and restore normal runtime afterward:

```bash
./scripts/install_app.sh --identity-profile "$CHATTYPE_IDENTITY_PROFILE" \
  --credential-read-check "$HOME/Library/Application Support/ChatType/identity/credential-check.json"
```

The result path must be new and its parent directory must be private to the current user. Output is a `0600` JSON file containing only app version/build, five logical service keys and `readable`, `notFound` or `OSStatus` results. The app performs actual data reads, discards the data, forbids authentication UI, and never creates an auth manager/provider, contacts a server, refreshes, saves or deletes credentials. It accepts no arbitrary service/account arguments. Authentication/locked-Keychain errors remain unknown compatibility results, not readable success.

For an identity change, first collect the denominator from the original identity and original queries. Previously readable services must remain readable in the compatible candidate; previously absent services stay reported as absent. A metadata-only presence check cannot establish this. Keep results and local compatible packages private.

## Evidence boundary

Public defaults, a locally compatible signed package and previously published Release assets are different objects. Local compatibility does not make a private signed package anonymous or establish an upgrade contract for all older Releases. This source change does not republish binaries, rewrite Git history, remove old Release assets, reset TCC, migrate credentials or alter product data paths. Existing historical copies remain a separate scope.
