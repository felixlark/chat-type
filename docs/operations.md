# ChatType 运维规约与 2026-08-24 故障复盘

## 错误 HUD 关闭（2026-11-14）

普通错误和可重试错误均显示右侧叉号，可立即关闭 HUD；可重试错误同时保留重试按钮。关闭沿用取消入口，清除本次待重试状态并返回就绪，原始录音与已保存审计仍留在 History。普通错误原有的自动消失行为保持。

## 130 活跃审计快照与真实输入计时（2026-11-14）

进程取样确认129真实GUI仍会在`readJournal`、`compact`与识别会话审计中读取并解码完整快照；单份取样不能独自区分首次冷读、缓存驱逐和文件指纹失配。130在原机会缓存之外，强持有所有活跃record的全部attempt配置，直到终态journal完成文件及目录同步才释放。`readyToInject`继续持有；终态保存失败继续保留，取消后晚到会话写仍保持终态并再次释放。没有活跃数量上限或新增准入限制。强持有命中仍检查文件指纹与引用SHA，损坏、缺失和不匹配继续失败关闭。

`LatencySample.recoveryWriteStats`记录本进程累计审计写入、完整快照解码、机会缓存/活跃持有命中、指纹失效及当前活跃数量；不是单次录音的增量统计。定向测试可回收机会缓存，验证活跃快照不重复解码、终态同步失败不会提前释放、损坏文件不能被活跃持有绕过。与原声、字典和阶段内容相关的磁盘格式保持129方案。

真实对照必须区分自动注入、剪贴板完成和本人后续手动粘贴。129第一次实录到剪贴板7032ms，网页更晚出现文字含后续手动粘贴，不能当作自动出字耗时；Fn未被会话层事件监听观察到，未自动播放原声，该原生一侧无有效成绩。后续以实体事件、实际麦克风状态、已确认的原生编辑目标及最终内容共同验收，不用孤立worker成绩代替。

## 129 发送积压与审计写放大（2026-11-14）

豆包发送端不再把每个20ms音频帧强制延时20ms。录音文件的增长提供采集时钟；已可用的帧依次发送并等待WebSocket背压，使启动/握手期间积压可以追回。空文件等待、取消、时间戳、Opus帧及完成协议仍保留。`liveFinishToLastSendMs`只表示录音结束信号到最后帧客户端发送调用返回，`sessionFinishWaitMs`表示FinishSession发送到最终ASR返回；前者不等于服务器已接收音频。

原声与阶段审计保留。完整配置快照在私有 `Recovery/Snapshots/<attempt UUID>.json` 写入一次并同步文件和目录，阶段journal只保存小体积路由配置、阶段文字及引用。引用复用旧版已知的 `terminology.lastImportedSource` 元数据字段，以 `ChatType snapshot SHA256:` 开头；只存在于落盘副本，运行配置和发送给后端的词条不会加入该标记。读取时按attempt UUID和SHA恢复完整原始快照，普通JSON导出仍包含完整配置。

旧128版可以读取、重建attempt及执行冷启动恢复，已知字段中的引用仍保留；History重跑原本就采用当前术语，因此后端选择不会因压缩副本改变。缺失或损坏的完整快照不降为精简配置；已有坏journal压住同ID旧索引，并保护其WAV不被当作孤儿重建覆盖。只改变本次触及的记录，不清理历史原声、尝试或文件。

`streaming-evaluate`现使用真实RecoveryStore、完整快照和阶段落盘；独立实时生产者在写审计时仍继续录音，停录计时还覆盖封口与输出前阶段保存。它仍不代替麦克风、实体键和目标插入的原生产品对照。原ChatGPT路线、豆包默认及本机Fn/F5安排保持。

## 128 豆包恢复、否定句保护与停录计时（2026-11-14）

仅将已实测的 `SessionFailed / 50700000` 且服务端原因为 `read backend response: rpc error: code = 2 desc = service discovery failure` 识别为临时服务发现失败。在尚未收到任何识别文字时，可在同一豆包服务内重开会话，从同一原声零点重新发送；初次自动处理总计至多三次，手动 Retry 仅一次。其他 50700000、鉴权拒绝、已有部分识别或取消不走该恢复分支。不刷新凭据，不自动切换其他服务。每个请求 ID、结果与已确认错误原因增量写入原声的 attempt 审计；即使后续取消也保留之前失败。服务端可用性本身仍不由客户端保证。

真实对照中上游 ASR 单个分段遗漏句界，文字整理随后把“不要删除历史录音”拆成“不要删除；历史录音……”。128 对“否定词紧接动词、原文其后没有句界”的具体形式增加本地保护：若整理新增强句界割开该结构，保留识别原文，审计仍保存提供方危险原始输出及保护原因；History 复制采用原文并标注“已保留原文”，正常结果通知解释保护。这是防止已知错误改写，不是恢复缺失标点或普遍语义正确性的保证。原 ChatGPT 润色逻辑保持原样。

128的帧间隔从发送开始计算，计入网络发送耗时；129进一步取消发送端的第二个媒体时钟，以录音文件增长为时钟并等待socket背压。GUI 总处理计时从 `stopRecording` 入口开始，包含录音封口和文字输出。`streaming-evaluate` 是显式安装版对照入口：相同 PCM 按真实时钟写入增长 WAV，豆包使用正式 live worker，原 GPT 在停录后处理完整音频，记录停录到 ASR／终稿；不操纵麦克风、HID、GUI 或生产设置，不能替代真实 F5／粘贴验收。仍保留豆包默认、原 ChatGPT 路线及每阶段选择。

## 126 豆包路线与阶段选择（2026-11-14）

本节为当前行为；下文带日期的旧事故与验收记录保留其历史范围。产品负责人已批准豆包默认及独立阶段选择。全新配置默认豆包 ASR 与豆包整段整理；旧配置保留已保存的路线，负责人本机按本轮授权切换后以安装版读回为准。Dictation 的六步分别提供实时预览、识别服务、术语对齐、润色服务、文本修正、粘贴或仅复制的控制。Save Settings 只影响下一次录音，正在处理和手动重试使用录音开始时的快照。

豆包录音为本机 16 kHz 单声道 PCM WAV；实时开启时从增长文件连续编码 Opus 并上传，预览与终稿来自同一个云端会话。关闭预览后停录再上传。固定服务为 `is.snssdk.com` 配置、`frontier-audio-ime-ws.doubao.com` ASR、`ime.doubao.com` 文本整理。配置凭据仅由应用存入自身 Keychain；不导出输入法或浏览器凭据。尚未证实豆包云端热词参数，词库仍在 ChatType 本机对齐。私有协议可能变更、限流或拒绝；探测成功不代表免费或稳定性承诺。

原 ChatGPT 技术路线保留：macOS 26+ 可用 Apple SpeechAnalyzer 预览，完整录音通过原账户转写，再走独立选定的润色。ChatGPT 只要被任一启用的云端阶段选择，就要求原应用会话；兼容 ASR、GLM 与 Qwen 保留原独立凭据和费用边界。不会因豆包失败自动上传到其他服务。

原声与每次尝试存于本地私有恢复库；记录路线、ASR/部分 ASR、实际润色输入和各次输出、终稿、错误及请求标识，不记录凭据。取消保留音频并关闭直播任务。中断录音保留已采集部分，显式确认后才重放残段；新录音使用新条目。手动 Retry 重用同一音频且追加尝试，不覆盖旧失败。处理失败不自动粘贴部分结果。输出前审计失败会阻止注入；输出后落盘失败提示核对目标，避免盲目重复粘贴。

构建需要固定 SHA 的 Xiph Opus 1.6.1，缓存位于 Library/Caches/chat-type；发布包带同身份签名的 dylib 和许可证。真实验收分别记录：单元/协议模拟、受控音频服务探测、安装版全流程、真实 F5 麦克风及取消/重试/粘贴。任一层不能代替下一层。实施证据见 [126 交付记录](doubao-implementation-2026-11-14.md)。

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

### 本机 F5／Fn 固定配置（2026-11-14）

用户指定：豆包输入法使用实体 Fn，ChatType 使用实体 F5。已由用户实体键盘验证两者独立唤起，以及安装版 127 的 F5 开停和可见文字输出。

本机 Karabiner 的 `Default profile` 将 F5 输出为 F18，ChatType 的 `transcription.hotkeyKeyCode` 为 **79**。该独立事件通道避免 F1–F12 转换中附带的 Fn 事件误唤起豆包；不能因为界面仍写 F5，就把内部键码改回默认 96。豆包自己的免按模式保留 Fn，ChatType 安装流程不改写豆包数据。

本机选择记录在 `~/Library/Application Support/ChatType/keyboard-binding.json`，与 `config.json`、`~/.config/karabiner/karabiner.json` 一起位于 App 包之外。`scripts/install_app.sh` 在替换 App 前调用 `preserve_local_keyboard.py`，只对已保存该选择的机器恢复 F5→F18 和键码 79，保留其他设置及其他用户的选择。升级、重装及配置整理须保留这些用户文件；不得恢复旧 Fn+F5→Codex Plus 规则。主动清除全部用户数据也会清除本机选择，不属于普通 App 重装。

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

## 长录音采集完整性门禁

- `HTTP 200` 和非空文本只证明转写服务处理了收到的音频，不能证明本地麦克风在整段录音中持续提供信号。
- 录音已经出现有效声音后，如果电平连续 15 秒低于数字静音阈值，ChatType 自动结束本次采集；停止后仍以 WAV 内容复检。
- PCM WAV 全程无有效信号，或长录音尾部存在至少 15 秒数字静音时，不调用转写端点、不粘贴残缺文本，并把原音频及明确的输入中断错误写入 Recovery。
- 排查“不完整转写”时必须先对齐 WAV 时长、非静音区间、上传字节数和 ASR 字数；只有 WAV 含完整语音而响应漏尾，才能归类为上游转写截断。

## 原始录音持久保存（2026-10-07）

- 每次 F5 开始采集前，在 `~/Library/Application Support/ChatType/Recovery/Audio/` 预留私有 WAV，并在 `Recovery/Records/` 原子写入且同步独立记录。目录权限 0700，音频和记录权限 0600。目录或记录不可写时不开始录音。
- 麦克风直接向该持久文件连续写入，不经过可清理临时目录；录音期间每秒同步文件，停止时再次同步。保存失败立即停止采集并报告错误，已写入文件仍保留。
- ESC、HUD 关闭、取消处理、处理成功或失败、开始下一段、退出和安装升级都不删除原音频。最近 10 条只是展示限制，所有记录和旧索引继续保留，不能自动修剪原音频。
- 正常启动时识别上次未结束的录音或处理，恢复 WAV 长度字段并标记 interrupted。修复只更新文件头，保留 PCM 样本；异常文件原样保留。旧 recovery-history.jsonl 只读兼容，新记录独立存储，音频路径不迁移。
- 软件保证已接收的音频持续落盘并同步，不能承诺磁盘物理损坏、整盘丢失或尚未交付给应用的设备缓冲音频可恢复。此修复不能还原此前已经删除的那段录音。
- 回归必须覆盖：开始时记录存在、不可写不启动、录音取消和处理取消保留、重启恢复、超过展示条数不删除、History 复制原文件。安装版用真实 F5/ESC/HUD 关闭验证；完成后保留正常运行。
- 构建缓存默认 `~/Library/Caches/chat-type/swiftpm/`，新包装产物默认 `~/Local/chat-type/dist/`（可用 CHATTYPE_DIST_PATH 显式设置），避免将新产物写入 iCloud Documents。既有 dist 不清理。

## Long-recording upload optimization

Managed ChatGPT STT keeps the durable 24 kHz PCM WAV as the recovery source. Recordings of at least 15 seconds use a temporary M4A/AAC upload derivative at 64 kbps per channel, with the original sample rate and channel count. Short recordings and local encoder failures retain WAV uploads. Original integrity checks and the 25 MB source-file guard run before encoding; cancellation is propagated, and temporary derivatives are removed after reading. The advanced OpenAI-compatible route retains its existing WAV behavior.

The destination remains the existing private `https://chatgpt.com/backend-api/transcribe` account route. No Platform transcription API, extra credentials, Cookies or provider are introduced. Private-route codec acceptance was measured on the installed app; public API format documentation alone does not establish compatibility. Auth/Cloudflare limits are unchanged. Only an explicit 400/422 rejection triggers the existing prompt-free retry; cancellation, network errors and empty successful responses do not initiate a duplicate upload.

Anonymous latency samples include optional `uploadedAudioBytes`, `uploadEncodingMs` and `uploadAudioFormat`; old JSONL samples remain readable. Original `audioBytes` continues to mean the recovery WAV size. Transcription timing excludes encoding, while `totalProcessingMs` includes it. The installed benchmark supports `CHATTYPE_BENCHMARK_UPLOAD_MODES=wav,aac,flac` with publicly authored fixtures, alternating format order and bounded runs. It reports actual encoded format, bytes and URLSession upload/wait/receive timings without credentials.

Measured on 2026-10-07: 53.23s synthetic Chinese audio, 3 runs/format, STT including preparation median WAV 20.544s vs M4A 6.165s; 106.86s audio WAV 46.294s vs M4A 8.113s. These small samples characterize this machine/account/network, not a universal SLA. All 18 requests succeeded with complete endings. Numbers and punctuation were normalized for character-error comparison; mean errors WAV/M4A were 2.99%/2.45% (53s) and 2.59%/2.93% (107s). This is not a general quality guarantee. Benchmark artifacts are in `~/Local/chat-type/latency-optimization/stt/`.

References: [Apple AVAudioFile](https://developer.apple.com/documentation/avfaudio/avaudiofile), [Apple URLSessionTaskMetrics](https://developer.apple.com/documentation/foundation/urlsessiontaskmetrics), [OpenAI speech-to-text format guide](https://developers.openai.com/api/docs/guides/speech-to-text), and the unofficial account-backed implementation [codex-asr](https://github.com/Wangnov/codex-asr). Polish remains the existing `gpt-5.6-terra` production model; the earlier Luna comparison does not establish a quality/tail-latency advantage.


## 本机通讯录候选报告（111）

此入口复用已安装 ChatType 的现有 Contacts 授权，只读 Apple Contacts 公开框架，不请求新权限。姓名、昵称、机构与账户关联只留本机；命令在认证和正常应用初始化前分流，不调用转写或润色服务。没有联系人合并/删除或新清单启用入口，真实转写继续使用原词库与规则。

通过 LaunchServices 从正式安装路径运行独立进程：

```bash
open -W -n /Applications/ChatType.app --args contacts-report
```

输出目录为 `~/Library/Application Support/ChatType/ContactsReports/Report-<UUID>/`。`index.html` 供本人在本机核对来源、同名/同昵称候选和原始卡片关联；`name-catalog.json` 是未接入真实转写的分层清单；`summary.json` 只含匿名计数、耗时和路径。目录权限 0700、文件 0600，静态 HTML 禁止外部资源。不要把报告或清单作为云模型/评审输入。

可选参数 `--check-cases` 后跟本机 JSON 文件路径；文件为数组，每项包含非空唯一 `id`、查询 `text`、预期姓名数组 `expected`，负例的预期数组留空。原词库与新清单沿同一姓名匹配规则比较，首例首查询可能含索引准备，另测预热后 5 轮中位数；只代表本地查询时间。已知漏召回必须如实记录，不据此宣称完整语音识别验收。

未授权、采集期间联系人变化、配置字节变化或发布失败会终止本次生成，已有完整报告保留。处理完成后恢复正常菜单栏运行：

```bash
open -n /Applications/ChatType.app
```

恢复 110 时仅替换已安装应用；保持联系人、配置和已生成报告。联系人实体写入、候选规则调整及分层清单启用均按各自批准范围办理。


## Control panel acceptance

The installed control panel has five destinations: Account, Dictation, Terminology, History and Settings. Account owns service credentials and model selection; Dictation owns processing behavior and an inspectable six-step route. A route preview uses the displayed draft; Save Settings applies changes to the next recording.

Terms hold standard spellings and names. Replacement holds explicit final-text corrections; rules run once after polish or its fallback, use literal whole-word matching for English and exact contiguous text for Chinese, and preserve code, paths and links. Identity rules additionally protect their literal text through alignment and polish. macOS input shortcuts are not imported; legacy rules migrate to target standard spellings with a 0600 original-byte backup made before decoding or writing config. To reverse that migration, restore the previous app before restoring the backup.

WeChat import calls the existing wechat-decrypt get_contacts read tool using its installed isolated runtime. Import is a draft operation, merging current entries while retaining unrelated edits. No private database is opened by ChatType. Reports contain counts and bounded failure categories, not names or credentials.

Acceptance covers 17k+ library opening, bilingual search, source grouping, pagination, add/edit/remove a task-owned temporary entry, import/save feedback, page navigation from a scrolled page, the six flow steps, and the SMAppService login item switch. Recheck the signed /Applications/ChatType.app after packaging, then leave its normal menu-bar runtime running.

## 124 自动粘贴焦点修复（2026-11-12）

无编辑光标时，读取selectedText/selectedTextRange成功、窗口中存在输入框或仅持有启动应用上下文，都不能证明可以粘贴。当前门禁只接受实际focused文本控件、可写AXValue且未禁用；原应用回退不搜索任意后代。恢复目标应用并确认PID后再次核实际编辑焦点，60ms等待后发键前重核；不满足时只保留系统剪贴板。终端或自定义编辑器无法提供该证据时可能保守回退，不宣称全编辑器兼容。

真实安装版124已验证Chrome可编辑目标粘贴与BODY无编辑焦点只复制，取消/重入分支及原音频保留；本轮没有触发真实可重试错误，不能据此签署Retry交互或完整固定矩阵通过。证据与速度基线的版本区别见[同机原声结果](doubao-installed-comparison-results-2026-11-12.md)。
