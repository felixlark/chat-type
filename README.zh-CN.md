# ChatType

[English](README.md) · [产品合同](PRODUCT.md) · [构建与发布](docs/release.md)

原生 macOS 菜单栏语音输入工具。按 **F5** 开始录音，再按 **F5** 结束，把处理完成的文字写入录音时捕获的可编辑目标；没有合适目标时，保留到剪贴板。

![ChatType 安装版状态 HUD 与单行字幕](docs/images/top-captions-installed-142.png)

## 当前行为

新配置默认使用**豆包识别与豆包文字整理**，已有服务选择保持。识别还保留 ChatType 自有 ChatGPT 登录路线和高级 OpenAI-compatible 恢复路线；润色可独立选择已批准的豆包、ChatGPT、GLM、Qwen。失败不会自动切换服务。

豆包 IME 与 ChatGPT 账户后端都是私有、随版本变化的服务。凭据只存 Keychain，不导出浏览器 Cookie 或已安装输入法的凭据。音频发给所选识别服务，相关文字发给所选润色服务；成功测试不保证今后的可用性或计费。兼容识别、GLM、Qwen 使用各自凭据与对应计费授权。

应用在私有本地历史中保存原录音、路线快照、各阶段输出和错误。处理失败不粘贴半成品。Retry 沿用原路线，历史中可明确选择用当前设置重新处理。ESC 或浮层关闭会取消活动任务，同时保留录音。

设置有四个入口：**Account、Workflow、History、Settings**。Account 区分服务安装、凭据就绪、本地预览支持与实际请求成功；Workflow 独立配置识别、术语对齐、润色和修正规则。词库支持自定义术语、替换规则及可选的通讯录／微信名称导入。History 保留录音和每次尝试的证据。

此机已登记的安排是 ChatType 使用物理 F5、豆包输入法使用物理 Fn，安装会保留该映射；其他用户保留自己的选择。安装版状态 HUD 固定在录音初始屏幕的菜单栏／摄像头安全区下方，独立单行字幕不随焦点切换停止；全文保存在恢复历史中，并只写入一次。

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

保留稳定的 Apple 签名身份，权限和交互只在真实安装版验收。签名、打包、验收与回滚见[发布说明](docs/release.md)。[Homebrew cask](packaging/homebrew/Casks/chattype.rb) 只是仓内元数据，不表示已有公开 tap。

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
- [全面清理方案与处置](docs/cleanup-2026-11-16.md)：依据、保留能力与交付状态。
- [历史证据](docs/history.md)：固定提交中的旧方案与保留的实验结果。
- [更新记录](CHANGELOG.md)：版本历史。

[MIT License](LICENSE)。
