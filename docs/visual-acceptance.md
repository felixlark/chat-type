# ChatType visual and native acceptance

Unit/integration checks, packaged identity, demo rendering and real dictation prove different parts of delivery. The current journey and product contract are maintained in [operations](operations.md) and [PRODUCT](../PRODUCT.md).

## Existing installed candidate

When the intended signed candidate is already installed, collect optional demo evidence without rebuilding it:

```bash
./scripts/visual_acceptance.sh
```

Use `--install` only when this invocation is responsible for the one intended package/install pass. The script launches each demo state through LaunchServices at `/Applications/ChatType.app`, captures its identified window and verifies visible/different state images. With separate status and caption windows, window selection requires owner ChatType and exact title `ChatType Status HUD`; captions use `ChatType Captions`, and the first visible app window is not a reliable HUD identity. Verify selected CGWindowID against the installed-app window before treating it as HUD evidence.

Both successful and failed demo runs must restore the normal installed runtime. Failure cleanup waits for the demo's `open -W` process to finish before opening a fresh normal instance, checks it remains running, and preserves the original failure code.

## Evidence location

Default output is under the user's Library logs, outside the repository:

```text
~/Library/Logs/ChatType/visual-acceptance/<run-id>/
```

`CHATTYPE_VISUAL_OUT_ROOT` can select another approved log/artifact directory. Each run keeps recording, processing, result, error and retryable-error PNGs, verification.txt, the per-state logs and summary.md. Evidence must identify source candidate, installed version/build and the actual status/caption windows covered.

## Native interaction

Use official Computer Use on the installed app with accurate PID/window_id, background actions and readback; preserve human focus and windows. Agent-owned windows belong on the rightmost physical screen. Physical F5 and continuous speech/focus switching require the prepared user test when the supported background route cannot reproduce them. Do not substitute a demo, generated subtitle or injected unit-test callback for real microphone/output acceptance.

Check only changed journey branches and reuse still-valid evidence: actual F5/F5 audio, live captions, exactly one confirmed output into the captured target, ESC/close cancellation and re-entry, original-route Retry/error preservation, the clipboard outcome and affected Settings navigation/save. Record any missing branch precisely and continue until it is observed.

For a final package containing only resource/document changes, compare executable/framework identity and the relevant configuration to the live-accepted candidate before reusing its behavior evidence. Independently verify the final package version, signature, resource contents, installed identity and normal runtime. A changed version number alone does not prove or invalidate a particular behavior claim.

Leave the normal `/Applications/ChatType.app` running. For Settings cleanup, leave its verified window visible when practical. Report implemented, checked, packaged, installed, live accepted and left running separately with candidate-bound evidence.
