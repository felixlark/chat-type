# Activation shortcut · build 143

![Installed Settings](images/shortcut-settings-installed-143.png)

Settings → 激活快捷键 now records a key with optional Command, Option, Control and Shift modifiers. Capture pauses activation. Escape, focus loss, section changes and closing the window restore the previous shortcut. Save Settings applies the candidate immediately; an unsuccessful registration or write retains the previous binding. Workflow auto-apply leaves a pending shortcut uncommitted. The sidebar shows the applied binding.

On the enrolled Mac, physical F5 produces F18, so Settings displays F18 with a local-mapping explanation. Custom keycodes and modifiers survive the installer. No transcription or polish provider is changed by this feature.

## Independent Fn tap

The owner’s final arrangement adds short Fn as another ChatType activation key. Karabiner passes native Fn down/up through immediately and adds F18 only on a short solitary tap. Native Doubao owns long-press behavior. There is no delayed Fn, held-Fn action, or held-Fn threshold in this rule. The explicitly enrolled local `fnTap.timeoutMilliseconds` is 300 ms. This follows [Karabiner’s simple modifier tap pattern](https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/to-if-alone/).

No Fn rule is added for an unenrolled machine. Absence of `fnTap` leaves existing rules alone; disabling a previously installed rule requires removing `ChatType local keyboard: Fn tap activates ChatType`. This replaces the earlier task-local launcher rule and leaves unrelated rules intact. The event targets F18, the enrolled ChatType binding; other custom bindings retain their own key choice.

## Verification

- Implemented: recorder, transactional registration, pending/applied distinction and installation preservation.
- Checked: source harness passed 387 Swift tests, 42 Python tests, shell/policy/landing-page checks. The five targeted shortcut tests cover legacy decoding, persistence, replacement failure, capture lifecycle and workflow auto-apply.
- Reviewed: native Codex independent automatic code review of the app candidate `62f300b` and a focused review of the later Fn-only installer revision both completed with no actionable P0–P2 findings.
- Packaged: build 143; Developer ID signature and packaged-app metadata verified.
- Installed: `/Applications/ChatType.app`, build 143.
- Live Settings: official Computer Use recorded Control + Option + Shift + K, saved it, read back the applied label and persisted configuration, and cancelled a new capture with Escape. The temporary binding was restored to physical F5 / internal F18 before closeout. The tool cannot send F18 in the background, so restoration used the supported configuration and reinstall path; this is not recorded as a second recorder acceptance.
- Fn configuration: official Karabiner lint passed; active Default profile and the short-tap rule were read back. The earlier launcher rule failed the owner’s short-tap test and was replaced following their correction. Physical short Fn → ChatType behavior still needs direct keyboard evidence; native Doubao long-press configuration is untouched.
- Left running: normal installed menu-bar runtime; Settings retained for review.

The first installed launch spent roughly two minutes restoring existing history snapshots before showing Settings. A process sample identified the existing recovery scan; no history was deleted or moved.

[Before Settings](images/shortcut-settings-before-143.png)
