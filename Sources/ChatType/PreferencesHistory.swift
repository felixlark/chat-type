import AppKit
import SwiftUI

extension PreferencesView {
    func refreshTextPolishStatus() {
        usage.refresh()
    }

    var polishStatusSection: some View {
        let provider = config.transcription.textPolish.provider
        let usage = textPolishUsage[provider] ?? TextPolishUsage()
        let ready = provider == .qwenFlash
            ? qwenKeySaved
            : provider == .glmFlash
                ? glmKeySaved
                : provider == .deepSeekFlash
                    ? markpipeKeySaved
                : provider == .doubaoIME
                    ? true
                    : authSnapshot.state == .ready
        let detail: String
        switch provider {
        case .doubaoIME:
            detail = "仅发送整理输入文本到 ime.doubao.com。无须账户登录，服务可用性与费用未作保证；未实测前不显示已连接。"
        case .chatGPTAuth:
            detail = ready
                ? "账户已连接。模型：\(config.transcription.textPolish.chatGPTResponseModel)。使用 ChatGPT 账户会话，不调用 OpenAI Platform API；实际额度由账户决定。"
                : authSnapshot.detail
        case .glmFlash:
            detail = ready ? "GLM 密钥已保存；润色时会检查服务可用性。" : "请先保存 GLM API Key。"
        case .qwenFlash:
            detail = ready ? "Qwen 密钥已保存；免费额度和计费遵循你的北京账户。" : "请先保存 Qwen API Key。"
        case .deepSeekFlash:
            detail = ready ? "DeepSeek API 密钥已保存；润色会校验 DeepSeek 文本端点。" : "请先保存 DeepSeek API Key。"
        }

        return HStack(alignment: .top, spacing: 16) {
            SettingsIconBadge(
                symbol: ready ? "checkmark" : "exclamationmark",
                tone: ready ? .ready : .attention,
                size: 40
            )

            VStack(alignment: .leading, spacing: 7) {
                Text("\(provider.title) 润色")
                    .font(SettingsTypography.rowTitle)
                Text(detail)
                    .font(SettingsTypography.detail)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                Text(provider == .doubaoIME
                    ? "记录：\(usage.attempts) 次尝试，\(usage.succeeded) 次完成；服务未提供 token 用量与费用。"
                    : "本地估算：\(usage.attempts) 次尝试，\(usage.succeeded) 次完成，约 \(usage.inputTokens) 输入 / \(usage.outputTokens) 输出 token；不是服务账单。")
                    .font(SettingsTypography.caption)
                    .foregroundStyle(.secondary)
                if unattributedPolishAttempts > 0 {
                    Text("\(unattributedPolishAttempts) 次尝试的提供方未知（包括失败尝试）。")
                        .font(SettingsTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(nsColor: .separatorColor).opacity(0.25), lineWidth: 1)
        )
    }
}
