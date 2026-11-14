# ChatType

[English README](README.md)

`ChatType` 是一个原生 macOS 听写工具，目标就是把 `F5 -> 说话 -> 回填` 这条链路做到尽可能快、尽可能稳。

公开落地页：[longbiao.crowdsensing.cn/chat-type](https://longbiao.crowdsensing.cn/chat-type/)

它的产品取向很明确：

- 全局 `F5` 热键
- 原生菜单栏应用
- 全新配置默认豆包识别与豆包整段整理；旧配置保留已保存的选择
- Dictation 六个阶段可独立设置：实时预览、识别、术语对齐、润色、修正、粘贴或仅复制
- 保留原 ChatGPT 路线：应用自己的登录态、macOS 26+ 本地预览、完整录音账户转写及整段润色
- 回填策略保守：只有检测到可编辑目标时才粘贴，不行就留在剪贴板
- 默认保留最后一次转写结果在剪贴板里，方便光标丢失时手动 `Cmd+V`
- 支持导入通讯录完整姓名、昵称和微信备注名、昵称，并添加自定义术语和修正
- 识别和润色可分别选择豆包或 ChatGPT；GLM-4.7-Flash 与 Qwen Flash 保留独立 Keychain API Key
- 原声和每次处理尝试留存在本机私有历史，失败保留已完成阶段供明确重试
- `OpenAI-Compatible Recovery` 只作为高级恢复路径


## 当前本地候选

0.6.0（126）增加豆包默认及阶段选择。全新配置使用豆包，旧配置保留原服务；可在 Dictation 明确切换。一次录音固定一份阶段快照，手动 Retry 沿用原选择。失败不自动切换服务，也不把部分文字自动粘贴到目标。

豆包使用输入法私有配置、流式识别和文本整理接口；配置凭据只存应用自身 Keychain，不导出输入法或浏览器凭据。私有接口可能变更、限流或拒绝；实测可用不构成免费或稳定性承诺。录音发送给所选识别服务，文字发送给所选润色服务；词库仍可在本机对齐，尚未证明云端热词可用。

原 ChatGPT 路线继续使用 ChatType 自己的登录态。兼容识别及 GLM/Qwen 润色保留各自凭据和费用边界。旧版[Qwen 验收记录](docs/qwen-flash-polish-2026-11-10.md)保留其当时测试结论；本次交付证据见[126 实施记录](docs/doubao-implementation-2026-11-14.md)。

## 使用流程

1. 安装 `ChatType`
2. 把打包后的应用安装到 `/Applications/ChatType.app`，并从这个已安装路径启动
3. 打开 Dictation 选择各阶段服务；选用 ChatGPT 阶段时在应用内完成原账户登录
4. 首次录音时授予麦克风权限；如果之前拒绝过，可在设置页点 `Open Microphone Settings`
5. 如果希望自动回填到当前输入框，在设置页点 `Guide Accessibility Access`
6. `ChatType` 会打开正确的 Accessibility 页面，并用拖拽式引导帮助你把已安装应用授权进去
7. 如果列表里还是没有 `ChatType`，就在 Accessibility 页点击 `+`，手动添加 `/Applications/ChatType.app`
8. 把光标放到 Notes、Mail、Slack、Codex 等可编辑位置
9. 按一次 `F5` 开始录音，再按一次 `F5` 结束录音
10. `ChatType` 将录音发送到所选识别服务，全新配置默认豆包
11. 可选：在设置页里导入通讯录姓名或微信名称
12. 可独立选择润色服务；ChatGPT 润色使用 ChatType 已保存的会话
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

- 通过系统通讯录权限导入完整姓名和昵称
- 通过现有 wechat-decrypt 的 get_contacts 只读接口导入微信备注名和昵称；排除系统账号、公众号和群聊
- 在设置页里添加自定义术语和确定性替换
- 导入后的词表由 ChatType 自己保存在本地配置里
- 在 STT 和可选 AI 润色之后，对工具名、产品名和技术术语做本地对齐
- `transcription.hintTerms` 仍然保留，用于文件名等关键字的 exact-only 保留

macOS 输入快捷码由系统管理。旧版导入的快捷码规则会迁移成目标标准词条，原配置先以 0600 权限备份。Replacement 只处理显式文本修正，在整段润色后运行一次；英文按完整词匹配，中文按精确文字匹配，并保护代码、路径和链接。词库支持搜索、来源筛选与虚拟列表。

控制面板收敛为 Account、Dictation、Terminology、History、Settings。Account 管理凭据及服务预设；Dictation 提供各阶段独立控制，并展示录音 → 识别 → 词条对齐 → 文字润色 → 文本修正 → 粘贴流程；Settings 提供系统登录项、权限与剪贴板偏好。

## AI 文本润色

`v0.5.x` 新增可选的 ASR 后文本润色引擎，主要面向长段口述给 agent 的场景：去掉口头禅，按后文修正后的意图为准，保留术语大小写，并在长输入时整理成更像计划的分点输出。

润色与 ASR 分开选择。豆包仅发送待整理文本到输入法整理接口；ChatGPT Auth 复用 ChatType 登录态和私有账户后端。可选 GLM-4.7-Flash 和 Qwen Flash 分别使用固定的智谱和北京 DashScope 接口，独立 Key 只存 Keychain。Qwen Flash 关闭思考，按账户有效免费额度优先、之后按量计费，录音按 Dictation 所选转写路线处理。设置页显示凭据就绪状态，provider 变更从下一次录音生效。润色失败保留原声和阶段文字，等待明确重试，不自动粘贴部分结果。

`v0.5.1` 修复了 AI Polish 与当前 ChatGPT/Codex Responses 私有入口请求格式不匹配的问题，并让设置页显示润色尝试、成功和失败次数，不再把后端失败隐藏起来。

## 高级恢复路径

如需独立端点，`ChatType` 仍然保留 `OpenAI-Compatible Recovery`。

保留的 ChatGPT 账号路线把 Cloudflare `403` 分类为 challenge，不当作普通网络波动或登录过期；初次流程有界最多 3 次，明确点击 Retry 后一次。失败保留原声，不自动切换目的地。

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

如果你要发 X，使用已批准的 `longbiao-x-post-workflow` / `xurl-ops` 路径。如果当前任务明确要求 X Web 界面，先用 IAB；只有任务依赖常用 Chrome profile 的现有登录态时才使用官方 Chrome 扩展。发布后必须读回帖子，并确认新的 `/status/` URL。

## 配置

`ChatType` 的运行时配置保存在：

```text
~/Library/Application Support/ChatType/config.json
```

术语相关的高级选项：

- 导入通讯录姓名或微信名称
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

当前豆包和保留的 ChatGPT 路线都依赖私有后端。ChatGPT 使用应用自己维护的本地会话；豆包配置凭据由应用独立取得并存入 Keychain。

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


本地构建109恢复个人词库来源及中文近音姓名提示：本地预览用于挑选少量相关姓名供原账户ASR提示，正式转写再挑选相关词进入原整段润色。读音检索仅提供候选，同音姓名保留歧义；整段预览和整本通讯录保留本机。
