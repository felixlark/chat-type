# ChatType 运维规约与 2026-08-24 故障复盘

## 结论

本轮效率低的主因不是单个缺陷复杂，而是没有先把故障分成“应用生命周期、安装包、登录、浏览器回调、转写传输、系统权限”六个独立层级。一个层级刚出现新现象，就直接修改下一层，造成诊断、实现、安装和验收交叉推进。

今后 ChatType 故障必须先执行 `scripts/doctor.sh`，明确失败层级和授权边界，再做单一假设的最小改动。自动化测试、打包成功、应用已安装和真实录音成功是四个不同结论，任何一项都不能替代下一项。

## 本轮影响

- 用户先后遇到 Dock 启动闪退、设置打不开、菜单栏入口消失、登录网页 400、设备码不明确和转写 Cloudflare 403。
- 登录最终成功，但浏览器错误页一度被当成登录失败；这延长了认证排查。
- 私有转写端点的稳定 Cloudflare challenge 一度被描述为“网络波动”并重复请求，错误分类不准确。
- 为验证本机语音识别而直接运行 app bundle 内二进制，TCC 无法按应用包读取隐私说明，导致一次可避免的崩溃。
- CLI 读取 Keychain 密码触发了 SecurityAgent 密码框；没有泄露令牌，但增加了干扰和风险。
- 本机语音识别曾被误作为“免费兜底”加入候选实现，带来了设计之外的系统权限和数据边界；它已在获批交付前从源码、权限声明和测试中移除。

## 为什么不顺利

### 1. 没有先冻结不变量

本轮一开始应明确以下不变量：

- 不调用或新增按量收费接口；
- ChatGPT OAuth token 只发送给固定的 OpenAI/ChatGPT 官方账户路径；
- 不新增代理、浏览器 Cookie 抽取或私有数据库读取；
- 用户只处理不可替代的登录、验证码、授权和权限确认；
- 完成必须包含 `/Applications/ChatType.app` 的真实用户流。

收费边界虽然后来得到遵守，但没有在第一次方案选择前写成硬门禁，导致讨论过不该进入候选集的官方 Platform 转写端点。

### 2. 将状态相关性误当成因果关系

- Safari 回调页 400 不等于 ChatType 登录失败；Keychain 和 Settings 的 `Ready` 才是应用登录状态证据。
- OAuth token 可用不等于私有转写端点接受该请求；认证成功与业务 API 可用是两道门。
- Cloudflare 403 HTML challenge 不等于 token 过期，也不是普通 403 JSON 鉴权失败。
- 单元测试通过不等于 TCC、LaunchServices、菜单栏或录音用户流通过。

### 3. 诊断入口不稳定

- 使用了过宽的 unified log 查询，产生大量无关输出。
- 尝试通过 `security ... -w` 读取 Keychain 密文，引发密码提示；本来只需要应用内状态或元数据。
- 基准脚本直接执行 `Contents/MacOS/ChatType`，绕过 LaunchServices，导致 TCC 错误地认为缺少隐私说明。
- Cloudflare challenge 已被一次请求稳定识别后，仍继续做多次同类请求，没有及时停止低信息量试验。

### 4. 变更面扩张过快

菜单栏/Dock、登录 UX、OAuth、转写、系统 Speech 权限同时发生变化。每个变化单独合理，但一起推进使“哪个改动修了什么”难以证明，也使回归面扩大。

本机语音识别属于新增 provider，需要单独产品决策；它新增系统权限、质量差异和隐私说明，不能作为网络错误处理细节加入。

### 5. 完成定义出现漂移

过程中多次出现“代码可行”“登录成功”“安装成功”接近完成的表述，但用户要的是正常菜单栏启动、可进入主窗口并完成一次真实录音。应始终使用同一验收矩阵，而不是随着当前进展改变完成定义。

## 运维硬规约

### A. 先分类，后修改

收到故障后 90 秒内完成以下只读分类；没有分类结果前不改代码：

| 层级 | 关键问题 | 最低证据 |
| --- | --- | --- |
| 安装 | 当前运行的是否为已安装版本 | 进程路径、bundle id、签名 |
| 生命周期 | 是否存活、菜单栏/Dock/窗口是否符合设计 | PID、LSUIElement、Computer Use |
| 登录 | ChatType 自己是否持有可用会话 | Settings 状态、Keychain 条目元数据 |
| 浏览器回调 | 网页是否失败但应用已完成登录 | 回调页状态与应用状态分别记录 |
| 转写传输 | 返回是 JSON 鉴权错误还是 HTML challenge | 单次请求的 status、content-type、server、body 类型 |
| 权限 | TCC 是否未决定、允许或拒绝 | 已安装 app 的真实权限流 |

每次只写一个当前假设，例如：“已登录；唯一失败层为私有转写端点返回 Cloudflare HTML 403”。下一次修改必须直接检验这个假设。

### B. 费用、凭据和数据去向是前置门禁

- 未经 Longbiao 在当前请求明确授权，禁止调用或添加任何按量收费端点，包括 `api.openai.com/v1/audio/transcriptions`。
- ChatGPT OAuth token 不能被当作 OpenAI Platform API 免费凭证。
- token 只能发往仓库中固定审计过的官方 OpenAI/ChatGPT host，绝不发送到用户自定义兼容地址。
- 新增任何 provider、网络域名、系统权限、Cookie 使用或数据去向，必须先说明费用、凭据、数据是否离机、质量和失败模式，并取得产品负责人确认。
- 禁止读取浏览器 Cookie、启用代理或用非官方浏览器自动化绕过 Cloudflare。

### C. 登录与业务能力分开验收

登录验收仅回答：ChatType 是否保存并能刷新自己的会话。转写验收另行回答：当前端点是否接受音频并返回非空文本。

浏览器错误页不能单独推翻应用内 `Ready`；应用内 `Ready` 也不能证明转写可用。两项必须分别记录。

### D. Cloudflare 处置

- 第一次 `403 + text/html` 或 Cloudflare server/body 特征即分类为 challenge。
- challenge 不触发 token refresh，不描述为普通网络波动；生产请求只执行既定的有界策略：首次自动流程最多三次，用户明确点击 Retry 后一次。
- 只记录 status、content-type、server、响应大小和 challenge 分类；不保存或打印完整 HTML。
- 如果固定私有端点被 challenge 阻断，停止额外同类试验：等待上游，或由用户显式选择设计内现有的 OpenAI-Compatible 高级恢复路径。

### E. Keychain 与系统权限

- 诊断 Keychain 默认只看条目是否存在和应用内状态；禁止使用 `security find-generic-password -w` 获取密文。
- 必须测试密钥读取时，只允许已签名、已安装的 ChatType 自己读取，并且日志不得打印 token。
- TCC 测试必须通过 LaunchServices 启动 `/Applications/ChatType.app`；禁止直接执行 bundle 内二进制来验证权限。
- 权限提示是用户确认点。自动化停在提示前并报告具体按钮，不代替用户授权。
- 单元测试不得触发真实 Keychain、浏览器、麦克风或 Accessibility 提示；所有这些边界必须注入 stub。

### F. 低噪声诊断

- 先运行 `scripts/doctor.sh`，禁止先做全量日志或全盘搜索。
- unified log 查询限定进程、事件关键词和最近 15 分钟，最多展示 20 行。
- 配置只输出 provider、固定 endpoint host、模型和布尔开关，不输出整份大词典、token 或个人数据。
- 网络差分最多三种有明确信息增益的假设；同一结果重复两次后必须停下重新分类。

### G. 变更与验收门槛

每次修复按以下独立门槛报告：

1. `implemented`：源代码已修改；
2. `checked`：聚焦测试和 `scripts/check.sh` 通过；
3. `packaged`：`dist/ChatType.app` 元数据和签名通过；
4. `installed`：最新包重新安装到 `/Applications/ChatType.app`；
5. `live accepted`：已安装 app 完成相关真实用户流；
6. `left running`：普通菜单栏模式仍运行，审阅所需窗口按任务要求保留。

前一门槛不能替代后一门槛。遇到权限、验证码或上游阻断时，结论必须是 `partial`，并写明唯一待完成动作。

### H. 品牌视觉所有权

- App 图标、菜单栏图标 renderer、产品名称、颜色和其他品牌视觉属于产品负责人控制的不变量；当前请求没有明确授权时禁止修改。
- 生命周期修复只能改变创建、显示、隐藏和恢复逻辑，不能顺带替换图标、文字或视觉状态。
- 任何获批视觉变更都必须保留安装态前后对比证据；“菜单栏项目存在”与“菜单栏图标正确”是两个独立结论。
- `scripts/check_policy.sh` 必须阻止既有动态图标被静态 `CT` 文本替换；Swift 回归测试必须覆盖每个状态继续使用模板图标。

## 2026-08-25 菜单栏图标越界变更复盘

### 事实

修复菜单栏项目消失时，代码正确加入了 `autosaveName` 和 `isVisible`，但同时未经授权把 `ChatTypeStatusIconRenderer` 生成的气泡声波动态图标替换成静态 `CT` 文本。图标变更不是生命周期修复所必需，也不是 macOS 或打包工具自动产生。

### 漏检原因

- 将“项目是否可见”错误地当成“图标是否正确”；
- 自动化只统计 `ensureVisible` 调用，没有约束按钮标题为空且使用既有 renderer；
- HUD 可视化验收没有覆盖菜单栏图标；
- 最终截图已显示 `CT`，但没有与变更前基线对比。

### 改进

- 恢复原有状态化模板图标，同时保留 `autosaveName` 和 `isVisible` 生命周期修复；
- 用类型化 `StatusMenuButtonPresentation` 固定标题、图标、缩放、辅助功能标签和 tooltip；
- 增加 Swift 回归测试和脚本级策略检查；
- 将品牌视觉授权和安装态前后对比加入发布门禁。

## 固定验收矩阵

涉及本轮范围的发布必须逐项验证：

- 冷启动：无 Dock icon、菜单栏图标出现、不自动弹主窗口；
- 视觉保真：菜单栏显示既有气泡声波图标而不是 `CT` 文本，并能随 Ready、Recording、Processing、Error 等状态更新；
- 菜单栏：可以打开 Settings，关闭窗口后菜单栏仍在；
- 命令：Settings 可用 `Cmd+Q` 退出；
- 登录：设备码在 ChatType 内显示并可一键复制；授权中禁止重复启动；成功后显示 `Ready`，重启仍保持；
- 转写：`F5` 开始、`F5` 停止，返回非空文本；
- 错误：Cloudflare、权限拒绝和普通鉴权失败显示不同、真实、可操作的提示；
- 恢复：错误录音被保留，Retry 不丢数据；
- 注入：有可编辑焦点时粘贴，否则只留剪贴板；
- 结束状态：重新启动普通 `/Applications/ChatType.app` 并保持菜单栏运行。

## 本轮已形成的改进

- 登录状态与浏览器错误页分离判断；
- 设备码、复制按钮和用户步骤进入 ChatType 窗口；
- Cloudflare challenge 从“网络波动”改为独立错误类型；
- ChatGPT 后端请求补齐官方 Codex OAuth 契约中的 `ChatGPT-Account-ID` 和客户端 User-Agent，并以两个真实录音样本验证通过；
- 增加按层级输出的只读 doctor；
- 增加策略检查，防止默认转写路径静默接入收费 API；
- 基准测试改为 LaunchServices 启动，避免 TCC 将 app 误判为裸二进制。

macOS Speech 兜底已经完整移除。当前产品严格保留设计内两条转写路径：默认 `chatGPTManagedAuth`，以及用户显式选择并自行配置的 `openAICompatible` 高级恢复路径。
