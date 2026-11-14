import Foundation
import Testing
@testable import ChatType

@Test
func accessibilityRequestSkipsPromptWhenAlreadyTrusted() {
    var didPrompt = false

    let trusted = AccessibilityPermission.requestTrustIfNeeded(
        trustCheck: { true },
        prompt: {
            didPrompt = true
            return true
        }
    )

    #expect(trusted)
    #expect(!didPrompt)
}

@Test
func accessibilityRequestPromptsWhenTrustIsMissing() {
    var didPrompt = false

    let trusted = AccessibilityPermission.requestTrustIfNeeded(
        trustCheck: { false },
        prompt: {
            didPrompt = true
            return false
        }
    )

    #expect(!trusted)
    #expect(didPrompt)
}

@Test
func injectionFallsBackToClipboardWithoutAccessibilityPermission() {
    let outcome = TextInjector.injectionOutcome(
        hasEditableTextFocus: true,
        accessibilityTrusted: false
    )

    #expect(outcome == .copiedToClipboard(reason: .accessibilityPermissionRequired))
}

@Test
func injectionFallsBackToClipboardWithoutEditableFocus() {
    let outcome = TextInjector.injectionOutcome(
        hasEditableTextFocus: false,
        accessibilityTrusted: true
    )

    #expect(outcome == .copiedToClipboard(reason: .noEditableTarget))
}

@Test
func injectionPastesWhenEditableFocusAndAccessibilityPermissionAreAvailable() {
    let outcome = TextInjector.injectionOutcome(
        hasEditableTextFocus: true,
        accessibilityTrusted: true
    )

    #expect(outcome == .pasted)
}

@Test
func injectionPlanUsesNativePasteForPlainFocusedSnapshot() {
    let snapshot = EditableTextSnapshot(
        value: "hello world",
        selectedRange: CFRange(location: 6, length: 0)
    )

    let plan = TextInjector.injectionPlan(
        text: "ChatType ",
        accessibilityTrusted: true,
        editableTextSnapshot: snapshot,
        fallbackEditableTextSnapshot: nil,
        hasEditableTextFocus: true,
        hasFallbackEditableTextFocus: false
    )

    #expect(plan == .keyPressPaste)
}

@Test
func injectionPlanUsesNativePasteForSelectedTextSnapshot() {
    let snapshot = EditableTextSnapshot(
        value: "hello brave world",
        selectedRange: CFRange(location: 6, length: 5)
    )

    let plan = TextInjector.injectionPlan(
        text: "ChatType",
        accessibilityTrusted: true,
        editableTextSnapshot: snapshot,
        fallbackEditableTextSnapshot: nil,
        hasEditableTextFocus: true,
        hasFallbackEditableTextFocus: false
    )

    #expect(plan == .keyPressPaste)
}

@Test
func injectionPlanUsesNativePasteForExistingTextSnapshot() {
    let snapshot = EditableTextSnapshot(
        value: "已有的一段 Codex 输入\n第二行",
        selectedRange: CFRange(location: 8, length: 0)
    )

    let plan = TextInjector.injectionPlan(
        text: "ChatType",
        accessibilityTrusted: true,
        editableTextSnapshot: snapshot,
        fallbackEditableTextSnapshot: nil,
        hasEditableTextFocus: true,
        hasFallbackEditableTextFocus: false
    )

    #expect(plan == .keyPressPaste)
}

@Test
func injectionPlanUsesNativePasteForFallbackSnapshotWhenLaunchAppEditorHasFocus() {
    let snapshot = EditableTextSnapshot(
        value: "hello world",
        selectedRange: CFRange(location: 11, length: 0)
    )

    let plan = TextInjector.injectionPlan(
        text: "ChatType",
        accessibilityTrusted: true,
        editableTextSnapshot: nil,
        fallbackEditableTextSnapshot: snapshot,
        hasEditableTextFocus: false,
        hasFallbackEditableTextFocus: true
    )

    #expect(plan == .keyPressPaste)
}

@Test
func injectionPlanUsesNativePasteWhenFocusedSnapshotIsOnlyCodexPlaceholder() {
    let snapshot = EditableTextSnapshot(
        value: "Ask for follow-up changes",
        selectedRange: CFRange(location: 0, length: 0)
    )

    let plan = TextInjector.injectionPlan(
        text: "ChatType",
        accessibilityTrusted: true,
        editableTextSnapshot: snapshot,
        fallbackEditableTextSnapshot: nil,
        hasEditableTextFocus: true,
        hasFallbackEditableTextFocus: false
    )

    #expect(plan == .keyPressPaste)
}

@Test
func injectionPlanUsesNativePasteForFeishuComposerAccessibilityWrapper() {
    let snapshot = EditableTextSnapshot(
        value: "发送给 项目部\n你们到时候写你的博士论文的时候,也是每个人都要有一个感知决策行动的闭环的。\u{200B}\n\u{200B}\n发送给 项目部\n\u{200B}\n\u{200B}\n\u{200B}",
        selectedRange: CFRange(location: 57, length: 0)
    )

    let plan = TextInjector.injectionPlan(
        text: "ChatType",
        accessibilityTrusted: true,
        editableTextSnapshot: snapshot,
        fallbackEditableTextSnapshot: nil,
        hasEditableTextFocus: true,
        hasFallbackEditableTextFocus: false
    )

    #expect(plan == .keyPressPaste)
}

@Test
func injectionPlanDoesNotPasteWithoutEditorSignal() {
    let plan = TextInjector.injectionPlan(
        text: "ChatType",
        accessibilityTrusted: true,
        editableTextSnapshot: nil,
        fallbackEditableTextSnapshot: nil,
        hasEditableTextFocus: false,
        hasFallbackEditableTextFocus: false
    )

    #expect(plan == .clipboardFallback(reason: .noEditableTarget))
}

@Test
func pasteReadinessRejectsLaunchAppWithoutActualEditor() {
    #expect(!TextInjector.isPasteTargetReady(
        launchAppProcessIdentifier: 101,
        frontmostProcessIdentifier: 101,
        hasEditableTextFocus: false
    ))
    #expect(!TextInjector.isPasteTargetReady(
        launchAppProcessIdentifier: 101,
        frontmostProcessIdentifier: 202,
        hasEditableTextFocus: true
    ))
    #expect(TextInjector.isPasteTargetReady(
        launchAppProcessIdentifier: 101,
        frontmostProcessIdentifier: 101,
        hasEditableTextFocus: true
    ))
}

@Test(arguments: ["AXWebArea", "AXStaticText", "AXGroup"])
func readableSelectionDoesNotEstablishEditableFocus(role: String) {
    #expect(!FocusedElementInspector.isEditableTextFocus(role: role, valueIsSettable: false))
    #expect(!FocusedElementInspector.isEditableTextFocus(role: role, valueIsSettable: true))
}

@Test(arguments: ["AXTextField", "AXTextArea", "AXComboBox"])
func textFocusRequiresWritableEnabledControl(role: String) {
    #expect(FocusedElementInspector.isEditableTextFocus(role: role, valueIsSettable: true))
    #expect(!FocusedElementInspector.isEditableTextFocus(role: role, valueIsSettable: false))
    #expect(!FocusedElementInspector.isEditableTextFocus(role: role, valueIsSettable: true, enabled: false))
}

@Test
func injectionPlanIgnoresStaleSnapshotsWithoutEditableFocusSignal() {
    let snapshot = EditableTextSnapshot(
        value: "stale editor text",
        selectedRange: CFRange(location: 0, length: 0)
    )

    let plan = TextInjector.injectionPlan(
        text: "ChatType",
        accessibilityTrusted: true,
        editableTextSnapshot: snapshot,
        fallbackEditableTextSnapshot: snapshot,
        hasEditableTextFocus: false,
        hasFallbackEditableTextFocus: false
    )

    #expect(plan == .clipboardFallback(reason: .noEditableTarget))
}

@Test
func injectionPlanUsesNativePasteWhenFocusedEditorIsNotDirectlyWritable() {
    let plan = TextInjector.injectionPlan(
        text: "ChatType",
        accessibilityTrusted: true,
        editableTextSnapshot: nil,
        fallbackEditableTextSnapshot: nil,
        hasEditableTextFocus: true,
        hasFallbackEditableTextFocus: false
    )

    #expect(plan == .keyPressPaste)
}

@Test
func injectionPlanUsesNativePasteWhenLaunchAppEditorStillHasFocus() {
    let plan = TextInjector.injectionPlan(
        text: "ChatType",
        accessibilityTrusted: true,
        editableTextSnapshot: nil,
        fallbackEditableTextSnapshot: nil,
        hasEditableTextFocus: false,
        hasFallbackEditableTextFocus: true
    )

    #expect(plan == .keyPressPaste)
}

@Test
func injectionPlanStillUsesClipboardWhenNoEditorSignalExists() {
    let plan = TextInjector.injectionPlan(
        text: "ChatType",
        accessibilityTrusted: true,
        editableTextSnapshot: nil,
        fallbackEditableTextSnapshot: nil,
        hasEditableTextFocus: false,
        hasFallbackEditableTextFocus: false
    )

    #expect(plan == .clipboardFallback(reason: .noEditableTarget))
}
