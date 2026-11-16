import AppKit
import Carbon
import Foundation
import Testing
@testable import ChatType

@Test func activationShortcutDecodesLegacyConfigurationAndRoundTripsCustomBinding() throws {
    let old = try JSONDecoder().decode(AppConfig.self, from: Data("{\"transcription\":{\"hotkeyKeyCode\":79}}".utf8))
    #expect(ActivationShortcut(old.transcription) == ActivationShortcut(keyCode: 79))
    #expect(!old.transcription.hotkeyIsCustomized)
    var updated = old
    updated.transcription.hotkeyKeyCode = 40
    updated.transcription.hotkeyModifiers = UInt32(cmdKey | shiftKey)
    updated.transcription.hotkeyIsCustomized = true
    #expect(try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(updated)) == updated)
    #expect(ActivationShortcut(updated.transcription).title == "Shift + Command + K")
    #expect(ActivationShortcut.carbonModifiers([.command, .shift, .function, .capsLock]) == UInt32(cmdKey | shiftKey))
}

@Test @MainActor func shortcutRegistrationCommitsOnlyAfterRegistrationAndPersistenceSucceed() throws {
    var registrations: [ActivationShortcut] = []
    var reject = false
    let binding = ActivationShortcutRegistration { shortcut in
        if reject { throw CocoaError(.validationMissingMandatoryProperty) }
        registrations.append(shortcut)
        return NSObject()
    }
    let original = ActivationShortcut(keyCode: 79)
    let candidate = ActivationShortcut(keyCode: 40, modifiers: UInt32(cmdKey))
    try binding.replace(with: original, persist: {})
    try binding.replace(with: original, persist: {})
    #expect(registrations == [original])
    reject = true
    var wrote = false
    #expect(throws: (any Error).self) {
        try binding.replace(with: candidate, persist: { wrote = true })
    }
    #expect(!wrote && binding.shortcut == original)
    reject = false
    #expect(throws: (any Error).self) {
        try binding.replace(with: candidate, persist: { throw CocoaError(.fileWriteUnknown) })
    }
    #expect(binding.shortcut == original)
    try binding.replace(with: candidate, persist: { wrote = true })
    #expect(wrote && binding.shortcut == candidate)
    binding.suspend()
    try binding.resume()
    #expect(registrations.last == candidate)
}

@Test @MainActor func shortcutDraftCaptureCancelsAndRestoresWithoutDiscardingWorkflowEdits() {
    let draft = PreferencesDraft(config: AppConfig())
    draft.config.transcription.provider = .chatGPTManagedAuth
    let original = draft.config
    var starts = 0, ends = 0
    draft.onBeginShortcutCapture = { starts += 1 }
    draft.onEndShortcutCapture = { ends += 1 }
    draft.beginShortcutCapture()
    #expect(draft.isRecordingShortcut)
    draft.endShortcutCapture()
    draft.endShortcutCapture()
    #expect(starts == 1 && ends == 1 && draft.config == original)
    draft.beginShortcutCapture()
    draft.endShortcutCapture(ActivationShortcut(keyCode: 40, modifiers: UInt32(cmdKey)))
    #expect(ends == 2 && draft.config.transcription.hotkeyIsCustomized)
    #expect(draft.config.transcription.provider == .chatGPTManagedAuth)
    #expect(draft.hasChanges)
    draft.onBeginShortcutCapture = { throw ShortcutCaptureError.busy }
    draft.beginShortcutCapture()
    #expect(!draft.isRecordingShortcut && draft.isError)
}

@Test @MainActor func startingWithOldShortcutAppliesWorkflowWithoutCommittingPendingShortcut() {
    let original = AppConfig(), draft = PreferencesDraft(config: AppConfig())
    draft.beginShortcutCapture()
    draft.endShortcutCapture(ActivationShortcut(keyCode: 40, modifiers: UInt32(cmdKey)))
    draft.config.transcription.provider = .chatGPTManagedAuth
    _ = draft.apply(includeShortcut: false) { saved in
        #expect(saved.transcription.provider == .chatGPTManagedAuth)
        #expect(saved.transcription.hotkeyKeyCode == original.transcription.hotkeyKeyCode)
        #expect(!saved.transcription.hotkeyIsCustomized)
        return .success(())
    }
    #expect(draft.activeShortcut == ActivationShortcut(original.transcription))
    #expect(draft.shortcutHasChanges && draft.hasChanges)
    _ = draft.apply { saved in
        #expect(saved.transcription.hotkeyKeyCode == 40)
        return .success(())
    }
    #expect(!draft.shortcutHasChanges && !draft.hasChanges)
}

@Test @MainActor func shortcutRecorderIgnoresRepeatAndRestoresOnFocusLossAndEscape() throws {
    let view = ShortcutRecorder.CaptureView()
    var cancelled = 0
    var captured: ActivationShortcut?
    view.onCancel = { cancelled += 1 }
    view.onCapture = { captured = $0 }
    let repeated = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: true, keyCode: 40))
    view.keyDown(with: repeated)
    #expect(captured == nil && cancelled == 0)
    _ = view.resignFirstResponder()
    view.stop()
    #expect(cancelled == 1 && captured == nil)

    let escapeView = ShortcutRecorder.CaptureView()
    escapeView.onCancel = { cancelled += 1 }
    let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    escapeView.keyDown(with: escape)
    escapeView.stop()
    #expect(cancelled == 2)
}
