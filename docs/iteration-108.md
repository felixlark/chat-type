# 迭代 108：停录收起、拖动稳定与低延迟语音服务

状态：Pstack 设计与 EGM 定向复核完成，浮窗修复及可选 GLM 已检查、打包、安装。浮窗原问题已在正式安装版验证；GLM 真实连接成功，配对速度验收失败，当前默认保留 ChatGPT。108 为工作编号，应用版本为 0.5.1(1)。

## 目标与授权

用户已实测底部多行、输入区避让及粘贴可用；反馈成功停录后浮窗常驻、拖动后回位、整段完成速度仍慢。本轮保留 F5/F5、ESC、关闭、Retry、整段术语规范化 → 整段润色 → 保护性规范化 → 一次粘贴/剪贴板。品牌视觉保持原样。

当前授权覆盖设计、EGM、修复、相称检查、正式安装及验收。线上服务先比较真实计费、凭据、数据去向和失败行为；新供应商或数据目的地的接入由负责人选择后实施。

## Pstack 安装与执行

通过官方 skill-installer 安装 `cursor/plugins` 上游 Pstack 0.15.36，提交 `6b0300214a09fd6029cfb7077043125758cd1fd2`，58 个技能位于 `~/.codex/skills/pstack/`。本轮直接读取 how、architect、arena 及相关原则。新技能目录供后续回合发现。

本机原生子代理暴露 GPT 系列，Pstack 默认 Claude/Grok runner 不在可用目录。本轮使用继承模型的两个独立架构候选，跨模型 cross-judge 记为能力缺口。EGM 使用 fresh-context 原生 reviewer，按实际结果记录。

执行顺序：Ground → 双候选 Sketch → 综合选型 → EGM → Implement → 验证与正式安装。文档由主 Agent 单 writer 维护；候选写各自临时文件。

## 当前证据与架构

`AppCoordinator` 在录音期间每 50ms 推送本地 SpeechAnalyzer 的实时文本和音量。停录后 `DictationPipeline` 等待整段转写、术语规范化、整段 ChatGPT 润色、保护性规范化，再由 coordinator 一次插入并展示终态。浮窗由 `OverlayController` 单独管理；`OverlayTranscriptView` 保留全文、换行和滚动；`BottomOverlayLayout` 计算安全位置。

正式安装版 `/Applications/ChatType.app` 为 0.5.1 (1)，签名 `HJG65XBC25`，doctor 显示安装有效、账户会话存在、无 crash。当前 managed 路径本地识别，文本润色请求发往 `chatgpt.com/backend-api/codex/responses`，模型 `gpt-5.6-terra`，请求中 `reasoning.effort=none`。

| 本机样本时间（北京时间） | 语音长 | 停录 ASR 收尾 | 润色阶段 | 停录后合计 | 结果 |
| --- | ---: | ---: | ---: | ---: | --- |
| 2026-11-10 01:12:53 | 30.192s | 83ms | 3553ms | 3888ms | pasted |
| 2026-11-10 01:14:07 | 48.994s | 154ms | 4922ms | 5191ms | pasted |

来源为产品 `latency.jsonl` 的脱敏字段；两次样本各自记录。ASR 数字只覆盖停录收尾。润色字段覆盖凭据、prompt、请求、完整输出及必要重试，进一步定位排队/网络/生成需单独计时。

### 停录后常驻

官方 Computer Use 已在真实安装版观察到 `Pasted` 浮窗持续存在。`showResult` 安排 1.2s 延迟隐藏，`present` 的 250ms 几何 timer 调用 `apply(currentState)`，`apply` 首行取消 `hideTask`，因此终态收起任务被周期刷新取消。普通 error 的自动收起也受影响。RetryableError 的持续显示沿用既有产品行为。

### 拖动回位

`OverlayDragHandle.mouseDown` 在 `window.performDrag` 返回后立即调用 onEnd。Apple 文档说明该方法立即返回，且 mouse-up 可能不发送；当前 onEnd 在实际拖动完成前读取旧 frame 并恢复自动定位。[Apple performDrag 文档](https://developer.apple.com/documentation/appkit/nswindow/performdrag(with:))

同时，`anchor` 兼作用户拖放意图和自动避让结果，preferred 碰撞后候选恢复到底部中心；固定最大包络与实际高度的差异可进一步触发回位。候选设计需同时处理事件生命周期和位置所有权。

## 架构候选与 EGM

候选 A `/tmp/chattype-108-design-a.md`、候选 B `/tmp/chattype-108-design-b.md` 均已完整读取。两者比较了控制器内责任分离和完整 reducer/effects，均选择前者。按根因覆盖、所有权清晰、调用侧迁移、真实可验证性四项评分，两候选均为4/4，选择 B 的原坐标纯函数接口作为基底，纳入 A 的超时/淡出 generation 约束。本机缺少 Claude/Grok 跨家族 cross-judge，综合由主 Agent 完成，EGM 再独立核验。

### 选定结构与约束

1. `OverlayController` 保持唯一业务显示状态 owner。`transition(to:)` 专门取消旧收起任务、增加 presentation generation、更新状态并绘制；电平、预览和 250ms 几何 tick 仅重绘/重排。成功沿用 1.2s，普通 error 沿用 2s；processing 等真实结果，RetryableError 保持 Retry。
2. 延迟到期检查 generation 后直接调用 hide，去除终态160ms淡出及其异步完成回调。新显示状态恢复 alpha=1，保留原入场效果。成功/普通错误的反馈 deadline 保持原值；明确选择到期直接收起，消除旧淡出影响新录音的路径。此调整属于用户本轮已要求修复的收起行为，原品牌视觉保持。验证在旧 deadline 前开始新录音，跨过旧 deadline 及原淡出窗口后，新录音仍保持显示。
3. `OverlayDragHandle` 统一使用原生 `mouseDown/mouseDragged/mouseUp`。事件通过 `window.convertPoint(toScreen: event.locationInWindow)` 转屏幕坐标；Controller 保存起始 pointer/frame，以起始值和总位移计算当前位置。去除 `performDrag` 路径。
4. 拖动中 Controller 暂停写尺寸和自动位置，全文数据继续收集，松手后一次排版最新全文。结束事件写入独立的用户 footer bottom-center 锚点；实际避让结果仅写 panel.frame。取消/隐藏清理拖动会话，晚到结束事件通过会话缺失忽略。
5. 自动模式保留底部优先与会话内位置稳定，四行包络用于初始避让。手动模式用真实当前尺寸，从用户中心锚点派生 origin，消除短预览、compact 和宽度变化的换算漂移；文字增长产生实际碰撞时再避让。
6. 手动位置安全时保持原位。碰撞时将 preferred、可见屏边和保护区四边构造有限 x/y 候选组合，clamp、过滤碰撞并按距离 preferred 的平方距离选择最近解，固定顺序处理同分。避让不改用户锚点，保护区解除后恢复原意图。无几何时保留用户位置并提示；无安全解时 compact 后再求一次，仍无解记录 needsAdjustment 并保留 clamp 后用户位置。
7. normal → compact 至多一轮，compact 宽280、正文40pt；正常宽480、正文40–80pt。这些沿用上一获批规格。每次布局使用相同输入得到相同结果；不持久化跨录音位置、不新增 provider/权限/云调用。屏幕沿用当前会话 pinned screen，跨屏拖动按屏幕边界约束。

调用方仍使用现有 showRecording/updateRecording/updateTranscriptPreview/showProcessing/showResult/showError/showRetryableError/hide。内部允许最小私有手势结构和 generation 值；纯几何函数保留 preferred-origin 入参，并用显式手动模式选最近安全解。取消与旧回调均由同一 Controller 生命周期约束。

### 修改范围与验收

产品修改集中 `Sources/ChatType/OverlayController.swift`、`Sources/ChatType/OverlayTranscriptView.swift`、`Sources/ChatType/BottomOverlayLayout.swift`；扩展 `Tests/ChatTypeTests/OverlayControllerTests.swift`、`Tests/ChatTypeTests/BottomOverlayLayoutTests.swift`。AppCoordinator、录音、术语、DictationPipeline、prompt、供应商配置和一次粘贴链路沿用当前实现。主 Agent 单独维护 `docs/iteration-108.md`、打包、安装和 GUI。

检查点依次为终态生命周期及定向回归、拖动与布局及定向回归、canonical检查及正式安装、真实安装版原问题验收。前一检查点的失败在相同写入范围修复后推进。

- 终态跨多个几何 tick 后仍自动收起；普通 error 收起，RetryableError 继续保留 Retry；旧 deadline 遇到新录音时新录音保持显示，跨过原淡出窗口继续观察。`presentsPanel:false` 下直接驱动与生产 timer 相同的刷新入口，覆盖此前测试漏过的取消链。
- 真实拖动序列开始/变化/松手、取消后晚到结束；拖动中音量/文本/几何刷新保持 frame；松手后多次刷新与 processing 保持用户 footer-center。
- 手动避让最近安全位置、原锚点不变、障碍解除后恢复；无几何、normal/compact、短句到四行、负坐标和小屏各覆盖实际数据路径。
- canonical `scripts/check.sh`、打包、安装后以官方 Computer Use 在 `/Applications/ChatType.app` 复核原问题。观察同一实际窗口在超过 deadline 后消失，拖到非默认安全位置并等待多次 tick；复用已确认的录音/粘贴和原有业务回归，必要时最小请求物理 F5。
- 本轮实际 F5 停录仍先完成原整段润色，再在 pasted/copied 成功提示后按 deadline 收起。用户等待中的 processing 和可恢复错误保持可见，所有终态结果以实际观察记录。

检查通过后使用 canonical package/install 切换正式安装版，安全签名同当前候选，最终通过 LaunchServices 恢复正常运行。若失败，继续在上述范围修复；必要时从本机已保留上一可用包恢复，原录音和凭据始终保留。源修改、检查、打包、安装、真实验收和保留运行分开登记。

EGM 首轮：readiness 发现1项 Major（淡出实现选择未定）和1项 Nit（文件清单/检查点）；design critic 发现0项 Blocker/Major和1项相关Nit。现稿固定 deadline 直接收起，补齐写入路径和检查点，提交 fresh-context 定向复核。

定向复核 reviewer `egm_108_recheck` 已读 persona、标准与现稿，确认剩余 Blocker/Major/Nit 均为0。实现由 `implement_overlay_108` 单 writer 在上述五个源码/测试文件推进；主 Agent 负责服务调研、文档、canonical检查、正式安装和真实验收。

### 同账户加速探测

使用现有已签名安装版的 synthetic-only `runPolishComparison`，通过 LaunchServices 启动独立 benchmark 进程；固定原 prompt/账户目的地，仅覆盖模型参数。`gpt-6.1-sol` 首条 synthetic short 请求761ms后记为failed，之后由现有benchmark停止该模型，未改现网配置。对应进程97480的 CFNetwork 日志记录 HTTP400。该结果只记录可用性探测失败，400的业务原因和速度优势均未建立。日志位于 `~/Library/Logs/ChatType/iteration-108/sol-probe.log`。

探测时本机10逻辑核、load average 16.77/26.45/26.86；因此本次不作本地CPU或跨模型速度结论。用户两次现网耗时仍按原始产品样本报告。

## 在线服务比较（2026-11-10 官方资料）

### 豆包输入法的公开边界

[豆包输入法官网](https://ime.doubao.com/pc)说明使用豆包同款识别能力，并提供智能文字整理；产品页面未披露客户端内部接口和完整润色编排。对外可接入的相近能力为火山引擎 Seed-ASR 2.0。[官方协议](https://docs.volcengine.com/docs/doubao-voice/large-model-streaming-automatic-speech-recognition-api-1?lang=zh)推荐双向流式优化接口 `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`，音频分包建议 200ms；`bigmodel_nostream` 在末包或音频较长后才输出，场景和延迟不同。产品内部接口是否与公开 API 相同仍属未知。

### ASR 选择

| 服务 | 实时形态 | 官方费用/免费条件 | 质量与接入判断 |
| --- | --- | --- | --- |
| 当前 Apple 本地识别 | 真正流式、本机音频 | 服务增量费用为 0 | 本机已连续出字；个别术语误识别需保留成对素材验收；适合先继续沿用 |
| 阿里 Paraformer realtime v2 | WebSocket 实时 | 北京地域每月 10h；超出 ¥0.00024/s，折合 ¥0.864/h | 免费额度可持续更新；云端收到录音，需阿里凭据和配对准确率测试 |
| 阿里 Qwen3 ASR Flash realtime | WebSocket 实时 | 北京地域 10h/90天初始额度，之后 ¥0.00033/s，折合 ¥1.188/h | 低成本中文候选；免费额度有到期日 |
| 火山 Seed-ASR 流式 | 双向 WebSocket partial/final | 后付费 ¥4.5/h；首次开通试用礼包以控制台为准 | 最接近公开豆包语音产品线的候选；试用与后付费分别确认 |
| 海外 Groq Whisper v3 turbo | 文件上传识别 | Free Plan 限额内免费；付费 $0.04/h、每请求至少按10s计费 | 适合低价文件/停录识别；逐包双向实时 ASR 需另选服务，分块调用会引入拼接维护成本 |
| 海外 Deepgram Nova-3 | WebSocket 实时 | 初始 $200 credit；多语种流式标价 $0.0092/min | 海外真流式候选；赠金耗尽后按量，中文与中英混输需本机样本验证 |

价格和额度来源分别为[阿里百炼计费](https://help.aliyun.com/zh/model-studio/model-pricing)、[火山语音计费](https://docs.volcengine.com/docs/DoubaoVoice/Billinginstructions-21?lang=zh)、[火山首次开通说明](https://docs.volcengine.com/docs/doubao-voice/quick-start-new-console?lang=zh)、[Groq ASR 文档](https://console.groq.com/docs/speech-to-text)、[Groq Free Plan 说明](https://community.groq.com/t/do-i-get-charged-for-anything-on-the-groq-free-plan/832)、[Deepgram 定价](https://deepgram.com/pricing)。Groq 的实际账户速率上限以控制台为准，[公开限额页](https://console.groq.com/docs/rate-limits)存在套餐说明与汇总表的口径差异，本轮保留账户配额未知。

### 润色选择与推荐

| 方案 | 费用和数据去向 | 体验与失败行为 |
| --- | --- | --- |
| 保留当前 ChatGPT | 使用现有账户额度；整段文本发往现有固定官方账户主机 | 已有两次 3.55s/4.92s 润色阶段观测；接口为私有账户后端。可先探测同账户更快模型，实测保真后再选 |
| 本地 ASR + GLM-4.7-Flash | [智谱官方公告](https://www.zhipuai.cn/zh/news/148)说明免费调用；仅文本发往 `open.bigmodel.cn`，凭据单独存 Keychain | 免费优先候选；[官方模型文档](https://docs.bigmodel.cn/cn/guide/models/free/glm-4.7-flash)支持流式。[思考模式说明](https://docs.bigmodel.cn/cn/guide/capabilities/thinking-mode)给出 `thinking.type=disabled`。需核账户限流及中文保真。429/失败沿既有规范化转写回退，切换其他目的地需用户选择 |
| 本地 ASR + Qwen Flash | [官方模型价格](https://help.aliyun.cn/zh/model-studio/qwen-flash)北京短上下文输入 ¥0.15/M token、输出 ¥1.5/M token；文本发往选定地域 DashScope | 低价付费候选。按1000输入+300输出token计算约¥0.0006/次，1000次约¥0.60；实际prompt和输出决定账单。采用非思考模式并做配对测试 |

当前建议先修复浮窗并保留本地 ASR；加速优先验证同一 ChatGPT 账户可用的小模型，其后评估免费 GLM 润色。若本地中文识别质量成为主要问题，再比较 Paraformer/Qwen 与 Seed-ASR。所有新服务仍沿完整整段润色流程；原音频只在明确选择云 ASR 时上传。

本轮服务资料比较已补充 GLM/ChatGPT 真实账户的合成配对计时，结果见下。统一素材覆盖否定、撤回更正、专名、数字、中英混输、长段和指令作为待润色数据；目标为每素材每侧5次。GLM 首次失败后按原有有界策略停止，故 GLM 的配对覆盖为前三类各1次成功、第四类1次失败，其余未执行。完整输出延迟、失败和字面量分别记录；首 token 未采集。

## 已批准的 GLM 接入增量

负责人已在本轮卡片明确批准“智谱免费润色接入与实测”，包括固定目的地、整段文本/相关术语上云、录音本地、独立 Keychain 凭据及原失败回退。

Pstack GLM 候选 A/B 分别位于 `/tmp/chattype-108-glm-a.md`、`/tmp/chattype-108-glm-b.md`，主 Agent 已完整读取。两者均选择现有 polisher 内私有 provider 分支，比较后的另一形态为双 polisher + factory。采用前者，共用现有 prompt/result/pipeline，凭据和 wire format 分开；新增公共转发工厂的收益不足以抵偿调用迁移。跨模型 cross-judge 缺口同前。

调用方仍调用 `TextPolishing.polish(text:terminologyEntries:hintTerms:)`。`TextPolishConfig.provider` 为唯一目的地选择，值为现有 ChatGPT 或新增 GLM Flash；旧配置默认 ChatGPT。保留旧 `chatGPTAuthEnabled` 的原禁用效果作为 ChatGPT 分支可用性条件，mode 继续统一控制开关。新增字段有解码默认值，旧历史和配置保持可读。

### 凭据、请求与设置

- 新增可注入 `GLMKeyStoring`，提供 load/save/contains；生产使用独立 Keychain service the existing GLM Keychain service，account `default`，沿 SecItemAdd/Update 范式；测试用内存实现。UI只通过contains读保存状态，SecureField仅保存新输入，保存成功清空；配置、日志、报告与历史均不写 Key。
- `TextPolisher` 在选择 GLM 后只访问 GLM store；ChatGPT 分支只取 OAuth。发送前校验原 ChatGPT endpoint 为已审计 HTTPS ChatGPT host；固定接口拒绝全部重定向（包括同host、异port或HTTPS降级），OAuth 和 GLM key 各自绑定受批准目的地。
- GLM endpoint 固定 `https://open.bigmodel.cn/api/paas/v4/chat/completions`，model 固定 `glm-4.7-flash`；`stream=true`、`thinking.type=disabled`，messages复用原完整 prompt、术语与全文，temperature/max_tokens沿现有配置。provider失败继续经原 pipeline 的规范化文本回退，取消向网络任务传播；保持一次插入和截断保护。
- GLM SSE 累积 `choices[0].delta.content`。非空内容且 `finish_reason=stop` 视为语义完成，及时结束传输；`length`、filter、error、坏JSON、仅[DONE]以及无stop的EOF均失败。选择候选A的stop语义终止，避免额外等待连接关闭。仅接收 content，忽略 reasoning_content。
- AI Polish 设置增加 provider Picker、GLM SecureField、保存Key按钮及明确的已保存/未保存状态。保存Key仅更新Keychain；用户沿既有 Save Settings 提交provider选择，新pipeline使用新配置快照，进行中会话沿旧快照。Key保存失败保留输入与原配置，明确显示失败。明确选择缺Key时阻止 Save Settings 提交GLM，显示“先保存GLM API Key”，磁盘与当前运行配置保留原值；用户也可切回ChatGPT后正常保存。直接编辑配置或保存后移除Key时，运行端仍返回providerUnavailable并沿原管线回退。全程不自动转发其他域名。设置说明文本上云、音频本地和免费模型可能限流。

### 写入与验证范围

新增 `Sources/ChatType/GLMKeyStore.swift`；修改 `Sources/ChatType/AppConfig.swift`、`Sources/ChatType/TextPolisher.swift`、`Sources/ChatType/PolishResponseTransport.swift`、`Sources/ChatType/PreferencesWindowController.swift`、`Sources/ChatType/BenchmarkRunner.swift`；测试限定 `Tests/ChatTypeTests/ConfigTests.swift`、`Tests/ChatTypeTests/TextPolishTests.swift`、`Tests/ChatTypeTests/StreamingTranscriptTests.swift` 和新增 `Tests/ChatTypeTests/GLMTextPolisherTests.swift`。优先由默认注入store复用现有Coordinator工厂，保留其业务顺序。已有 `TextPolishProviderID.allCases` 派生选择/状态UI。品牌、ASR两条路由与语音采集沿现状。

单元检查旧配置、显式provider与mode、缺key、固定host/参数、token目的地隔离、跨域重定向拒绝、SSE stop/断流/length/filter/坏JSON、429和取消；只注入假凭据/网络，不触碰真实Keychain。设置通过原生安装版验证安全框、保存状态及生效路径。

合成配对 benchmark 复用现有7种素材，`CHATTYPE_BENCHMARK_POLISH_MODELS` 中的固定 `glm-4.7-flash` 显式选GLM，其余模型显式选ChatGPT，避免把GLM结果标成ChatGPT模型；凭据门禁逐provider检查，GLM独立检查Key，不受benchmark全局ChatGPT启用门禁影响。7种素材每种、每侧各≥5轮交错，报告完整耗时中位数/范围、失败比例和字面量/语义保真，API不可用样本不计作成功提速。采用标准为配对完整输出中位数下降，否定、更正、数字与专名保真通过；失败与异常值逐类保留，差异小于运行波动时结论列为不明确。现有 benchmark 未采首token，先以完整输出耗时判断，首token保留后续观测项。线上实测的标准 API Key 通过应用 SecureField 写入 Keychain；用户已明确授权 Agent 使用官方 Computer Use 创建专用 Key 并安全填充。凭据不进入聊天、脚本或命令行。

实施前对此新增边界做 EGM 定向可实施性检查。实现/全测/安装/设置可交互和实际GLM成功、配对质量/延迟分别记录；缺Key时保持本轮浮窗修复候选可用，GLM线上验收列为等待安全输入。

GLM 增量 EGM 首轮提出缺Key时保存行为未定的1项Major，及写入路径、重定向边界、配对提速判据三项Nit。现稿固定缺Key阻止提交、全部拒绝重定向、补齐真实文件路径及7素材逐侧5轮判据。fresh-context `egm_glm_recheck_108` 定向复核剩余0/0/0。`implement_glm_108` 独占上述GLM文件，主Agent保留文档和安装/GUI单writer。

GLM实现已交回主Agent集成。30项定向检查通过；主侧将拒绝重定向的会话保持为共享连接池，保留原连接复用。Settings Test Connection发送一条人工合成文本，按真实响应报告成功或安全错误。完整检查触发的账户就绪通知覆盖processing状态问题，通过coordinator仅在idle刷新ready状态修复；实际业务处理顺序保持。最终canonical `scripts/check.sh` 235项通过，策略、landing page合同、打包元数据通过，见 `~/Library/Logs/ChatType/iteration-108/glm-check.log`。

最终 GLM 候选已安装 `/Applications/ChatType.app`，0.5.1(1)、Team HJG65XBC25、签名时间2026-11-10 01:52:27。官方 Computer Use 验证 provider Picker、SecureField、Save Key 和缺 Key 阻止 Save Settings；用户完成 BigModel 短信登录并明确确认创建专用标准 API Key `ChatType Free Polish`。Agent 用官方 Chrome 创建后，将一次性凭据直接写入应用安全框并保存 Keychain，看到 `Key saved`，安全框清空；网页确认妥善保存，临时变量和中转剪贴板清理。报告、配置、日志均无凭据内容。

应用 `Test Connection` 发送人工合成文本，实际返回 `Connected: GLM-4.7-Flash.`。GLM 使用非思考、流式、整段原提示；生产 provider 保留 `chatGPTAuth`/`always`，GLM 的真实调用通过独立 benchmark 选择，不改变默认配置。

### GLM 配对实测与采用判定

在正式安装版用 LaunchServices 启动 synthetic-only benchmark，7类素材、每类计划5轮、模型顺序交错；没有调用音频付费 API。完整输出计时如下：

| 模型 | 成功/尝试 | 完整输出中位数 | 成功范围 | 失败/质量范围 |
| --- | ---: | ---: | ---: | --- |
| ChatGPT `gpt-5.6-terra` | 35/35 | 2215ms | 1537–5293ms | 严格字面量30/35；长段5次将普通词 polish 首字母大写，原否定、更正、数字及约束保留 |
| GLM `glm-4.7-flash` | 3/4 | 29714ms | 14692–35245ms | 第4次 HTTP429 后停止；前三类字面量3/3，其余质量未覆盖 |

GLM 三次成功依次为 short14692ms、correction35245ms、literals29714ms，long遇429。该账户 GLM 的速度和可用性均未达到采用标准，保留可选入口及安全 Key，默认继续 ChatGPT。前三次小样本不形成全素材质量结论；服务排队、网络、生成各自占比未知。ChatGPT 完整输出的35次成功与5项严格字面量差异分别保留，未调整检查口径。

原始合成结果 `~/Library/Logs/ChatType/iteration-108/paired-polish.jsonl`，汇总 `paired-polish-summary.json`，进程诊断 `paired-polish-stderr.log`。记录包含人工素材及输出，无用户录音和凭据。

## 浮窗修复当前交付证据

- implemented / checked：浮窗五文件及9个新增回归已集成；canonical `scripts/check.sh` 共226测试通过，策略、landing page合同和打包元数据检查通过。`~/Library/Logs/ChatType/iteration-108/check.log`、`targeted-tests.log`、`footer-test.log`。
- packaged / installed：canonical包安装到 `/Applications/ChatType.app`，0.5.1(1)、Team HJG65XBC25。五状态视觉图位于 `~/Library/Logs/ChatType/visual-acceptance/20261109T173301Z/`。
- 安装版终态：官方Computer Use观察到成功状态收起；辅助CoreGraphics窗口计数 `visibleHUDCount=0`。普通error先显示，再等待2.2s后离场，计数亦为0。日志 `result-after-deadline.log`、`error-after-deadline.log`。
- 安装版手动位置：官方Computer Use在长段录音demo中完成原生drag；松手后frame为x36/y712/w480/h140，再等待2.4s跨多次250ms tick，frame保持相同。`drag-release.log`、`drag-stable.log`。拖动后内联关闭收起HUD。早期另一拖动样本因60s演示进程到期而不计为稳定性结果；测试demo保留时间调整为180s以支撑后续检查。
- 本机真实语音现场进一步观察到录音→processing→HUD消失：产品匿名记录为2026-11-10 01:53:46、语音69.893s、ASR收尾109ms、润色4222ms、停录合计4462ms、pasted。观察先保护用户当前录音，处理结束后再安装GLM候选。该证据覆盖浮窗修复及原真实业务路径；GLM独立路由的安全配置、连接与配对结果见上。记录 `live-overlay-result.json`。

## 同账户轻量模型实测结论

依据 [OpenAI 当前模型说明](https://learn.chatgpt.com/docs/models?surface=app)，Luna 用于明确、重复的转换任务。固定原 ChatType 账户、主机、完整 prompt 和术语，探测 `gpt-6-luna`、`gpt-5.6-luna`，各7类素材1轮均返回；5.6-Luna 在指令作为数据素材删去“发给朋友”的意图。随后比较6-Luna与当前Terra，每类每侧5轮交错，结果：

| 模型 | 成功/尝试 | 完整输出中位数 | 范围 | 严格字面量 |
| --- | ---: | ---: | ---: | ---: |
| gpt-5.6-terra | 35/35 | 2057ms | 1588–5791ms | 30/35 |
| gpt-6-luna | 35/35 | 1727ms | 1186–4334ms | 30/35 |

6-Luna中位数下降16.04%，7类逐类中位数均下降；预设明确加速门槛为至少20%。两侧严格差异均为长段普通词polish/Polish大小写，原命令和专名保留。主Agent逐条读取35条Luna完整输出，发现指令作为数据的第1/3轮删去收件意图和“暂不发送”，第5轮删去收件意图；该项语义保真2/5。否定约束与完整意图丢失触发保真门槛失败，保持 `gpt-5.6-terra`。

原始记录 `~/Library/Logs/ChatType/iteration-108/luna-paired.jsonl`、`luna-paired-summary.json`。本轮未改变生产模型，无新增数据目的地和按量音频调用。合成比较仅覆盖7类素材，未采首token，速度统计不外推全部用户长段。

采用前 EGM 定向评审报告 `/tmp/chattype-108-luna-review.md` 提出1项Major：Settings当前只展示ChatGPT模型，草案假定存在编辑字段。由于候选在速度/保真门槛失败，采用与回滚执行步骤已退出本轮；本轮无模型配置变更。未来模型采用需要明确公开 `config.json` 写入及正常进程重载方案，或另行确定UI范围。已保留当前配置并在正式安装版重新选中/保存 ChatGPT Auth。

## 108 最终现场与后续选择

- implemented：终态收起、拖动位置所有权和最近安全避让已修复；可选 GLM 固定接口、安全凭据及真实连接测试已接入。
- checked：最终候选235项测试及既有策略/landing/包元数据检查通过，`glm-check.log`。本轮服务比较均由正式安装版执行，音频继续本地；整段润色和一次粘贴流程保持。
- packaged / installed：0.5.1(1)正式包已安装至 `/Applications/ChatType.app`，签名Team HJG65XBC25。108为迭代编号。
- live accepted：成功/普通错误的定时收起、拖放后跨多次几何tick保持、关闭取消及真实语音处理后收起/粘贴已有现场证据。GLM Key保存和真实API连接通过；GLM速度/可用性门槛失败。Luna配对完成，保真及20%速度门槛失败。
- default / left running：官方Computer Use重新选择 ChatGPT Auth并点击Save Settings，再真实测试显示 `Connected: ChatGPT Auth.`；持久配置读回 `provider=chatGPTAuth, mode=always, chatGPTResponseModel=gpt-5.6-terra`。正常安装版PID31999运行，AI Polish Settings保留可见。智谱专用Key继续仅存Keychain，无默认流量。

创建专用Key的掩码截图：`~/Library/Logs/ChatType/iteration-108/glm-key-created.jpg`。轻量模型EGM报告归档为 `luna-adoption-review.md`。

本轮完成浮窗问题及免费候选的接入/实测，最终润色明显提速目标仍待更合适服务。建议下一候选为保留本地ASR、仅把整段润色送往Qwen Flash；官方短上下文参考1000输入+300输出token约¥0.0006/次。DashScope属于新的文本目的地和按量接口，当前未接入、未调用；下一轮需先明确地域、费用、凭据及文本出境边界，再按相同保真素材实测。云ASR先保留为质量备选：Paraformer每月免费10h适合成本优先，Seed-ASR适合对照公开豆包语音产品线。
