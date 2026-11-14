import AppKit

enum RecoveryReplayDecision: Equatable {
    case possiblePreviousOutput
    case partialAudio
    case unknownOriginalRoute(String)

    @MainActor static func present(_ decision: Self) -> Bool {
        let alert = NSAlert()
        switch decision {
        case .possiblePreviousOutput:
            alert.messageText = "上次输出状态待核对"
            alert.informativeText = "文字可能已经粘贴或复制。请先核对目标内容，避免重复输出。"
            alert.addButton(withTitle: "已核对，重新处理")
        case .partialAudio:
            alert.messageText = "仅重跑已保存片段"
            alert.informativeText = "原录音曾中断、取消或标记为片段。只能处理已保存内容，不能保证整段原声完整；原件保留。"
            alert.addButton(withTitle: "重跑已保存片段")
        case .unknownOriginalRoute(let title):
            alert.messageText = "旧录音没有后端记录"
            alert.informativeText = "本次将按当前流程发送给 \(title)，并保留原声。"
            alert.addButton(withTitle: "按当前流程重跑")
        }
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
