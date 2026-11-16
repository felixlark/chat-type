# Top captions surface

Mode: Operate. The user watches live speech while continuing to work in the original app. The approved reference is video-style black-and-white captions underneath the existing compact status HUD.

The status pill stays 44pt high, centered16pt below the selected display's menu/camera safe area. Captions start12pt below it,600pt wide fitted to the visible display, with22pt medium system type and30pt line height on90% black. The latest fitting phrase is shown; older phrases leave the viewport at word boundaries. Each line is centered. These are presentation dimensions, not transcript limits.

The display is selected at recording start; subsequent focus changes do not retarget captions or stop recognition. Captions receive recognition text independently of input geometry. The original target/selection and output route remain captured separately. Final output is sealed before one delivery attempt; subtitles never write provisional text into the document.

Confirming is rendered before synchronous delivery. On its return, final captions start a fresh draw generation; only its visible drawing receipt begins the1.5s reading hold. Cancel/new-session and stale drawing/hide callbacks are isolated. Unknown output stays an attention state with a request to inspect the input, without an automatic second paste. Retry remains one action.

Keep existing app and menu-bar icons, status colors, compact controls and native keyboard behavior. The settings language in DESIGN.md is unchanged. Acceptance requires actual installed panels plus real F5 speech, focus switching, last-word visibility and exactly one verified output into the original target; static mockups are design references only.
