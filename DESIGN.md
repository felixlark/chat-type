---
name: ChatType Control Panel
description: Native macOS settings for a candid personal dictation studio
colors:
  accent: "SwiftUI.Color.accentColor"
  surface-sidebar: "System-managed NavigationSplitView sidebar"
  surface-group: "System GroupBox"
  surface-save-bar: "SwiftUI.Material.bar"
  text-primary: "SwiftUI.HierarchicalShapeStyle.primary"
  text-secondary: "SwiftUI.HierarchicalShapeStyle.secondary"
  status-ready: "SwiftUI.Color.green"
  status-attention: "SwiftUI.Color.orange"
  status-error: "SwiftUI.Color.red"
typography:
  product-title:
    fontFamily: "macOS system"
    size: 28
    weight: 700
  page-title:
    fontFamily: "macOS system"
    size: 34
    weight: 700
  section-title:
    fontFamily: "macOS system"
    size: 22
    weight: 600
  body:
    fontFamily: "macOS system"
    size: 16
    weight: 400
  row-title:
    fontFamily: "macOS system"
    size: 18
    weight: 600
  detail:
    fontFamily: "macOS system"
    size: 15
    weight: 400
  caption:
    fontFamily: "macOS system"
    size: 13
    weight: 400
  navigation:
    fontFamily: "macOS system"
    size: 16
    weight: 500
rounded:
  controls: "System-managed"
  containers: "System GroupBox and List"
spacing:
  text-tight: "2pt"
  text-stack: "3pt"
  compact: "4pt"
  inline-small: "6pt"
  inline: "8pt"
  row-gap: "10pt"
  group-gap: "12pt"
  editor-gap: "16pt"
  section-gap: "30pt"
  page-padding: "40pt"
  content-max-width: "980pt"
  card-padding: "24pt"
components:
  navigation-split-view:
    sidebar: "Native List with .sidebar style"
    detail: "ScrollView for settings; HSplitView for History"
  settings-group:
    container: "Native GroupBox"
  processing-picker:
    control: "Native segmented Picker"
  sidebar:
    width: "220–300pt"
  save-bar:
    material: "{colors.surface-save-bar}"
    placement: "fixed top action bar"
    padding: "32pt horizontal / 16pt vertical"
---

# Design System: ChatType Control Panel

## Overview

**Creative North Star: "Native personal studio"**

ChatType’s control panel is a useful, candid personal studio: readable service facts, restrained navigation and native macOS controls. Its AppKit window hosts SwiftUI content. System typography, dynamic system colors and SF Symbols (Apple’s system icon library) support everyday operation while the existing product name and brand assets remain owner-controlled.

This document records the implemented settings surface of 0.6.0 (157), using `ApplicationMenu.swift`, `PreferencesWindowController.swift`, `PreferencesView.swift`, `HistoryWorkspace.swift`, `TerminologyEditor.swift` and `ProcessingFlowView.swift`. It covers the reusable control-panel language, not the recording overlay or a new visual direction. Page strategy remains in `docs/control-panel-surface.md`; product commitments remain in `PRODUCT.md`.

**Key Characteristics:**
- Native `NavigationSplitView`, `List`, `GroupBox`, `Picker` and `HSplitView` structure.
- A deliberately readable macOS type scale rather than the platform's minimum 13pt body size.
- Liquid Glass is left to system navigation, bars, sheets and controls; content uses stable standard containers.
- Larger row height, padding and control sizes aligned with the 2027 Apple design refinements.
- Standard App, Edit and Window menus, including text-field editing commands.
- Local feedback beside its action; configuration save state in a fixed top action bar.

## Colors

The palette uses Apple’s dynamic semantic colors, resolved for the active macOS appearance. The frontmatter deliberately stores native API identifiers, not CSS color strings: this AppKit/SwiftUI application has no CSS color source. Web-only token renderers must not interpret these identifiers as literal paint or replace them with invented hex values.

### Primary

- **System accent** (`accent`): native List selection and bordered-prominent actions. No custom selected fills are painted behind sidebar rows or processing stages.

### Neutral

- **Sidebar** (`surface-sidebar`): supplied by `NavigationSplitView` and `.listStyle(.sidebar)`.
- **Grouped control surface** (`surface-group`): native `GroupBox` containers.
- **Save bar** (`surface-save-bar`): `.bar` material, which is system-managed and adopts Liquid Glass on supported macOS releases.
- **Primary / secondary foreground** (`text-primary`, `text-secondary`): substantive text versus supporting descriptions and metadata.

Ready, attention and error colors accompany status text and/or SF Symbols. Ready includes successful copy feedback; attention includes missing permission or pending approval; error indicates an actual failure. These semantic status roles are distinct from the selection accent.

**The Native Color Rule.** Keep system colors dynamic; resolve appearance through AppKit and SwiftUI rather than freezing sampled light-mode RGB values.

## Typography

The macOS system font supplies titles, controls and body text. Apple’s macOS default body size is 13pt, but its HIG explicitly requires testing legibility and increasing the size when the content is difficult to read. ChatType therefore uses a deliberately larger fixed scale: 16pt body, 15pt supporting copy, 18pt row titles, 22pt section titles and 34pt page titles. macOS does not provide Dynamic Type, so the layout must remain responsive as the window and text length change.

### Hierarchy

- **Product title:** 28pt bold for the sidebar identity.
- **Page title:** 34pt bold for the current destination.
- **Section title:** 22pt semibold for `GroupBox` headings.
- **Row title:** 18pt semibold for service names, group headings and prominent state.
- **Body:** 16pt regular for standard settings copy, labels and history text.
- **Detail:** 15pt for supporting descriptions; 13pt only for captions, timestamps and compact metadata.
- **Numeric information:** pagination uses monospaced digits; device codes use 26pt monospaced semibold.

**The Readability Type Rule.** Keep the macOS system font, but do not default substantive content to the platform minimum. Enlarged body and detail sizes must preserve the title → section → row → body → caption hierarchy.

## Layout

The resizable native window opens maximized to the built-in display’s `visibleFrame`, with window minimum (1240 × 760pt); the hosted root uses a 1200 × 760pt minimum. The built-in display is identified by `CGDisplayIsBuiltin=1`, not a fixed display ID or name. If no built-in display is present, the first available screen is used. A closed Settings window returns to this placement; a visible window already on the built-in display keeps the user’s position and size. `NavigationSplitView` supplies the resizable sidebar (220–300pt) and flexible detail column. There are no web breakpoints or mobile layouts.

The detail column has a fixed `.bar` action area at the top, then a scrollable page. Page padding is 40pt with a 980pt content maximum, centered in the detail column so long settings pages do not stretch into unreadable full-width lines. Native `GroupBox` cards use 24pt inner padding and 30pt section spacing. The page header stacks the 34pt title and a selectable 17pt subtitle. Sidebar destinations are Account, Workflow, History and Settings. Account uses icon-led service rows with capability labels (实时预览, 识别, 润色) and native status labels. Permissions live only in Settings, not Account. Green Doubao means installed, not a successful cloud probe; green Apple means the local analyzer reports available; green GLM/Qwen/DeepSeek means a key is saved, not that a request has been verified.

History is a full-height native `HSplitView` workspace rather than a scrolling settings page. The voice `List` scrolls independently; the detail pane stays on one screen. Long transcript columns scroll internally with hidden indicators so the page itself never grows. Other destinations recreate the ScrollView via `.id(selectedSection)` so the next page starts at the top.

Information rows use `LabeledContent` for system-aligned labels and values. Related text stacks remain close together; actions stay beside the facts they affect. The fixed top action bar keeps Open Config Folder and save status at the leading side and Save Settings at the trailing side, avoiding the macOS failure mode where critical controls at the bottom of a window are moved offscreen.

## Elevation & Depth

Content uses native depth: `GroupBox`, system list selection, materials and dividers create grouping. No custom shadows or hand-painted card borders are used. Window chrome, Liquid Glass rendering, native controls and focus rings remain macOS-managed.

**The Native Grouping Rule.** Use system containers and materials for structure; do not recreate their backgrounds, borders or shadows.

## Shapes

Buttons, fields, toggles, segmented controls, list rows, sheets and `GroupBox` containers keep their system shapes. Status labels use text plus SF Symbols without a custom capsule background. The device authorization block uses a native `GroupBox`.

## Components

### Recording HUD waveform

The Listening mark is a nine-bar mini spectrum inside the existing graphite status pill. Bars share a flat bottom baseline and grow upward; they do not mirror around a center line. The profile changes every audio tick from the live input level plus a moving, asymmetric spectral contour, so quiet speech remains alive without turning into decorative motion. Processing reuses the same flat-baseline geometry for its traveling pulse. Keep the approved graphite, mist and ice-blue palette and the existing HUD dimensions.

Across recording, processing, success, error and retryable-error states, the leading visual, the complete title/description text block, the timer and the inline controls share one bottom edge. The text block remains centered as a block; do not center a small icon against a two-line error.

### Buttons

Use native default or bordered buttons for ordinary actions, bordered-prominent for the relevant connection, save, or device-code action, and borderless text actions only for compact secondary affordances. Primary History, Account and Settings actions use the large native control size; icon-only copy controls expose at least a 28–32pt hit area. Save Settings is the window’s default keyboard action. Sidebar navigation uses native List selection; Workflow and History stage selection use native segmented controls. Focus, hover, pressed, Liquid Glass and disabled appearances are supplied by macOS. Icon-only history, key-management and pagination actions have accessible labels and help text.

### Cards / Containers

The reusable settings section is a native `GroupBox` containing an 22pt section title, 15pt supporting copy and vertically stacked content with 24pt padding. Readiness rows pair a status symbol, title and subtitle without a second custom surface. Native dividers separate logical groups. List and form rows use enlarged padding to match the 2027 platform updates.

### Inputs / Fields

Native TextField, SecureField, Picker and Toggle remain the form vocabulary. Controls use `.large` on macOS 13 and `.extraLarge` on macOS 14+, where available, and their labels inherit the 16pt body/control scale. Search uses a rounded-border field. Secure key entry opens a native settings sheet with the field focused, 16pt explanatory text and a native Save/Cancel footer; this state is separate from request availability and configuration save status. Descriptions and history text can be selected, while TextFields receive standard editing commands through the app’s Edit menu. No custom focus ring or validation animation is defined.

### Navigation

The sidebar is a native `.listStyle(.sidebar)` List with four icon-and-label destinations and an F5 reminder at its foot. Selection, keyboard navigation, focus and collapse behavior belong to `NavigationSplitView` and `List`. The app installs standard App, Edit and Window menus; the Edit menu is required for native text-field Copy, Paste and Select All.

### Processing picker and inspector

Six stages—录音, 识别, 对齐, 润色, 校正 and 输出—use one native segmented `Picker` inside a `GroupBox`. The selected stage’s service caption sits below it. The 录音 stage includes an explicit live-preview source picker: follow the recognizer, use Doubao streaming preview, or use Apple SpeechAnalyzer when ChatGPT recognition is selected. Selecting a stage changes the native option controls and the `LabeledContent` rows for 输入, 运行于, 输出 plus the explanation below; 识别 is the initial selection. The inspector makes model, service and destination facts readable and selectable.

### Vocabulary editor

The 对齐 stage contains Custom phrases; 修正 contains Replacement. Each editor has a fixed entry type, keeping canonical spelling and explicit corrections in their workflow positions. Search indexing runs off the UI thread. Add/update fields precede a divider, search and source filtering. The source picker is fixed (240pt). A native inset list pages at 50 entries; its height ranges 440–640pt, ideal 520pt. Entry text uses 16pt body type and provenance uses 13pt caption type beside borderless Edit/Delete actions. Empty state, import progress and bounded local feedback occupy their own slots. “Read X names” reports the read operation; the top action bar owns configuration save state.

### History workspace

A native `List` sits beside a flexible detail pane in `HSplitView`. Each voice appears once, with status, time, target, duration, a two-line preview and a six-segment stage rail. Native row selection loads the full record on demand; search uses a native field and filters use a segmented `Picker` over lightweight metadata.

The detail pane is one fixed screen: the original waveform/player comes first, followed by status metadata and exactly two whole-flow actions, 重试原路线 and 按当前流程重跑. There is no top copy button, no stage-level rerun row and no processing-evidence block. Below the actions, a six-item segmented `Picker` selects the stage; the selected stage shows its narrative and state. The 校正 stage reports word-level changes as a count, unique-word count and sampled before/after pairs.

The text chain has three columns: ASR 原文, 对齐后 and 润色输出 (the final, corrected output when corrections exist). Each column has a copy button and its text is selectable; columns scroll internally without a visible scrollbar. The column surface has no tap gesture competing with text selection. Corpus-level scrolling is intentionally absent.

Error text is explicitly labeled by its content and uses the error color. Copy feedback fades in with ease-out (0.12s), stays about (1.5s) and fades out (0.18s); this is local confirmation, not a global motion system.

### Save bar

The fixed top action bar uses `.bar` material and is the single configuration save-status location. It presents normal, unsaved, saved or error text on one selectable line with a help tooltip and a default-action Save Settings button. The bar stays above scrolling content, so it is visible at every window position. Immediate native operations, such as the login-item switch, explain their own timing near the control.

## Do's and Don'ts

### Do:
- **Do** preserve the product name, app icon, dynamic menu-bar icon and existing brand colors.
- **Do** use native split views, lists, group boxes, buttons, fields, pickers, toggles, sheets, focus treatment and disabled states.
- **Do** keep the standard Edit menu installed so text fields get the system editing shortcuts.
- **Do** prefer system materials and Liquid Glass rendering over custom card backgrounds.
- **Do** accompany readiness and errors with meaningful labels or symbols.
- **Do** show operation feedback near the action and configuration save status in the fixed top bar.
- **Do** reset the page scroll position when changing sidebar destinations.

### Don't:
- **Don’t** freeze dynamic semantic colors into sampled hex values.
- **Don’t** substitute decorative display fonts for the native operating interface.
- **Don’t** invent custom hover colors, shadows, selection fills or motion for controls that use system defaults.
- **Don’t** add parent tap gestures over selectable text or text fields.
- **Don’t** treat a local “Read names” result as proof that configuration was saved.
- **Don’t** change owner-controlled brand visuals without explicit approval.

## Apple References

Checked against official Apple documentation on 2026-11-26:

- [Human Interface Guidelines: Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- [Human Interface Guidelines: Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- [Human Interface Guidelines: Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Human Interface Guidelines: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Human Interface Guidelines: Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Apple Developer: Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [WWDC26 iOS guide](https://developer.apple.com/wwdc26/guides/ios/)
- [WWDC26 Design guide](https://developer.apple.com/wwdc26/guides/design/)
