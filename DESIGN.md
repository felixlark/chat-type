---
name: ChatType Control Panel
description: Native macOS settings for a candid personal dictation studio
colors:
  accent: "SwiftUI.Color.accentColor"
  surface-group: "NSColor.controlBackgroundColor"
  surface-row: "NSColor.textBackgroundColor"
  surface-footer: "NSColor.windowBackgroundColor"
  text-primary: "SwiftUI.HierarchicalShapeStyle.primary"
  text-secondary: "SwiftUI.HierarchicalShapeStyle.secondary"
  status-ready: "SwiftUI.Color.green"
  status-attention: "SwiftUI.Color.orange"
  status-error: "SwiftUI.Color.red"
typography:
  product-title:
    fontFamily: "macOS system"
    fontSize: "24pt"
    fontWeight: 600
  page-title:
    fontFamily: "macOS system"
    fontSize: "22pt"
    fontWeight: 600
  section-title:
    fontFamily: "macOS system"
    fontSize: "13pt"
    fontWeight: 600
  body:
    fontFamily: "macOS system"
    fontSize: "12pt"
    fontWeight: 400
  row-title:
    fontFamily: "macOS system"
    fontSize: "12pt"
    fontWeight: 600
  detail:
    fontFamily: "macOS system"
    fontSize: "11pt"
    fontWeight: 400
rounded:
  row: "8pt"
  group: "12pt"
spacing:
  text-tight: "2pt"
  text-stack: "3pt"
  compact: "4pt"
  inline-small: "6pt"
  inline: "8pt"
  row-gap: "10pt"
  group-gap: "12pt"
  card-padding: "14pt"
  editor-gap: "16pt"
  flow-padding: "18pt"
  section-gap: "20pt"
  page-padding: "22pt"
components:
  settings-card:
    backgroundColor: "{colors.surface-group}"
    typography: "{typography.body}"
    rounded: "{rounded.group}"
    padding: "{spacing.card-padding}"
  information-row:
    backgroundColor: "{colors.surface-row}"
    rounded: "{rounded.row}"
    padding: "10pt"
  processing-inspector:
    backgroundColor: "{colors.surface-group}"
    rounded: "{rounded.group}"
    padding: "{spacing.flow-padding}"
  sidebar:
    backgroundColor: "{colors.surface-group}"
    width: "180pt"
  save-bar:
    backgroundColor: "{colors.surface-footer}"
    padding: "{spacing.editor-gap}"
---

# Design System: ChatType Control Panel

## Overview

**Creative North Star: "Native personal studio"**

ChatType’s control panel is a useful, candid personal studio: readable service facts, restrained navigation and native macOS controls. Its AppKit window hosts SwiftUI content. System typography, dynamic system colors and SF Symbols (Apple’s system icon library) support everyday operation while the existing product name and brand assets remain owner-controlled.

This document records the implemented settings surface of 0.6.0 (134), using `PreferencesWindowController.swift`, `TerminologyEditor.swift` and `ProcessingFlowView.swift`. It covers the reusable control-panel language, not the recording overlay or a new visual direction. Page strategy remains in `docs/control-panel-surface.md`; product commitments remain in `PRODUCT.md`.

**Key Characteristics:**
- Dynamic macOS semantic surfaces and one system accent.
- Compact system typography with a clear title, section and detail hierarchy.
- Flat grouped content, small rounded rows and native control behavior.
- Local feedback beside its action; configuration save state in the persistent bottom bar.

## Colors

The palette uses Apple’s dynamic semantic colors, resolved for the active macOS appearance. The frontmatter deliberately stores native API identifiers, not CSS color strings: this AppKit/SwiftUI application has no CSS color source. Web-only token renderers must not interpret these identifiers as literal paint or replace them with invented hex values.

### Primary

- **System accent** (`accent`): existing selection accent and native prominent actions. The sidebar applies opacity (0.14), the processing-stage selection (0.12), and the device sign-in inset uses a light accent fill (0.08) and stroke (0.28). These are per-component treatments, not new palette colors.

### Neutral

- **Grouped control surface** (`surface-group`): sidebar, settings cards and processing inspector.
- **Readable inset surface** (`surface-row`): service facts, compact readiness tiles and history rows.
- **Window surface** (`surface-footer`): persistent save bar; content otherwise inherits its native hosting background.
- **Primary / secondary foreground** (`text-primary`, `text-secondary`): substantive text versus supporting descriptions and metadata.

Ready, attention and error colors accompany status text and/or SF Symbols. Ready includes successful copy feedback; attention includes missing permission or pending approval; error indicates an actual failure. These semantic status roles are distinct from the selection accent.

**The Native Color Rule.** Keep system colors dynamic; resolve appearance through AppKit and SwiftUI rather than freezing sampled light-mode RGB values.

## Typography

The macOS system font supplies titles, controls and body text. Semibold and medium establish hierarchy; there is no custom display font. Native SwiftUI `.headline`, `.callout`, `.caption` and `.title2` roles remain semantic styles, with sizes resolved by macOS rather than inferred from screenshots. Numeric frontmatter weights describe the SwiftUI regular/medium/semibold roles; code remains authoritative.

### Hierarchy

- **Product / page title:** the two large semibold roles identify the app and current destination.
- **Section title:** semibold card headings, with a compact regular body below.
- **Row title:** medium or semibold facts, statuses and labels; terminology entry text uses system medium (13pt).
- **Detail:** secondary descriptions; history timestamps, outcomes and usage metadata use compact system text (10pt) within those specialized rows. This small metadata is not a general body-text size.
- **Semantic roles:** captions for breadcrumb, footer, field labels and counts; callout for explanations; headline for the selected processing stage. Native defaults are retained where no override exists.
- **Numeric information:** pagination uses monospaced digits. The device-code value alone uses system monospaced semibold (20pt) for copying a code.

**The Native Type Rule.** Use the macOS system font and the observed semantic or point-size roles; preserve the native title hierarchy.

## Layout

The resizable native window opens at (980 × 720pt) with window minimum (940 × 680pt); the hosted root has its own lower minimum (920 × 640pt). A fixed-width sidebar sits beside a divider and flexible content column. There are no web breakpoints or mobile layouts.

The content column has a scrollable page above a persistent divider and save bar. Page padding, card spacing and compact row spacing use the frontmatter roles. The page header stacks a native caption breadcrumb, page title and secondary subtitle. Sidebar destinations are Account, Workflow, History and Settings. Account uses matching provider rows with a status dot and explicit state labels. Green Doubao means installed, not a successful cloud probe. Apple preview support does not imply a prepared model or a local final transcription provider. Changing destination recreates the ScrollView via `.id(selectedSection)` so the next page starts at the top.

Information rows align labels and values horizontally with flexible trailing space. Service facts use a fixed label column (90pt); processing details use (64pt). Related text stacks remain close together; actions stay beside the facts they affect. The bottom bar keeps Open Config Folder at the leading edge and save status plus Save Settings at the trailing edge.

## Elevation & Depth

Content is flat: semantic background contrast, spacing and native dividers create the grouping. Settings cards, rows and the processing inspector have no custom shadows. Window chrome, native controls and focus rendering remain macOS-managed. The accent sign-in inset has a thin native-color stroke (1pt), a localized emphasis rather than a general card border.

**The Flat Grouping Rule.** Use semantic background contrast and native dividers for structure; content cards and rows do not add custom shadows.

## Shapes

Groups use the larger rounded role; nested rows and selected navigation/stage items use the smaller role. Native buttons, fields, segmented controls and list styling keep their system shapes. Authentication status helper pills use Capsule; the device sign-in inset and code have localized rounding (10pt and 7pt), not additional global radius steps.

## Components

### Buttons

Use native default or bordered buttons for ordinary actions, bordered-prominent for the relevant connection or device-code action, and borderless text actions inside vocabulary rows. Save Settings is the window’s default keyboard action. Sidebar and processing selectors use plain buttons with explicit selected fills. Focus, hover, pressed and disabled appearances are supplied by macOS; no custom states are implied by this document. Icon-only history and pagination actions have accessible labels and history actions have help text.

### Cards / Containers

The reusable settings card contains a semibold section title and vertically stacked content. Full-width grouped background and generous inner padding distinguish it from the smaller, lighter fact rows inside. Readiness tiles pair a status symbol with title and subtitle; they share available row width. Native dividers separate logical groups without ornamental borders.

### Inputs / Fields

Native TextField, SecureField, Picker and Toggle remain the form vocabulary. Search uses rounded-border field styling. Secure key entry places Save Key and key-storage state next to the field; this state is separate from request availability and configuration save status. Explanations wrap where the source explicitly requests it. No custom focus ring or validation animation is defined.

### Navigation

The narrow sidebar has an app heading, four icon-and-label destinations and an F5 reminder at its foot. Each row uses horizontal padding (12pt), vertical padding (9pt) and a small rounded selected background. Symbols use a fixed icon column (18pt). Text retains its native foreground; selection is a restrained accent tint.

### Processing trail and inspector

Six equally flexible stage buttons—Voice, Recognize, Align, Polish, Correct and Paste—form one horizontal trail with secondary chevrons between stages. Stage icons (17pt) sit above medium labels (11pt); row padding is vertical (12pt). Selecting a stage changes the Input, Runs on, Output and explanation below; Recognize is the initial selection. The inspector makes model, service and destination facts readable and selectable. It documents the currently displayed configuration; a caption explains when saved changes take effect.

### Vocabulary editor

The Align stage contains Custom phrases; Correct contains Replacement. Each editor has a fixed entry type, keeping canonical spelling and explicit corrections in their workflow positions. Search indexing runs off the UI thread. Add/update fields precede a divider, search and source filtering. The source picker is fixed (180pt); the segmented selector has a maximum (390pt). A native inset list pages at (50 entries); its height ranges (280–420pt), ideal (360pt). Entry text and provenance sit beside borderless Edit/Delete actions. Empty state, import progress and bounded local feedback occupy their own slots. “Read X names” reports the read operation; the bottom bar owns configuration save state.

### History rows and feedback

A native segmented picker chooses record type. Compact rows put metadata above a selectable, two-line text preview with adjacent Copy/Retry actions. Error text is explicitly labeled by its content and uses the error color. Copy feedback fades in with ease-out (0.12s), stays about (1.6s) and fades out (0.18s); this is local confirmation, not a global motion system.

### Save bar

The persistent footer is the single configuration save-status location. It presents normal, unsaved, saved or error text with a two-line limit and a default-action Save Settings button. Immediate native operations, such as the login-item switch, explain their own timing near the control.

## Do's and Don'ts

### Do:
- **Do** preserve the product name, app icon, dynamic menu-bar icon and existing brand colors.
- **Do** use native buttons, fields, pickers, toggles, focus treatment and disabled states.
- **Do** accompany readiness and errors with meaningful labels or symbols.
- **Do** show operation feedback near the action and configuration save status in the bottom bar.
- **Do** reset the page scroll position when changing sidebar destinations.

### Don't:
- **Don’t** freeze dynamic semantic colors into sampled hex values.
- **Don’t** substitute decorative display fonts for the native operating interface.
- **Don’t** invent custom hover colors, shadows or motion for controls that use system defaults.
- **Don’t** treat a local “Read names” result as proof that configuration was saved.
- **Don’t** change owner-controlled brand visuals without explicit approval.
