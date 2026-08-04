# ChatType Release Process

## Local Release Checklist

1. Run `./scripts/check.sh`
2. Run `./scripts/package_app.sh`
3. Confirm the release assets exist:
   - `dist/ChatType-0.5.1-macos-arm64.zip`
   - `dist/ChatType-0.5.1-macos-arm64.dmg`
4. Install `dist/ChatType.app` to `/Applications/ChatType.app`
5. Launch `/Applications/ChatType.app`
6. Verify setup states:
   - signed-in Codex desktop session shows as ready
   - microphone state is reported correctly
   - Accessibility state is reported correctly
   - denied microphone state exposes `Open Microphone Settings`
   - missing Accessibility exposes `Guide Accessibility Access`, `Open Accessibility Settings`, and `Refresh Status`
7. Verify runtime behavior:
   - HUD appears on `F5`
   - recording stops on second `F5`
   - missing Codex desktop install produces a clear setup blocker
   - missing ChatGPT login in Codex produces a clear setup blocker
   - first-run microphone flow still surfaces the native macOS system prompt
   - denied microphone flow jumps to `Privacy & Security > Microphone`
   - Accessibility guidance opens the correct page and shows the drag-to-authorize helper for the packaged app
   - paste only reports success when an editable focus target exists
   - clipboard fallback keeps the latest transcript available for manual `Cmd+V`
   - Settings exposes the workflow sidebar with Account, Dictation, AI Polish, Terminology, Paste, and Advanced sections
   - AI Polish shows the ChatGPT Auth rewrite route without provider-key fields
   - Advanced shows the current ChatGPT account route instead of API fallback provider lists
   - text polish can produce a concise agent-plan style output for a long dictation sample
   - terminology import is visible in Settings and reads Contacts or Smart Shadow's decrypted WeChat remarks without a file picker
   - output remains directly usable when text polish is unavailable or disabled
8. Verify advanced recovery mode:
   - switching to `OpenAI-Compatible Recovery` exposes endpoint, model, and API env settings
   - missing API key in recovery mode produces a clear setup blocker
   - if `transcription.hintTerms` exists in config.json, filenames and product names are preserved
   - simplified Chinese remains the default when the recognizer drifts into Traditional Chinese
9. Re-test from the packaged release artifacts:
   - unzip `dist/ChatType-0.5.1-macos-arm64.zip`
   - install the extracted `ChatType.app` to `/Applications/ChatType.app`
   - launch `/Applications/ChatType.app`
   - mount `dist/ChatType-0.5.1-macos-arm64.dmg`
   - install the mounted `ChatType.app` to `/Applications/ChatType.app`
   - launch `/Applications/ChatType.app`
10. Update GitHub-facing documentation for the same version before publishing the release:
   - update `README.md` and `README.zh-CN.md`
   - update `CHANGELOG.md`
   - add or update `docs/releases/vX.Y.Z.md`
   - confirm the GitHub release notes match the packaged version and default product path
11. Update the GitHub Pages landing page for the same version before announcing the release:
   - update `docs/index.html`
   - confirm the primary download link points at the new GitHub Release tag
   - keep the landing page value proposition aligned with the current README and release notes
12. If you are announcing the release on X, preview the outgoing post first and send it through the official Chrome plugin using the signed-in X web app or default Chrome profile.
   - create the post in one composer session
   - click `Post` once
   - treat the post as complete only after opening the profile and finding the new post text plus a fresh `/status/` URL
13. Update any additional docs if onboarding, naming, packaging, launch assumptions, or live verification surfaces changed.

## Public Promotion Checklist

Use `docs/promotion/README.md` as the source of truth for low-cost public promotion.

Before posting to public channels:

1. Confirm the GitHub README, GitHub release page, and GitHub Pages landing page describe the same default path: local ChatType-owned ChatGPT login, `F5` recording, transcription, optional AI Polish, safe paste, and clipboard fallback.
2. Keep the private backend dependency explicit. Do not describe the default route as a stable public API.
3. Publish Chinese social content first, then V2EX, then Hacker News or Product Hunt only after real install feedback exists.
4. Do not ask for upvotes on Hacker News or Product Hunt.
5. Submit free or low-cost AI directories first; defer paid directory placement until the first week produces real signal.
6. Keep support copy framed as optional maintenance support, not a crowdfunding campaign.

## Gatekeeper Notes

`v0.5.1` is expected to be locally signed with Apple Development or Developer ID Application and is not notarized.

`./scripts/package_app.sh` now fails fast when no stable signing identity is available. Only use `CHATTYPE_ALLOW_ADHOC_SIGNING=1` for throwaway local debugging, because ad-hoc builds can break the Accessibility repair flow.

Do not verify or repair permissions from `dist/ChatType.app`. Install the packaged app to `/Applications/ChatType.app` first so TCC binds to the real runtime path.

If macOS blocks the app:

- right-click `ChatType.app` and choose `Open`
- or remove quarantine:

```bash
xattr -dr com.apple.quarantine /path/to/ChatType.app
```

## Homebrew Cask

Keep the cask file aligned with the release artifact:

```text
packaging/homebrew/Casks/chattype.rb
```

If the asset filename or release URL format changes, update the cask in the same change.

## Follow-Up Work After v0.5.1

- notarize the `.app` or `.dmg`
- publish a dedicated Homebrew tap
- broaden first-run diagnostics for desktop-host failures
- keep benchmark samples around for 3s / 10s / 30s regression checks
