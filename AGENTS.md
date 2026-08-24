# ChatType Runbook

## Repo Scope

- Owner/escalation: Longbiao for product behavior, installed app state, and release copy.
- This repo owns the native macOS dictation app `ChatType`, packaged output under `dist/`, and the installed app path `/Applications/ChatType.app`.
- The live app path is authoritative for permission and interaction verification; `dist/ChatType.app` is packaging output only.

## Canonical Commands

- Local harness: `script/build_and_run.sh`
- Test/check harness: `scripts/check.sh`
- Package app: `scripts/package_app.sh`
- Install packaged app: `scripts/install_app.sh`
- Visual acceptance: `./scripts/visual_acceptance.sh --install`
- Installed app smoke: `scripts/check_packaged_app.sh`
- Read-only incident doctor: `scripts/doctor.sh`
- Incident and acceptance rules: `docs/operations.md`

## Routine Operations

| Trigger | Command | Expected Result | Failure Recovery |
| --- | --- | --- | --- |
| Implement app behavior fix | `scripts/check.sh` | Unit/integration checks pass | Fix the first failing test; keep paste/permission regressions covered |
| Ship usable local build | `scripts/package_app.sh` then `scripts/install_app.sh` | Fresh `dist/ChatType.app` is installed to `/Applications/ChatType.app` | Rebuild and reinstall; never launch directly from `dist` for live verification |
| Run visual acceptance | `./scripts/visual_acceptance.sh --install` | Installed app launches through LaunchServices in overlay demo mode and captures recording/processing/result/error/retryable-error evidence | Inspect generated artifact directory, fix the HUD/state mismatch, and rerun |
| Verify first-run permissions | Reset TCC for installed app path, then launch `/Applications/ChatType.app` | System permission prompt fires from `not determined` state | Do not let setup preflights request permissions before the first-run path is observed |

## Troubleshooting

| Trigger | Command | Expected Result | Failure Recovery |
| --- | --- | --- | --- |
| Output pastes into the wrong place | Inspect focused editable target and run the installed app path | Text pastes only when a focused editable target exists; otherwise it stays in clipboard | Keep paste behavior conservative and debug AX/direct insertion path before changing STT cleanup |
| HUD or hotkey interaction changed | Use official Computer Use on the installed app | `F5` starts/stops, `ESC` cancels, inline close cancels, retry/re-entry works | Fix source, rebuild, reinstall, and rerun the full interaction branch |
| Permission flow regresses | Clean TCC state and installed app launch | Accessibility/Microphone prompts appear in the expected order | Add or update automated ordering tests, then repeat installed-app proof |

## Incident Response Gates

- Before changing code, run `scripts/doctor.sh` and classify the failure as installation, lifecycle/UI, ChatType login, browser callback, transcription transport, or TCC permission. Record one current hypothesis; do not modify multiple layers to chase one symptom.
- A browser callback error does not prove ChatType login failed, and a `Ready` login state does not prove transcription works. Verify login and the business request separately.
- Classify the first `403` with HTML/Cloudflare evidence as a challenge. Do not refresh the token or call it ordinary network fluctuation; never exceed the product's bounded policy of three automatic attempts and one attempt for an explicit manual Retry.
- Never use `security find-generic-password -w` for diagnosis. Inspect Keychain entry metadata or use the signed installed app without logging secrets.
- TCC and privacy flows must launch `/Applications/ChatType.app` through LaunchServices. Never validate permissions by directly executing `Contents/MacOS/ChatType`.
- Unit tests must inject Keychain, browser, microphone, Accessibility, and network boundaries; tests may not open real system prompts.
- Keep diagnostic output bounded: safe config fields only, 15 minutes of targeted logs, at most 20 status lines, and no full Cloudflare body or terminology dictionary.

## Provider And Billing Gates

- Without explicit authorization in the current request, do not call or add any metered/pay-per-use endpoint, including `api.openai.com/v1/audio/transcriptions`. A ChatGPT OAuth token is not evidence that an OpenAI Platform request is free.
- ChatGPT OAuth tokens may go only to fixed, audited official OpenAI/ChatGPT account hosts. Never send them to a user-defined compatible endpoint.
- Adding a provider, network domain, Cookie dependency, system permission, or data destination is a product/privacy decision. Explain billing, credentials, data movement, quality, and failure behavior and obtain Longbiao's approval before implementation.
- Do not add proxy settings, extract browser Cookies, or automate around Cloudflare challenges.

## Verification

- Verification ladder: unit tests, integration tests, then real installed-app user-flow testing. The first two are prechecks only.
- For native GUI work, use official Computer Use whenever clicks, hotkeys, focus, timing, modal state, permissions, or multi-step interaction are touched.
- ChatType Computer Use acceptance should cover: focus a real editable target, start with `F5`, stop with `F5`, cancel with `ESC`, cancel with inline close, retry after cancel/error, and observe paste-versus-clipboard result.
- For closeouts, report the installed-app user flow exercised, the live verification path, the exact outcome observed, and the live ChatType state left for review.
- After build, install, scripted visual acceptance, or interaction acceptance, relaunch `/Applications/ChatType.app` as the normal installed app and leave it running. General ship closeouts should leave the menu bar app running; Settings or Terminologies work should leave that window visible when practical.
- Report `implemented`, `checked`, `packaged`, `installed`, `live accepted`, and `left running` as separate gates. A permission prompt, browser callback, upstream challenge, or unverified fallback makes the result partial, not complete.
- For auth/transcription changes, use the fixed matrix in `docs/operations.md`: cold menu-bar launch, no Dock icon/window, Settings access, `Cmd+Q`, device-code UX, login persistence, real `F5` audio, truthful error classification, Retry preservation, injection/clipboard behavior, and final normal runtime.

## Release/Deploy

- "Ship it" means run the canonical harness, build, install to `/Applications/ChatType.app`, validate installed behavior, and keep release-facing docs current.
- After any fix reaches test/acceptance green, reinstall the freshly built app, launch `/Applications/ChatType.app`, verify ChatType is still running, and leave it running before reporting completion.
- Launch copy should describe the real public path: local Codex desktop login, `F5` to record, transcription, and paste-versus-clipboard fallback.

## Guardrails

- Preserve the single-trigger workflow: `F5` starts recording and `F5` stops recording.
- Treat the existing app icon, menu-bar icon renderer, product name, colors, and other brand visuals as owner-controlled invariants. Lifecycle, authentication, transcription, and reliability fixes may not alter them without Longbiao's explicit approval in the current request.
- A visual change requires a before/after installed-app comparison and explicit approval. Checking that a menu-bar item merely exists does not prove that its approved appearance was preserved.
- Do not run `ChatType.app` directly from `dist`.
- Do not end a ChatType closeout with `pkill -x ChatType`, quit, or close. `scripts/install_app.sh` may stop the old app before replacing `/Applications/ChatType.app`, and visual demo scripts may stop transient overlay-demo processes, but final closeout must restore the normal installed runtime.
- Keep `.notDetermined` permission paths as their own regression surface.
- Keep the private ChatGPT backend dependency explicit in docs and UX; do not describe it as a stable public API.
- Keep `OpenAI-Compatible` positioned as advanced recovery, not the default public story.
- The product has exactly two transcription routes: `chatGPTManagedAuth` and user-selected `openAICompatible`. Do not add a third fallback/provider without explicit product approval.

## Known State

- `dist/ChatType.app` is build output only.
- `/Applications/ChatType.app` is the app path for launch, permission, LaunchAgent, and user-flow proof.

## Browser Automation Constraint
- Follow the global `~/.codex/AGENTS.md` official browser/GUI policy: Browser plugin for unauthenticated local/public rendering, Chrome plugin for signed-in/default-profile browser state, and Computer Use only for native desktop boundaries.
- Keep only repo-specific verification surfaces here; do not copy the full global policy block into this runbook.
