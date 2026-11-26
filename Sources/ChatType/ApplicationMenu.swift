import AppKit

@MainActor
final class ApplicationMenuController: NSObject {
    private let showSettings: () -> Void

    init(showSettings: @escaping () -> Void) {
        self.showSettings = showSettings
        super.init()
    }

    static func install(showSettings: @escaping () -> Void) -> ApplicationMenuController {
        let controller = ApplicationMenuController(showSettings: showSettings)
        NSApplication.shared.mainMenu = controller.makeMainMenu()
        return controller
    }

    func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(applicationMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(windowMenuItem())
        return mainMenu
    }

    @objc
    private func openSettings() {
        showSettings()
    }

    private func applicationMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "ChatType")

        menu.addItem(menuItem(
            "关于 ChatType",
            action: NSSelectorFromString("orderFrontStandardAboutPanel:"),
            target: NSApplication.shared
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            "设置…",
            action: #selector(openSettings),
            keyEquivalent: ",",
            target: self
        ))

        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "服务")
        servicesItem.submenu = servicesMenu
        menu.addItem(servicesItem)
        NSApplication.shared.servicesMenu = servicesMenu

        menu.addItem(.separator())
        menu.addItem(menuItem("隐藏 ChatType", action: NSSelectorFromString("hide:"), keyEquivalent: "h", target: NSApplication.shared))
        menu.addItem(menuItem(
            "隐藏其他",
            action: NSSelectorFromString("hideOtherApplications:"),
            keyEquivalent: "h",
            modifiers: [.command, .option],
            target: NSApplication.shared
        ))
        menu.addItem(menuItem("全部显示", action: NSSelectorFromString("unhideAllApplications:"), target: NSApplication.shared))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出 ChatType", action: NSSelectorFromString("terminate:"), keyEquivalent: "q", target: NSApplication.shared))

        root.submenu = menu
        return root
    }

    private func editMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "编辑")

        menu.addItem(menuItem("撤销", action: NSSelectorFromString("undo:"), keyEquivalent: "z"))
        menu.addItem(menuItem(
            "重做",
            action: NSSelectorFromString("redo:"),
            keyEquivalent: "z",
            modifiers: [.command, .shift]
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem("剪切", action: NSSelectorFromString("cut:"), keyEquivalent: "x"))
        menu.addItem(menuItem("复制", action: NSSelectorFromString("copy:"), keyEquivalent: "c"))
        menu.addItem(menuItem("粘贴", action: NSSelectorFromString("paste:"), keyEquivalent: "v"))
        menu.addItem(menuItem("删除", action: NSSelectorFromString("delete:")))
        menu.addItem(menuItem("全选", action: NSSelectorFromString("selectAll:"), keyEquivalent: "a"))

        root.submenu = menu
        return root
    }

    private func windowMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "窗口")

        menu.addItem(menuItem("最小化", action: NSSelectorFromString("performMiniaturize:"), keyEquivalent: "m"))
        menu.addItem(menuItem("缩放", action: NSSelectorFromString("performZoom:")))
        menu.addItem(.separator())
        menu.addItem(menuItem("关闭", action: NSSelectorFromString("performClose:"), keyEquivalent: "w"))
        menu.addItem(menuItem("全部置于顶层", action: NSSelectorFromString("arrangeInFront:")))

        root.submenu = menu
        NSApplication.shared.windowsMenu = menu
        return root
    }

    private func menuItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = [.command],
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        if !keyEquivalent.isEmpty {
            item.keyEquivalentModifierMask = modifiers
        }
        item.target = target
        return item
    }
}
