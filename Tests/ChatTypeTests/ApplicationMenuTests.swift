import AppKit
import Testing
@testable import ChatType

@Test @MainActor
func applicationMenuInstallsStandardEditingCommands() throws {
    let controller = ApplicationMenuController(showSettings: {})
    let menu = controller.makeMainMenu()
    let edit = try #require(menu.items.first(where: { $0.title == "编辑" })?.submenu)

    let commands: [(String, String, Selector)] = [
        ("撤销", "z", NSSelectorFromString("undo:")),
        ("重做", "z", NSSelectorFromString("redo:")),
        ("剪切", "x", NSSelectorFromString("cut:")),
        ("复制", "c", NSSelectorFromString("copy:")),
        ("粘贴", "v", NSSelectorFromString("paste:")),
        ("删除", "", NSSelectorFromString("delete:")),
        ("全选", "a", NSSelectorFromString("selectAll:")),
    ]

    for (title, key, selector) in commands {
        let item = try #require(edit.items.first(where: { $0.title == title }))
        #expect(item.keyEquivalent == key)
        #expect(item.action == selector)
        #expect(item.target == nil)
        if !key.isEmpty {
            #expect(item.keyEquivalentModifierMask.contains(.command))
        }
    }
}

@Test @MainActor
func applicationMenuKeepsNativeWindowAndQuitCommands() throws {
    let controller = ApplicationMenuController(showSettings: {})
    let menu = controller.makeMainMenu()

    let app = try #require(menu.items.first?.submenu)
    let quit = try #require(app.items.first(where: { $0.title == "退出 ChatType" }))
    #expect(quit.keyEquivalent == "q")
    #expect(quit.keyEquivalentModifierMask.contains(.command))

    let window = try #require(menu.items.first(where: { $0.title == "窗口" })?.submenu)
    let close = try #require(window.items.first(where: { $0.title == "关闭" }))
    #expect(close.keyEquivalent == "w")
    #expect(close.keyEquivalentModifierMask.contains(.command))
}
