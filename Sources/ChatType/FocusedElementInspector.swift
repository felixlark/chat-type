import ApplicationServices
import Foundation

enum FocusedElementInspector {
    private static let textRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
    ]

    static func hasEditableTextFocus() -> Bool {
        guard AXIsProcessTrusted() else {
            return false
        }

        guard let element = focusedElement() else {
            return false
        }

        return isEditableTextFocus(element)
    }

    static func hasEditableTextFocus(in launchAppContext: LaunchAppContext?) -> Bool {
        guard
            AXIsProcessTrusted(),
            let launchAppContext,
            launchAppContext.processIdentifier > 0,
            let element = focusedElement(in: launchAppContext)
        else {
            return false
        }

        return isEditableTextFocus(element)
    }

    private static func isEditableTextFocus(_ element: AXUIElement) -> Bool {
        var roleValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        var enabledValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledValue)
        return isEditableTextFocus(
            role: roleValue as? String,
            valueIsSettable: isAttributeSettable(kAXValueAttribute, on: element),
            enabled: (enabledValue as? Bool) ?? true
        )
    }

    static func isEditableTextFocus(role: String?, valueIsSettable: Bool, enabled: Bool = true) -> Bool {
        guard let role else { return false }
        return enabled && textRoles.contains(role) && valueIsSettable
    }

    private static func focusedElement(in launchAppContext: LaunchAppContext) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(launchAppContext.processIdentifier)
        var focusedElement: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard status == .success, let focusedElement else {
            return nil
        }

        let element = focusedElement as! AXUIElement
        return element
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard
            focusedStatus == .success,
            let focusedElement
        else {
            return nil
        }

        let element: AXUIElement = focusedElement as! AXUIElement
        return element
    }

    private static func isAttributeSettable(
        _ attribute: String,
        on element: AXUIElement
    ) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element,
            attribute as CFString,
            &settable
        ) == .success && settable.boolValue
    }

}
