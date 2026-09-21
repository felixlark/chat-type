# ChatType

[English README](README.md)

`ChatType` 是一个原生 macOS 听写工具，目标就是把 `F5 -> 说话 -> 回填` 这条链路做到尽可能快、尽可能稳。

公开落地页：[longbiao.crowdsensing.cn/chat-type](https://longbiao.crowdsensing.cn/chat-type/)

它的产品取向很明确：

- 全局 `F5` 热键
- 原生菜单栏应用
- 默认由 ChatType 自己登录 ChatGPT 并维护本地会话，不要求额外 API key
- ChatGPT ASR 后可选 AI 文本润色，面向长段、给 agent 的计划型输出
- 回填策略保守：只有检测到可编辑目标时才粘贴，不行就留在剪贴板
- 默认保留最后一次转写结果在剪贴板里，方便光标丢失时手动 `Cmd+V`
- 支持导入通讯录昵称和 Smart Shadow 已解密的微信备注名，并添加自定义术语和修正
- 长句 AI 文本润色只走 ChatGPT Auth，不需要单独的润色 API key
- `OpenAI-Compatible Recovery` 只作为高级恢复路径

## 产品承诺

- 不额外订阅新的听写服务
- 默认 ASR 路径不要求 API key
- 长句润色走 ChatType 保存的 ChatGPT 登录态，不单独配置文本模型 key
- 不要求下载或维护本地模型
- 在这台 Mac 上装好 ChatType，并在应用内登录 ChatGPT，按下 `F5` 就能开始用

## 当前版本

`ChatType` `v0.5.1` 是当前公开版本。`./scripts/package_app.sh` 会生成本地签名、未 notarize 的 `.app`，以及 GitHub Release 用的 `.zip` 和 `.dmg`。

## 使用流程

1. 安装 `ChatType`
2. 把打包后的应用安装到 `/Applications/ChatType.app`，并从这个已安装路径启动
3. 打开 ChatType 设置，并在应用内完成 ChatGPT 登录
4. 首次录音时授予麦克风权限；如果之前拒绝过，可在设置页点 `Open Microphone Settings`
5. 如果希望自动回填到当前输入框，在设置页点 `Guide Accessibility Access`
6. `ChatType` 会打开正确的 Accessibility 页面，并用拖拽式引导帮助你把已安装应用授权进去
7. 如果列表里还是没有 `ChatType`，就在 Accessibility 页点击 `+`，手动添加 `/Applications/ChatType.app`
8. 把光标放到 Notes、Mail、Slack、Codex 等可编辑位置
9. 按一次 `F5` 开始录音，再按一次 `F5` 结束录音
10. `ChatType` 通过自己维护的 ChatGPT 会话把音频送到 ChatGPT 转写路径
11. 可选：在设置页里导入通讯录昵称或 Smart Shadow 已解密的微信备注名
12. 可选：在设置页启用 ChatGPT Auth 文本润色；它使用 ChatType 已保存的 ChatGPT 会话，不需要单独的润色 API key
13. `ChatType` 会先做术语对齐，再按需 AI 润色，最后再做保护性术语归一化
14. 只有检测到可编辑目标时，结果才会直接回填到当前输入位置；否则保留在剪贴板，方便手动 `Cmd+V`

## 安装

### 下载版

1. 构建并打包：

```bash
./scripts/package_app.sh
```

2. 安装到 `/Applications`：

```bash
./scripts/install_app.sh
```

如果你只是为了临时调试、确实需要 ad-hoc 签名，可以显式打开：

```bash
CHATTYPE_ALLOW_ADHOC_SIGNING=1 ./scripts/package_app.sh
```

但这不适合作为正常使用路径。较新的 macOS 上，ad-hoc build 可能会导致 Accessibility 设置里没有可切换的 `ChatType` 项；新的引导式权限修复也依赖 `/Applications/ChatType.app` 这个真实安装路径。

3. 启动已安装应用：

```bash
open -n /Applications/ChatType.app
```

不要直接运行 `dist/ChatType.app`。`dist` 里的副本只是打包产物，权限和运行时验证都必须绑定到 `/Applications/ChatType.app`。

4. 如果首次启动被 macOS 拦截：

```bash
xattr -dr com.apple.quarantine /path/to/ChatType.app
```

### Homebrew Cask 元数据

Homebrew 的 cask 元数据位于：

```text
packaging/homebrew/Casks/chattype.rb
```

目前仓库还没有单独的 Homebrew tap，但 cask 文件会跟随 release 资产保持同步。

### Release 下载

- Releases: [github.com/felixlark/chat-type/releases](https://github.com/felixlark/chat-type/releases)
- 当前版本页面：[v0.5.1](https://github.com/felixlark/chat-type/releases/tag/v0.5.1)

## 支持继续维护

首选支持入口是 GitHub Sponsors，但这个账号的公开 sponsor 页面还没有启用。在入口正式可用前，最有效的支持是试用 release、给仓库 star，并用 issue 反馈安装阻塞或工作流问题。

## 术语词库

`ChatType` 保留本地确定性术语对齐，并把它作为 AI 润色前后的安全层：

- 通过系统通讯录权限导入通讯录昵称
- 从 Smart Shadow 的微信解密联系人库中只导入非空备注名
- 在设置页里添加自定义术语和确定性替换
- 导入后的词表由 ChatType 自己保存在本地配置里
- 在 STT 和可选 AI 润色之后，对工具名、产品名和技术术语做本地对齐
- `transcription.hintTerms` 仍然保留，用于文件名等关键字的 exact-only 保留

## AI 文本润色

`v0.5.x` 新增可选的 ASR 后文本润色引擎，主要面向长段口述给 agent 的场景：去掉口头禅，按后文修正后的意图为准，保留术语大小写，并在长输入时整理成更像计划的分点输出。

润色路径和 ASR 分开，但只使用 ChatType 自己维护的 ChatGPT 登录态。设置页会展示可检查的 ChatGPT backend Responses endpoint 和模型；不再保存或调用 DeepSeek、Kimi、OpenAI、自定义 provider 的文本润色 key。

`v0.5.1` 修复了 AI Polish 与当前 ChatGPT/Codex Responses 私有入口请求格式不匹配的问题，并让设置页显示润色尝试、成功和失败次数，不再把后端失败隐藏起来。

## 高级恢复路径

如果默认的 ChatGPT 账号路径不可用，`ChatType` 仍然保留 `OpenAI-Compatible Recovery`。

默认 ChatGPT 账号路径现在会把私有 ChatGPT 转写接口返回的 Cloudflare `403` 当作可重试的网络波动处理：不会误判为 ChatType 会话过期反复 refresh，会最多尝试 3 次私有接口；如果仍失败，会保留这次录音并在 HUD 右侧显示 Retry 按钮。

但它不是默认 onboarding 的一部分。使用它需要：

- 你自己的 endpoint
- 你自己的模型配置
- 你自己的 API key 环境变量

## 构建与验证

```bash
swift build --package-path .
swift test --package-path .
./scripts/check.sh
./script/build_and_run.sh
```

如果你要测打包后的真实路径性能：

```bash
./scripts/benchmark_stt.sh ~/bench/3s.wav ~/bench/10s.wav ~/bench/30s.wav
```

如果你要发 X，现在走官方 Chrome plugin，使用已登录的 X web app 或默认 Chrome profile。只有打开 profile 并看到新帖文本和新的 `/status/` URL 后，才算发布完成。

## 配置

`ChatType` 的运行时配置保存在：

```text
~/Library/Application Support/ChatType/config.json
```

术语相关的高级选项：

- 导入通讯录昵称或 Smart Shadow 已解密的微信备注名
- 在设置页里添加自定义术语和替换
- 用 `transcription.hintTerms` 保留不想被改动的 exact-only 隐藏术语

## 权限修复

`ChatType Settings` 现在把首次系统弹窗和后续修复动作分开处理：

- 麦克风首次授权仍然走 macOS 原生系统弹窗
- 如果麦克风之前被拒绝，可点 `Open Microphone Settings` 直接跳到 `Privacy & Security > Microphone`
- 如果 Accessibility 没开，可点 `Guide Accessibility Access`，打开正确的设置页并显示针对 `/Applications/ChatType.app` 的拖拽式授权引导
- `Open Accessibility Settings` 仍然保留，作为只想直接跳转设置页时的次级入口
- `Refresh Status` 会在你从系统设置返回后重新检测实时权限状态

## 风险与边界

`ChatType` V1 默认依赖 ChatType 自己维护的本地 ChatGPT 会话和上游私有转写路径。

这意味着：

- 对已经在用 ChatGPT 的个人用户来说，它很快也很省事
- 一旦上游 ChatGPT Web 会话或私有后端行为变化，这条路径可能会失效
- 它不是企业级、长期稳定的公开 API 集成方案
- 私有后端里的 prompt 路径是 best-effort，必要时会自动回退到 plain transcription

## 相关文档

- [English README](README.md)
- [架构说明](docs/architecture.md)
- [发布流程](docs/release.md)
- [Release Notes](docs/releases/v0.5.1.md)
- [产品 PRD](docs/chattype-v1-prd.md)
- [推广物料包](docs/promotion/README.md)

## License

MIT。见 [LICENSE](LICENSE)。
