import AppKit

@MainActor
protocol StatusMenuUpdating: AnyObject {
    func update(state: StatusMenuVisualState, detail: String)
    func ensureVisible()
}

extension StatusMenuUpdating {
    func ensureVisible() {}
}

@MainActor
struct StatusMenuButtonPresentation {
    let title: String
    let image: NSImage
    let imagePosition: NSControl.ImagePosition
    let imageScaling: NSImageScaling
    let accessibilityLabel: String
    let toolTip: String

    static func approved(for state: StatusMenuVisualState) -> StatusMenuButtonPresentation {
        StatusMenuButtonPresentation(
            title: "",
            image: ChatTypeStatusIconRenderer.image(for: state),
            imagePosition: .imageOnly,
            imageScaling: .scaleProportionallyDown,
            accessibilityLabel: "ChatType \(state.stateDescription)",
            toolTip: "ChatType: \(state.stateDescription)"
        )
    }

    func apply(to button: NSStatusBarButton) {
        button.title = title
        button.image = image
        button.imagePosition = imagePosition
        button.imageScaling = imageScaling
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = toolTip
    }
}

@MainActor
final class StatusMenuController: NSObject, StatusMenuUpdating {
    private static let autosaveName = "ChatTypeMenuBarItemV2"

    private let statusItem: NSStatusItem
    private let stateItem = NSMenuItem(title: "State: idle", action: nil, keyEquivalent: "")
    private let detailItem = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
    private let openSettingsHandler: () -> Void
    private let openConfigHandler: () -> Void
    private let quitHandler: () -> Void

    init(
        openSettingsHandler: @escaping () -> Void,
        openConfigHandler: @escaping () -> Void,
        quitHandler: @escaping () -> Void
    ) {
        self.openSettingsHandler = openSettingsHandler
        self.openConfigHandler = openConfigHandler
        self.quitHandler = quitHandler
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.autosaveName = Self.autosaveName
        configureMenu()
        update(state: .ready, detail: "Ready. Press F5 to dictate")
        ensureVisible()

        DispatchQueue.main.async { [weak self] in
            self?.ensureVisible()
        }
    }

    func update(state: StatusMenuVisualState, detail: String) {
        if let button = statusItem.button {
            StatusMenuButtonPresentation.approved(for: state).apply(to: button)
        }

        stateItem.title = "State: \(state.stateDescription)"
        detailItem.title = detail
    }

    func ensureVisible() {
        statusItem.isVisible = true
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.addItem(stateItem)
        menu.addItem(detailItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let openConfigItem = NSMenuItem(
            title: "Open Config Folder",
            action: #selector(openConfigFolder),
            keyEquivalent: ""
        )
        openConfigItem.target = self
        menu.addItem(openConfigItem)

        let quitItem = NSMenuItem(
            title: "Quit ChatType",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc
    private func openSettings() {
        openSettingsHandler()
    }

    @objc
    private func openConfigFolder() {
        openConfigHandler()
    }

    @objc
    private func quitApp() {
        quitHandler()
    }
}
