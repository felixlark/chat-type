## 152 设置窗口原生编辑命令与界面升级（2026-11-26）

根因不是 SwiftUI `TextField`，而是菜单栏样板启动时没有安装 `NSApplication.mainMenu`。应用只有状态菜单，没有 macOS「编辑」菜单，因此输入框能键入文字，却没有系统提供的 Undo、Redo、Cut、Copy、Paste、Delete 和 Select All 命令；`Cmd+A`、`Cmd+C`、`Cmd+V` 在 Search 和 Keychain 输入框中都不生效。2026-08-25 加入的 `CommandClosingWindow` 只补了 `Cmd+Q`/`Cmd+W`，没有补编辑命令。

152 安装标准 App、编辑、窗口主菜单，用 responder-chain selector 驱动原生编辑命令；设置窗口只保留快捷键录入期间对 `SettingsWindow.performKeyEquivalent` 的精确拦截。设置壳层改为 `NavigationSplitView + List`，内容改用系统 `GroupBox` 和语义字体；Workflow 六个阶段及 History 处理阶段改为原生 segmented `Picker`，History 记录列表改为原生 `List` 选择，凭证输入从 popover 改为原生 sheet。静态说明文字启用 `textSelection`，History 文本列移除了会与选择操作竞争的外层点击手势。

安装版 152 已实测：History 搜索框 `Cmd+A` 后键入会替换原值，`Cmd+C`/`Cmd+V` 可回贴；Qwen API Key 原生 sheet 可粘贴，保存按钮随之启用，取消后不写 Keychain。菜单、侧栏、Workflow、History 和 Settings 均从 `/Applications/ChatType.app` 读回。本机安装使用既有 `me.longbiaochen.chattype` 身份与五个本地 Keychain service；仓库默认公开包身份不变。

## 151 DeepSeek 全流程（2026-11-26）

新增 `deepSeek` 识别与 `deepSeekFlash` 润色。Workflow 的“DeepSeek 全流程”只显式设置这两项，并恢复自动预览源；用户仍需保存配置。完整 WAV 发往固定 `https://api.markpipe.app/v1/tools/asr`，润色文本和词表发往固定 `https://api.markpipe.app/v1/chat/completions`，模型为 `deepseek-flash`。两段共用 Account 中保存的 Markpipe Keychain key，不读取 ChatGPT、GLM、Qwen 或豆包凭据。

DeepSeek ASR 是整文件接口，不支持流式识别，也没有 prompt 或热词请求字段；ChatType 因此不发送识别提示词，术语对齐仍在本地识别之后执行。音频上限沿用官方 8 MiB / 120 秒，超过时在发网前拒绝。失败只保留原录音与当前尝试，不自动切换服务；HTTP 408、429 和 5xx 允许用户显式 Retry。Markpipe 站点或上游不可用时按真实 HTTP 状态报告，不能把 `523` 写成鉴权失败。

## 144 词条生效核验与大词库索引复用（2026-11-16）

词库有 18,796 条时，失败录音快照及已保存配置均没有 `interactiond`、`contextd`、`taskd`。安装版界面经实际编辑、Add Term、Save Settings 后，三个词进入保存配置；随后增加 `interaction d → interactiond`、`context d → contextd`、`task d → taskd` 三条明确的 Replacement，并将同样的拆词写法写入对应术语的 aliases，使其在豆包整理前完成对齐。原始失败识别中的 `and d`、`contacts d` 没有足够信息作唯一还原，不建立猜测映射。此前新增为何没有进入配置仍未确认，不归咎于用户未点按钮。

在相同词库的离线副本中，微信导入词 `D` 会先将 `task d` 改为 `task D`，随后小写术语的大小写保护阻止模糊合并；显式别名可在整理前处理这种拆词。仅依赖整理后的 Replacement 时，如果豆包给整句添加代码标记，原有代码保护会跳过替换；因此还原应在前置术语对齐时完成。代码、路径等受保护文字继续遵循原有规则。豆包识别尚无获验的热词上传，文字整理请求仅发送正文；本机词库不等于豆包云端已经学会所有词。

每次处理原先重新筛选、拼接 alignment 数组，使按数组存储身份缓存的标准化索引在新录音中失效。144 单独缓存相同词库的 terms 与 terms 加 identity correction 两份不可变数组，保留原顺序和严格相等判定；录音快照、普通纠错、阶段开关及术语算法保持原语义。词库修改即重新派生，旧录音仍采用自己的快照。全部词条保留，未增加词库数量限制或更换服务。

设置窗口不可见时先经应用菜单栏 Settings 入口恢复，核准确 PID/window_id 后继续后台操作。此次还复现了 AXSetValue 仅改变框内显示、没有更新 SwiftUI 绑定：实际焦点和编辑事件后 Add Term 才启用。验收须检查列表、保存配置和新录音快照；不能把工具成功或框内显示当作生效证明。窗口定位与工具恢复由开发者处理，不因首次查询失败让用户代开窗口。规则已写入仓库 AGENTS.md。

## 141–142 顶部 HUD 与独立字幕（2026-11-16）

用户已批准顶部方案：状态HUD在原目标屏幕的菜单栏/摄像头安全区下方16pt居中，保持44pt高；字幕在其下方12pt，黑色90%不透明底、白色22pt系统字体、30pt行高。按用户实录后的简化决定，字幕固定一行，长句按词语或完整字符边界切换最新一段，完整尾部始终可见。一行只约束字幕显示窗口，原录音、全文、历史与输出均不截断。旧的输入框旁渲染、光标/字体依赖和底部拖拽定位已退役。

同次会话锁定屏幕身份，持续读取该屏幕当前安全区域；切焦点不停录、不跳到新屏幕。菜单栏和摄像头区域使用Apple [safeAreaInsets](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets)及[visibleFrame](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe)。停录后字幕补齐ASR末尾，封存后即交接一次终稿，不为阅读等待而延迟粘贴；注入返回后建立新的字幕显示代次，即使同字串也以该代次的实际绘制回执起算1.5秒，再关闭字幕与HUD。取消、下一次录音和历史重跑隔离旧绘制回执及旧关闭任务。

原生粘贴仍只发一次。初始150ms后，如完整回读尚未一致，按既有1秒UI响应参数另开回执观察窗口、每25ms再读原控件。同步AX IPC可能超过观察窗口，未确认时主界面可能短暂等待；不改变识别时长。只有确认后才恢复仍归本次写入占用的旧剪贴板；未知时保留终稿和剪贴板，显示“请核对输入框”，不伪报失败/成功，不自动重发。日志仅有长度及段落数；实际失败的确切回读仍须按现场证据诊断。

## 137–138 Codex 实际输入与完整初稿交接（2026-11-16）

136 的 Sublime 验收不代表 Codex 输入框可用。Codex 的网页编辑器可能接受 AXValue 调用却不完成真实编辑，而且空框的 AXValue 会包含占位提示及段落换行。137 对 AXWebArea 内的原文本目标使用一次原生 Cmd+V：保留原 PID、窗口、控件、值与 UTF-16 选区，恢复并核对原目标后发送，随后回读原控件。精确匹配终稿及原上下文才报告 Pasted；仅对已识别的空框占位提示接受其被真实输入替换的完整回读。发送后不自动重发，不在未知输出后再复制另一份；无法确认时保留 readyToInject 和具体错误。原生 AX 控件与 Sublime 插件仍沿各自已验证路径。

停录后，完整 ASR 文字在终稿写入前重新显示；只有实际渲染可见后才保留 1.2 秒阅读时间。焦点切走或位置不可用时跳过阅读等待，继续校验原目标。等待中取消或开始下一次录音会撤销旧交接。录音和终稿成功保存后才输出。

137 实体 F5 验收中，用户确认两句均自动写入；随后只读观察复现了成功写入却误报未知的原因：Codex 空框的 AXValue 包含占位提示和段落换行，真实输入后的 AXValue 则是终稿本身，不带末尾换行。138 对已识别的空框接受“终稿”或“终稿加一个段落换行”两种完整回读；其他内容和上下文仍须精确匹配，不用包含匹配，也不重复发送粘贴。

结果徽标为 20pt、符号为 14pt，均在 44pt 状态 HUD 内裁剪；剪贴板分支显示“已复制，未粘贴”。剪贴板保留设置沿用原录音快照；确认粘贴后才安排恢复，且只恢复仍由本次写入占用的剪贴板，保留后来的用户复制。`--overlay-demo-state copied` 可独立检查该结果样式。

## 136 统一原位初稿与实际编辑器输出（2026-11-16）

实时初稿统一显示在原光标右下方 6pt 的半透明圆角框内，字号、字体与主题颜色从原输入目标读取；展示宽度最多 360pt 自动换行，不受原输入框宽度约束，靠近屏幕边缘时移回可见区域。初稿带点状下划线，状态 HUD 独立水平居中、距可见屏幕底部 24pt，并优先向上避让输入及按钮区域。识别和整理过程中不把初稿写进文档，终稿安全保存后一次进入原目标。换焦点不停止录音；原窗口/标签不在前台时隐藏原位框，回到原处可继续显示。Sublime 坐标和字号按其 `ui_scale` 换算，并加上 AppKit 当前系统标题栏高度；全屏不加标题栏。

135 在标准 NSTextView 中的验证未覆盖实际 Sublime Text。Sublime 不暴露标准可写 AX 文本节点，135 因此进入剪贴板分支，原框既没有实时字也没有终稿。136 为已安装的 Sublime 配置官方用户插件，读取光标几何、字体和选区，并按稳定 view ID 和隐藏的跟踪选区完成终稿插入。插件不改第三方应用包，不切换输入法，不申请权限，不添加网络服务或云端目的地。官方 API 来源：[Sublime API](https://www.sublimetext.com/docs/api_reference.html)。

插件源随 ChatType 包交付，安装到 `~/Library/Application Support/Sublime Text/Packages/ChatType/ChatType.py`。IPC 只用私有目录内的 Unix socket，目录 0700、socket 0600；实际 protocol 1 / build 136 的 begin 回执才证明输入连接就绪。没有 socket 或原文档已关闭/只读/选区被修改时，保留录音和终稿，明确复制兜底。编辑器确认终稿前不报告 pasted；写入回执丢失时只查询原会话状态，不重复插入，不再复制另一份终稿。无法确认的输出保持 readyToInject，要求先核对原文档。

同一次录音的目标句柄独立于重试 attempt，手动 Retry 保留原文档/选区及路线。取消只移除原位初稿与目标标记，不修改文档。普通 AX 输入框同样只在终稿阶段替换原选区；写入后回读不一致或不可读视为输出状态未知，不回滚、不追加粘贴。关闭实时预览仍保留终稿的目标定位；仅复制设置保持仅复制。

## 135 输入框实时预览与简化重试（2026-11-16）

状态 HUD 恢复紧凑的 44pt 状态条，只显示水波纹、计时、状态、取消和重试。实时转写不再出现在 HUD 内。启用实时预览且未选“仅复制”时，在录音开始前锁定原输入控件与选区；中文、表情与选区替换按 Accessibility 的 UTF-16 坐标处理。焦点切到同应用另一个框或其他应用后，仍更新原控件，录音继续，不改投新焦点。

原控件不支持安全写入时，实时文字显示在其输入框矩形内的独立、不可抢焦点且鼠标可穿透的蒙版；原应用不在前台、位置不可读或停录进入处理后隐藏蒙版。输入框或选区无法获取时继续保存音频，终稿复制到剪贴板。检测到用户手工改字或写入回读不一致后，不覆盖当前内容，终稿复制并提示核对框内临时文字。取消、识别/整理或输出前保存失败，只撤回仍精确匹配的本次临时文字；完整终稿保存后才替换临时段。成功输出后审计失败不会撤回终稿。

失败 HUD 的重试按钮直接重跑一次原路线，沿用该次录音的服务、词表、注入快照和原目标，不弹菜单、不隐式应用设置草稿。History 保留显式“按当前流程重跑”和“重试原路线”。仅复制与关闭实时预览时保持原输出流程。豆包连接错误提示不会混入输入框的转写正文。

## 134 设置与 Workflow（2026-11-15）

设置导航为 Account、Workflow、History、Settings。Account 显示所有已支持服务：ChatGPT 会话、豆包 IME 安装、Apple SpeechAnalyzer 本地预览支持、GLM/Qwen 密钥和兼容恢复入口；豆包安装绿点不是云端可用性或费用保证。GLM/Qwen 密钥在 Account 管理。Workflow 的 Recognize 与 Polish 保持独立服务选择，Align 内维护自定义短语，Correct 内维护 Replacement；其余阶段保留预览、提示音和输出控制。未添加本地终稿服务或新的数据去向。

卡顿采样显示应用重新激活时，界面线程在恢复库 JSON 解码路径约占 2.7 秒。修复将使用统计、Keychain 元数据、历史读取移到后台；Account/Workflow 打开不扫描恢复库。History 使用独立只读 store，不持有录音 writer 的锁；先排序压缩 journal，再恢复最近有效记录的完整快照。记录损坏仍压住同 ID 旧索引，不回退覆盖。异步刷新合并读取期间到达的录音/凭据更新，失败保留已有数据并显示错误。关闭窗口取消结果应用，重新打开刷新。

# ChatType 运维规约与 2026-08-24 故障复盘

## 133 采集就绪边界与同源对照

录音器的 `record()` 接受请求后，等待有效的录音时钟前进再显示 recording／播放开录声。取消等待会停止并保留原声；旧启动的迟到取消或保存异常不得重置新的 F5 会话。没有引入启动超时或后台预录。

同音频测试不能把硬件 prepare 阶段的 mic on/off 当成正式开始／停止。仓库的 [同源对照规约](same-audio-readiness.md)要求实体 F5、新 recording attempt 快照及实际 PCM 增长共同成立后才送音，并以实体停录键、实际字段与审计哈希出验收回执。静音原声校验原已存在；一次录到环境底噪的无源音试验不等于 ASR 服务故障，也不证明声效假设。

## 错误 HUD 关闭（2026-11-14）

普通错误和可重试错误均显示右侧叉号，可立即关闭 HUD；可重试错误同时保留重试按钮。关闭沿用取消入口，清除本次待重试状态并返回就绪，原始录音与已保存审计仍留在 History。普通错误原有的自动消失行为保持。

## 131 当前流程重跑与唯一配置入口（2026-11-14）

本节保留 131 的历史实现。149 已改为 HUD 无箭头菜单，History 单屏只显示“重试原路线”和“按当前流程重跑”两个整流程动作；当前行为以 [PRODUCT](../PRODUCT.md) 为准。

本人选择 ChatGPT 后，130 的手动 Retry 仍重用旧录音快照中的豆包，History 却提示“current settings”。131把语义分开：普通“按当前流程重跑”显式采用 Dictation 当前选择，新增attempt；“重试原路线”保留最后一次尝试的识别、润色、词表和注入快照。HUD箭头菜单提供这两个明确动作，History主按钮为当前流程，“更多”中保留原路线。自动恢复不跨服务。

服务、模型及阶段选项只在 Dictation 流程中设置；Account保留账户登录，不再重复识别/润色选择器。识别、润色原完整配置放到对应步骤，提示音在Voice，剪贴板行为在Paste；Settings保留启动项、系统权限与本地数据。没有每次输入都写配置：共享草稿跨窗口保留，F5开始新录音、按当前流程重跑和Save Settings才提交；忙碌操作、F5停录、原路线Retry及关闭窗口不隐式提交。已开始的任务继续使用自身快照。保存失败不开始新录音或云请求。

History对cancelled/interrupted、已有partial标记及PCM中断检测统一请求片段重放决定，并保留readyToInject/outputUnknown的重复输出核对。各attempt新增注入快照；不可变SHA sidecar同时保留它，即使128旧DTO回写丢弃未知字段，131也能还原。只有收到已同步journal的更新后才刷新对应History行，直接显示本次ASR/润色路线，不为此重复扫描整个原声库。

本次实际诊断：保存配置已为ChatGPT，291478ms原声此前多次豆包重试未完整结束；已从安装版以原ChatGPT账户完成全文件ASR（8081ms）。这项成绩只证明ASR；新界面当前流程动作、全文润色和终稿输出须另做安装验收。旧原声与每次失败继续保留。

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

- 未经用户在当前请求明确授权，禁止调用或添加任何按量收费端点，包括 `api.openai.com/v1/audio/transcriptions`。
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

2026-11-16 更新：Settings →「激活快捷键」支持录入普通按键及 Command / Option / Control / Shift 组合。点击录入暂停 ChatType 激活，Esc、失焦、切页或关窗恢复原绑定；候选仅在 Save Settings 成功后生效。新录音／按当前流程重跑只应用流程编辑，不保存待选快捷键。注册冲突或配置保存失败时保留原绑定；录入值与当前生效值分别显示。`hotkeyIsCustomized=true` 后，安装器保留自选键码和修饰键。

本人最终指定：实体 Fn 短按额外发送 ChatType 的唤醒键 F18；Fn 按下／松开原事件立即透传，长按完全由豆包输入法已有设置处理。登记文件使用 `fnTap: {"timeoutMilliseconds":300}`；安装器只维护自身命名的 Karabiner 规则，`to` 直接输出 Fn，`to_if_alone` 输出 F18，不设置 lazy、不设置 `to_if_held_down` 或长按阈值。短按窗口来自该本机显式配置。未配置不新增规则；移除配置不自动删除已装规则，停用时删除唯一规则 `ChatType local keyboard: Fn tap activates ChatType`。该映射独立于 ChatType 的 ASR／润色路线。配置校验不代替实体按键验收。

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
- 命令：Settings 可用 `Cmd+Q` 退出；输入框的 `Cmd+A`/`Cmd+C`/`Cmd+V` 与编辑菜单一致生效；
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

The installed control panel has four destinations in a native `NavigationSplitView`: Account, Workflow, History and Settings. Account owns service capability, installation and credential status; Workflow independently owns recognition, live-preview source, terminology alignment, polish and correction, with a six-stage native segmented picker and an inspectable route. History is a native `HSplitView` review workspace with a `List`, a segmented stage picker and copyable text columns. A route preview uses the displayed draft; Save Settings applies changes to the next recording.

The app installs standard App, Edit and Window menus. Text fields must accept Undo, Redo, Cut, Copy, Paste, Delete and Select All with their standard shortcuts; a menu-bar-only launch must not be used as a reason to omit them. The shortcut recorder is the only key-equivalent interception and applies only while it is first responder.

Terms hold standard spellings and names. Replacement holds explicit final-text corrections; rules run once after polish or its fallback, use literal whole-word matching for English and exact contiguous text for Chinese, and preserve code, paths and links. Identity rules additionally protect their literal text through alignment and polish. macOS input shortcuts are not imported; legacy rules migrate to target standard spellings with a 0600 original-byte backup made before decoding or writing config. To reverse that migration, restore the previous app before restoring the backup.

WeChat import calls the existing wechat-decrypt get_contacts read tool using its installed isolated runtime. Import is a draft operation, merging current entries while retaining unrelated edits. No private database is opened by ChatType. Reports contain counts and bounded failure categories, not names or credentials.

Acceptance covers 17k+ library opening, bilingual search, source grouping, pagination, add/edit/remove a task-owned temporary entry, import/save feedback, page navigation from a scrolled page, the six flow steps, and the SMAppService login item switch. Recheck the signed /Applications/ChatType.app after packaging, then leave its normal menu-bar runtime running.

## 124 自动粘贴焦点修复（2026-11-12）

无编辑光标时，读取selectedText/selectedTextRange成功、窗口中存在输入框或仅持有启动应用上下文，都不能证明可以粘贴。当前门禁只接受实际focused文本控件、可写AXValue且未禁用；原应用回退不搜索任意后代。恢复目标应用并确认PID后再次核实际编辑焦点，60ms等待后发键前重核；不满足时只保留系统剪贴板。终端或自定义编辑器无法提供该证据时可能保守回退，不宣称全编辑器兼容。

真实安装版124已验证Chrome可编辑目标粘贴与BODY无编辑焦点只复制，取消/重入分支及原音频保留；本轮没有触发真实可重试错误，不能据此签署Retry交互或完整固定矩阵通过。证据与速度基线的版本区别见[同机原声结果](doubao-installed-comparison-results-2026-11-12.md)。

### Build132 recognition fidelity

For Doubao ASR, the bundled Opus encoder explicitly uses AUDIO, constant64kbps and the existing20ms frames; StartSession uses compression ratio4 and single-toggle mode. Do not restore automatic VOIP/VBR defaults merely because requests still succeed: matched-WAV tests showed lost mixed-language terms. Raw recovery WAVs and ChatGPT routing are unaffected. See [quality investigation](doubao-recognition-quality-2026-11-15.md) for the measured scope, failed hypotheses and acceptance requirements.
