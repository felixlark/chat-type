# ChatType

[English](README.md) · [产品合同](PRODUCT.md) · [构建与发布](docs/release.md)

原生 macOS 菜单栏语音输入工具。按 **F5** 开始录音，再按 **F5** 结束，把处理完成的文字写入录音时捕获的可编辑目标；没有合适目标时，保留到剪贴板。

![ChatType 安装版状态 HUD 与单行字幕](docs/images/top-captions-installed-142.png)

## 当前行为

新配置默认使用**豆包识别与豆包文字整理**，已有服务选择保持。识别还保留 ChatType 自有 ChatGPT 登录路线、经 Markpipe 的 DeepSeek 整段录音识别路线和高级 OpenAI-compatible 恢复路线；润色可独立选择已批准的豆包、ChatGPT、GLM、Qwen、DeepSeek Flash。Workflow 可一键选择 DeepSeek 两段全流程。失败不会自动切换服务。

豆包 IME 与 ChatGPT 账户后端都是私有、随版本变化的服务。凭据只存 Keychain，不导出浏览器 Cookie 或已安装输入法的凭据。音频发给所选识别服务，以及用户明确选择的豆包实时预览；相关文字发给所选润色服务。DeepSeek 将完整 WAV 发到 `api.markpipe.app/v1/tools/asr`，将润色文本发到 `api.markpipe.app/v1/chat/completions`；DeepSeek ASR 不接收提示词或热词字段，因此术语对齐仍在本地随后执行。ChatGPT Auth 润色使用 `chatgpt.com` 的现有账户会话，不是 OpenAI Platform API Key；界面中的 token 数为本地估算，不是账单。成功测试不保证今后的可用性或计费。兼容识别、GLM、Qwen、DeepSeek 使用各自凭据与对应计费授权。

应用在私有本地历史中保存原录音、路线快照、各阶段输出和错误。处理失败不粘贴半成品。Retry 沿用原路线，历史中可明确选择用当前设置重新处理。ESC 或浮层关闭会取消活动任务，同时保留录音。

设置有四个入口：**Account、Workflow、History、Settings**。Account 用「实时预览、识别、润色」标明每项服务的能力，并区分安装状态、凭据保存与实际请求成功；Workflow 独立配置识别、实时预览来源、术语对齐、润色和校正规则。词库支持自定义术语、校正规则及可选的通讯录／微信名称导入。History 采用一屏详情：波形、可点击阶段、校正的词级统计，以及 ASR 原文、对齐后、润色输出三列文本。

在 **Settings → 激活快捷键** 点击「录入快捷键」，按下按键或组合键，再点击 **Save Settings** 即可生效。Esc 取消录入；保存成功前保持原绑定，自选快捷键在重装后保留。[查看安装版设置](docs/activation-shortcut-143.md)。

此机 ChatType 使用实体 F5；可选映射让 Fn 短按激活 ChatType，Fn 原事件照常透传，长按仍由豆包输入法处理。安装保留已登记的选择；其他用户保留自己的选择。安装版状态 HUD 固定在录音初始屏幕的菜单栏／摄像头安全区下方，独立单行字幕不随焦点切换停止；全文保存在恢复历史中，并只写入一次。

## 安装

从 [GitHub Releases](https://github.com/felixlark/chat-type/releases) 下载可用包，解压后把 **ChatType.app 放入 /Applications**，打开安装版，沿首次使用或修复入口授权麦克风和辅助功能。公开发布包可能早于当前源码候选，请核对实际版本。签名有效与 Apple 公证分别验证。

本机构建候选：

```bash
./scripts/check.sh --source
./scripts/package_app.sh
./scripts/check_packaged_app.sh --existing
./scripts/install_app.sh
open -g /Applications/ChatType.app
```

保留稳定的 Apple 签名身份；已有本机安装使用[显式兼容身份 profile](docs/runtime-identity.md)，同一文件贯通打包、检查和安装。公开默认身份不覆盖不同身份的原安装，私有兼容签名包不作为匿名公开制品上传。权限和交互只在真实安装版验收。签名、打包、验收与回滚见[发布说明](docs/release.md)。[Homebrew cask](packaging/homebrew/Casks/chattype.rb) 只是仓内元数据，不表示已有公开 tap。

## 使用与恢复

1. 把光标放入可编辑输入框，按 F5 开始。
2. 口述后再按 F5，应用按所选路线处理完整录音。
3. 在捕获的目标里确认输出，或手动粘贴剪贴板中的文字。
4. 失败时用 Retry，或在 History 检查保存的尝试；部分／中断录音需要明确选择重放。

选用 ChatGPT 阶段才需要 ChatGPT 登录。高级兼容识别需要自己的端点、模型和 API-key 环境变量。ChatGPT OAuth 登录不等于 OpenAI Platform 的调用或付费授权。恢复不会暗中切换提供方。

配置和私有历史位于 `~/Library/Application Support/ChatType/`，凭据留在 Keychain。录音、联系人、词库和秘密不进入仓库。权限修复沿真实安装路径的应用入口；[doctor](scripts/doctor.sh) 只读取有界诊断元数据。

## 开发与证据

```bash
./scripts/check.sh --source
./script/build_and_run.sh
```

默认 `./scripts/check.sh` 还会打包并检查一份候选，CI 使用相同的源码检查阶段。正式 Computer Use 的安装版交互、单元／集成检查、演示截图分别举证。交付后保留正常安装版运行。

- [架构](docs/architecture.md)：运行链、服务、持久化与设置状态归属。
- [运维](docs/operations.md)：诊断、服务边界与安装版验收。
- [公开示例](docs/privacy-fixtures.md)：虚构测试资料与历史结果的匿名摘要。
- [全面清理方案与处置](docs/cleanup-2026-11-16.md)：依据、保留能力与交付状态。
- [历史证据](docs/history.md)：固定提交中的旧方案与保留的实验结果。
- [更新记录](CHANGELOG.md)：版本历史。

[MIT License](LICENSE)。
