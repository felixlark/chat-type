# 实时转写与最终润色：三方案评估

日期：2026-11-09（Asia/Shanghai）。状态：已完成 EGM 独立设计/实施准备评审及定向复核，进入产品讨论。

[EGM 评审与处置记录](reviews/realtime-transcription-2026-11-09.md)

## 结论与本轮边界

建议优先验证 **B：本地实时转写 + 独立的整段最终润色**。这台 Mac 的 M1 Max / 64GB、macOS 27.2 适合先评估 Apple SpeechAnalyzer；中文夹英文、术语准确率决定是否采用。**C：Fun-ASR 实时转写 + 千问 Flash 润色**作为可直接对照的云端候选；**A：现有 ChatGPT 账户私有链路**保留为基线与现有用户路径。

本轮按“完成三种方案对比后，找 EGM 评审，再进一步讨论”的顺序交付调研与代码迁移设计。运行代码、服务选择、付费请求、权限和安装版切换安排在讨论定案后；本报告明确列出这些待实施项。既有工作区改动保持原样。

用户目标：讲话期间持续看到文字，停录后的整段润色更快；保持 F5 开始/停止、取消、恢复、术语保护、润色语义与安全粘贴流程。

**固定处理顺序**：完整 ASR 定稿 → 现有术语归一化 → 一次整段 AI Polish（含现有疑似截断重试）→ 现有保护性归一化 → 一次安全粘贴或剪贴板结果。录音期间的 partial 仅用于预览；后续自我纠正仍由完整文本润色处理。持续预览放在 ChatType 自有浮层；现有应用输入框在最终完成时接收结果。逐字写入其他应用涉及新的编辑/替换语义，另行决定。

完整 ASR 已成功时，润色 HTTP/流式错误、完整性保护或二次疑似截断沿用现有规范化文本回退与错误标记；用户取消继续走取消分支。

## 1. 当前实现和实际瓶颈

### 1.1 候选、环境与证据范围

- ChatType checkout：`issue-6/runtime-baseline-inheritance`，HEAD `faa5918f7f7c448074718ae88163e741cb8bc290`，存在其他任务未提交修改；下面源码结论针对本轮读取的工作区。
- 本机：MacBook Pro，Apple M1 Max，10 核 CPU，64GB，macOS 27.2。
- 只读 Speech 框架探测：`SpeechTranscriber.isAvailable=true`；`supportedLocales` 包含 `zh_CN`、`zh_HK`、`zh_TW` 与多种英语；`installedLocales` 包含 `zh_CN`、`zh_TW` 和英语。探测没有请求麦克风、下载模型或开始识别。
- `scripts/doctor.sh`：`/Applications/ChatType.app` 签名有效、LSUIElement=true、正常进程在运行；转写为 `chatGPTManagedAuth`，润色模型为 `gpt-5.6-terra`，转写/润色均指向 `chatgpt.com`。本次未读取凭据明文。
- 安装版与源码的精确构建对应关系本轮未核验；匿名历史日志缺少逐条 build/model 字段，以下用作用户现状的观测基线。新候选的提速结论须通过同版本配对测试建立。

### 1.2 源码链路

| 位置 | 当前行为 | 延迟含义 |
| --- | --- | --- |
| `AudioRecorder.swift` | `AVAudioRecorder` 保存录音；接口返回停录后的 `RecordedAudio` | 当前没有供实时识别使用的 PCM frame 输出 |
| `AppCoordinator.swift:stopRecording` | 第二次 F5 后才调用 `startProcessing` | 讲话期间没有 ASR 请求与文字事件 |
| `ChatGPTTranscriber.swift:transcribe` | 读完整文件，准备上传，取得账户 token，multipart 请求私有 `/backend-api/transcribe` | 上传和服务端 ASR 完整落在停录之后 |
| `AudioUploadPreparation.swift` | 15 秒以上录音已有 AAC 上传优化，保留原 WAV | 长录音压缩已存在，可复用 |
| `DictationPipeline.swift:prepare` | ASR → normalize → polish → normalize | 转写与润色串行；润色依赖完整文本 |
| `TextPolisher.swift` | 请求 `stream=true`、`reasoning.effort=none`；使用 `URLSession.data(for:)`，收齐后解析 SSE | 当前没有首 token 展示或逐事件耗时；增量读取改善首字体验，完成耗时由生成和网络共同决定 |

术语候选索引、相关词条裁剪、禁思考参数和 AAC 优化都已实现。继续压缩本地归一化的收益空间应根据实测决定。

### 1.3 有界匿名耗时观测

从现有 `~/Library/Application Support/ChatType/latency.jsonl` 取最后 100 条，只输出时间、耗时、状态等统计；未提取转写内容或错误正文。时间范围为 2026-10-12 13:43:20 至 2026-11-09 20:17:51。91 条成功（88 pasted、3 clipboard），9 条 error；成功样本均记录了润色尝试。

| 阶段 | 成功样本 p50 | 成功样本 p95 |
| --- | ---: | ---: |
| 音频时长 | 11.284 秒 | 114.296 秒 |
| ASR | 1.837 秒 | 5.781 秒 |
| 本地归一化 | 0.068 秒 | 0.320 秒 |
| AI Polish | 2.425 秒 | 8.106 秒 |
| 注入 | 0.066 秒 | 0.089 秒 |
| 停录后总耗时 | 4.591 秒 | 12.291 秒 |

各阶段分位数取自各自分布，总耗时独立统计。`polishMs` 包含失败/截断重试等情况；这份日志没有首 token、排队、首包等分解信息。9 条错误单列，未通过剔除错误声称可靠性提升。

11 月 9 日观测例：86.0 秒录音，ASR 6.886 秒、润色 5.305 秒、总计 13.078 秒；117.0 秒录音，ASR 4.035 秒、润色 7.100 秒、总计 12.291 秒。当前长段等待同时受停录后 ASR 和最终润色影响。新候选应分别测量两者。

## 2. 接线小妹最新聊天室代码

### 2.1 版本选择

远端 main 为 `d65cbe369007fe5937f3fd3d2f16047635b18a7f`；其代码以旧 Voice Lab/电话链路为主。聊天室的最新发布归档位于 **`release/1.2-saloon-20261108@f93627388902aae8ec95749f6c2093050cf1dd7d`**，版本 **1.2 (22)**。本轮通过 `git fetch` 和 `git show` 直接读取该分支，原 checkout 保持原位。

[发布归档代码](https://github.com/AlinaZhang0713/jiexian-xiaomei/tree/f93627388902aae8ec95749f6c2093050cf1dd7d)

[build 22 发布与验收记录](https://github.com/AlinaZhang0713/jiexian-xiaomei/blob/f93627388902aae8ec95749f6c2093050cf1dd7d/docs/releases/2026-11-08-voice-room-m1-execution.md)

发布记录记载服务端实际 ASR_FINAL、受限内存媒体验证与连接手机验收通过；该记录提供历史交付依据。当前云端运行态及用户目标手机安装状态本轮未访问。

### 2.2 真实转写方式

1. LiveKit 接收真人独立音轨，`run_transcriber` 用 `rtc.AudioStream` 输出 16kHz、单声道、20ms PCM frame。
2. `Speech.recognize` 通过 DashScope 双向 WebSocket 发 `run-task`，默认 `fun-asr-realtime`，等待 `task-started` 后持续发送二进制 PCM。
3. 服务端 `result-generated` 中只有 `sentence_end=true`、非 heartbeat、非空文本进入 `on_final`。当前代码过滤中间文本。
4. 以 `task_id:sentence_id` 生成稳定片段 ID，保留时间范围和 speaker，通过内部接口幂等保存。
5. 结束时发 `finish-task` 并等待 `task-finished`，Worker 收尾后报告 ready/failed，已有文本继续保留。

[speech.py：真实双向 ASR 协议](https://github.com/AlinaZhang0713/jiexian-xiaomei/blob/f93627388902aae8ec95749f6c2093050cf1dd7d/services/voice-room-agent/src/voice_room_agent/speech.py)

[main.py：真人音轨、片段编号与结束收尾](https://github.com/AlinaZhang0713/jiexian-xiaomei/blob/f93627388902aae8ec95749f6c2093050cf1dd7d/services/voice-room-agent/src/voice_room_agent/main.py)

聊天室发布版 README 规定“只有 final 句子入库，不向房间展示滚动字幕”；iOS LiveKit adapter 中存在 `isFinal` 和同 ID 更新能力。**端到端已实现的是持续收音、逐句定稿与记录；讲话中不断修订的字幕仍需在 ChatType 中接通上游 partial 与浮层。** 旧 Voice Lab 的 250ms 轮询与千问 Omni 电话桥属于独立旧路径。

### 2.3 “最终润色”的核实

聊天室 `voice_room_m1.py` 的 `postprocess_result/finalize_postprocess` 读取已保存片段与 Worker 完成状态，确定 ready/partial/failed；关房后有 60 秒收尾宽限。这里没有调用 LLM 做整段文本重写。`agent_text` 调自定义 HTTPS 端点生成被点名 Agent 的回答，后续 TTS 播放；这是聊天室回复能力。

ChatType 可以迁移持续采集、按 ID 更新、final drain、取消代际保护等机制。整段润色继续使用 ChatType 自己的 `TextPolishPromptBuilder`、流程及完整性保护。聊天室的 LiveKit/SFU、电话 8kHz 降采样、TTS、订单与房间数据库无需加入单人听写产品。

## 3. 三种后端方案

| 比较项 | A：ChatGPT 账户链路 | B：Mac 本地 ASR + 最终润色 | C：全云实时 ASR + 最终润色 |
| --- | --- | --- | --- |
| 讲话期间出字 | 当前私有文件接口缺少已验证的实时输入契约；分段上传可试验句级预览 | Apple SpeechAnalyzer 原生 volatile/final；WhisperKit 可做增量候选 | Fun-ASR 可返回句中结果和句末 final；需接入 partial |
| 停录后关键路径 | 上传整段 + ASR + 润色 | ASR 尾部定稿 + 润色；成熟后可移除整段上传等待 | finish-task/尾部定稿 + 润色 |
| 质量依据 | 用户现有词典与历史样本；私有 ASR 还带轻度整理 | 中文、英文术语和中英混输需在本机配对测量 | Fun-ASR 与 Qwen ASR 有中文/多语种能力；ChatType 工作负载需配对测量 |
| 免费与成本 | 现有账户额度/条款；API 免费资格单独核验 | ASR 无按量服务费；润色可保留账户链路、测试免费 GLM 或低价 Flash | ASR 按时长/Token；润色按 Token；免费额度具有条件和有效期 |
| 数据流 | 完整录音和文本到现有官方账户主机 | 音频留 Mac；选择云润色时文本与相关词条送所选服务 | 音频和润色文本均送获准服务商 |
| 主要代价 | 私有接口、挑战/尾延迟；分段策略增加请求 | 模型资源准备、算力/电量、混输质量与支持系统范围 | 凭据、网络、费用、断线丢片风险与账单观测 |
| 当前建议 | 基线保留 | 优先做小范围实测 | 并列验证的云候选 |

### A：继续使用 ChatGPT

现有私有转写依赖完整文件上传，缺少在当前凭据路径已验证的实时音频会话。将录音按句切开上传可以产生句级预览，但引入分段上下文、重复/漏字、请求数及最后纠正合并问题；要保留现有整段识别质量，末尾还需完整识别，从而保留部分停录后等待。A 的工程确定性和实时首字体验弱于 B/C。

可保持现有流程的改进：增量读取润色 SSE，记录首 token 与终止事件时间；从完整输入发一次润色，按 completed 事件完成；候选模型用同一 prompt、词典和质量集做 A/B。当前已使用 none reasoning，后续速度结论依赖实测。分句提前润色会影响后文纠正前文的语义，维持整段润色策略。

OpenAI 官方实时转写文档当前推荐 `gpt-live-transcribe`，使用独立 Realtime 转写会话和标准 API key。将该公开能力用于 ChatType 需要新增计费、凭据及域名决定，归入 C 的 OpenAI 备选。当前 ChatGPT OAuth 凭据仅留在原固定账户主机。[OpenAI 官方实时转写](https://developers.openai.com/api/docs/guides/realtime-transcription)

对齐豆包输入法：产品官网展示语音识别、中英混输与长文整理，本轮没有获取同设备首字/停录后延迟对照数据。以首字、持续更新、最终定稿三个指标对齐体验；A 当前路径对“边说边出字”的达成把握较低。[豆包输入法官网](https://ime.doubao.com/pc)

### B：Mac 本地实时转写

**B0，先验证采集与识别：Apple SpeechAnalyzer/SpeechTranscriber + 原有 ChatGPT 整段润色。** 使用单一 AVAudioEngine tap，PCM 同时写恢复 WAV 并送 analyzer，读取 volatile/final；停止时 finalize，得到完整 transcript 后继续原 pipeline。Apple 官方描述该路径为设备端识别，模型资产由系统下载；本机只读探测已确认模块可用、简体中文模型已安装，实际采集、混输质量和延迟待测。其他设备仍在运行时核对模块、locale 与资源。保留现有 macOS 13 支持范围：低版本继续走已选现有路径。[Apple 实现说明](https://developer.apple.com/videos/play/wwdc2025/277/)、[设备/语言支持检查](https://developer.apple.com/documentation/speech/speechtranscriber)

**B1，进一步压缩润色尾延迟：同一完整 prompt 输入 → 非思考 GLM-4.7-Flash 或 Qwen Flash。** 智谱官方发布说明提供免费调用，适合作为免费候选；账户实际资格、限流、队列延迟和当前控制台价格要在接入时核对。免费定价和流式能力分别有依据，实际速度与润色质量待测。[智谱免费发布说明](https://www.zhipuai.cn/zh/news/148)、[GLM 模型能力](https://docs.bigmodel.cn/cn/guide/models/free/glm-4.7-flash)

若 Apple 混输质量未达标，再对照 WhisperKit 多语种模型。其 Swift/Core ML 接入及麦克风 stream 适合此仓；滑窗识别需要确认稳定前缀、时间范围替换与尾部收尾。WhisperKit 仓库当前已重定向为 argmax-oss-swift，接入前固定经过验证的版本、模型和许可证。本轮保留为替代候选，避免一次增加多个本地引擎。[Argmax 官方仓库](https://github.com/argmaxinc/argmax-oss-swift)

B0 有望减少停录后的完整 ASR 等待；其润色耗时仍由原 ChatGPT 模型决定。B1 的“更快”以同输入完整输出耗时与质量实测为采用条件。

### C：全量上云

**优先对照：Fun-ASR-Realtime + Qwen Flash 非思考整段润色。** 直接从 ChatType 连接服务商 WSS；只移植协议和事件管理，单人听写无需聊天室服务器。Fun-ASR 复用参考项目已有的协议证据。千问新版 `qwen-audio-3.1-asr-flash-streaming` 作为质量对照候选，官方列有热词/上下文能力，协议与音频 Token 计费需单独核对。[阿里 ASR 型号比较](https://help.aliyun.com/en/model-studio/asr-model)

Fun-ASR：`run-task` → `task-started` → PCM binary → `result-generated`（同句替换 partial / sentence_end 定稿）→ `finish-task` → `task-finished`。根据服务商事件中的 task/sentence ID 和音频时间排序；忽略 heartbeat；连接断开后已有 final 和本地原音频继续保留。重新送音涉及额外费用，使用显式 Retry 和已选 provider；保留错误与缺失范围的真实状态。[客户端协议](https://help.aliyun.com/en/model-studio/fun-asr-client-events)、[服务端协议](https://help.aliyun.com/en/model-studio/fun-asr-server-events)

北京地域价格快照：Fun-ASR-Realtime、Qwen3-ASR-Flash-Realtime 都为 ¥0.00033/秒（¥1.188/小时）；前者/后者标注 10 小时、90 天条件免费额度。Paraformer-Realtime-v2 为 ¥0.00024/秒，标有每月 10 小时免费额度。Qwen Flash 输入/输出每百万 Token 为 ¥0.15/¥1.5；Qwen3.8 Flash 为 ¥0.8/¥2.7。新版 ASR 3.1 streaming 为输入/输出每百万 Token ¥6/¥4.5。以上为公开牌价，账户适用资格和真实 Token 数在接入时核对。[官方价格](https://help.aliyun.com/zh/model-studio/model-pricing)

成本演算（全部由上述单价推算，未发起计费调用）：每天 30 分钟、每月 30 天为 15 小时；按每次恰好 1 分钟共 900 次、每次润色 2,000 输入/1,000 输出 Token，Fun-ASR+Qwen Flash 在无免费额度时约 **¥19.44/月**（17.82+1.62）；首期可用 ASR 10 小时额度时约 **¥7.56/月**。换 Qwen3.8 Flash 润色约 ¥3.87/月，总计 ¥21.69/月。重试、静音、词典和实际长文 Token 会改变费用，实际账单以供应商为准。已有阿里额度或密钥的跨项目复用需要本产品授权，凭据留在 Keychain。

自托管云 ASR 的机器租赁、部署、升级和观测责任增加；对单用户当前工作量，先用托管接口验证更容易核对单位成本与真实质量。

## 4. 代码迁移设计与实施边界

### 4.1 可复用机制

| 接线小妹已读实现 | ChatType 对应更新 | 保持的语义 |
| --- | --- | --- |
| `speech.py:recognize` 双向任务握手/finish | 选 C 后新增 `StreamingTranscriber.swift`、`DashScopeStreamingTranscriber.swift` | 原录音保留、错误可重试；停录后 drain final |
| `main.py:run_transcriber` PCM/句子时间范围 | `AudioRecorder.swift` 提供单一 PCM 源；本地路线新增 `LocalSpeechTranscriber.swift` | 一份采集同时驱动恢复录音、音量、识别与完整性检查 |
| `task_id:sentence_id` / final 幂等写入 | 新增 `StreamingTranscript.swift` 负责本地 session/segment/revision | partial 替换、final 只采纳一次、取消后的旧事件丢弃 |
| iOS 同 ID 更新 | `AppCoordinator.swift` 转发 preview，`OverlayController.swift` 显示 | F5/ESC/关闭保持原动作；视觉延用现有样式，经前后对比确认 |
| finalization 保留 ready/partial/failed | 录音结束等待本次 ASR 的尾部；错误保留 WAV 和 final | 识别缺失时明确错误，保留手动恢复 |

表中新增文件是讨论后的实施清单，本轮尚未创建生产入口。源项目正文无整段润色可搬运；ChatType 的润色更新集中在 `TextPolisher.swift` 的增量网络读取和获准的传输 adapter。

### 4.2 固定状态与接口约束

- 会话沿用 `activeSessionID`，每次新录音/Retry 都取得新代际。实时事件带 sessionID、segmentID、音频 start/end 和 partial/final；adapter 先把各提供商的增量或覆盖文本转换成同段完整快照。
- reducer 按音频时间和 provider 序列形成文本；重复事件幂等，旧 revision 丢弃，final 之后迟到的 partial 丢弃。局部引擎若回改时间窗，adapter 用时间范围覆盖，避免把整窗假设拼接成重复段。
- 第二次 F5 停止音频输入并 finalize；收到当前会话全部 final 与完成信号后形成唯一完整 transcript。pipeline 接入已定稿 ASR 结果，继续执行原 normalize/polish/normalize。首字与润色 SSE 可预览，最终安全插入保持一次。
- 握手、ASR final drain 和润色终止读取都必须有可取消的失败出口。停止送音后连接仍存活却缺失完成信号、本地 analyzer finalize 停滞，均在所选引擎的收尾期限后转为 partial/failed、退出 processing、保留 WAV 与已完成片段，缺失文本禁止自动粘贴。握手失败没有可提交 ASR；完整 ASR 后润色失败继续走前述安全回退。参考 Fun-ASR 实现的 drain 为 10 秒，ChatType 的具体等待参数随选型、真实收尾测试和负责人讨论定稿；新增/调小的期限须在 PR「新增限制」列位置、值和依据，实施前定稿，取消随时打断等待。
- ESC、内联关闭和取消在 MainActor 上令当前 session 失效，关闭音频及 provider task；每个回调、最终提交与剪贴板更新前检查 session，防止迟到粘贴。
- 识别/网络失败时保留原音频及已完成片段，结果状态明确 failed/partial。现有 ChatGPT 的 3 次自动 / 1 次手动 Retry 策略保持；新提供商的重发须按讨论确认的费用与重试语义处理。
- 恢复链路接入 `RecoveryHistory.swift`：复用现有 WAV 与记录，新增可缺省的 `streamingSnapshot`（provider/model、session、已定稿片段及时间、complete/partial 状态、已知缺失时间范围）。旧记录缺省读取，授权凭据不入快照。每次 final 更新同一会话记录；失败写入已完成 final 的拼接文本与错误，ASR 历史明确标记“部分转写”，支持复制已有文字。未知丢失范围标记未知，禁止把连续时间覆盖推定为内容完整。
- 流式故障后的手动 Retry 建议使用保存的完整 WAV 做一次完整重识别，生成新会话与新候选，不拼接新旧识别文本；沿用所选方案已获准的同一 provider，不自动换服务。支持离线文件输入的本地引擎读 WAV；流式云 ASR 按文件帧重放，重发计费时长在操作前显示。恢复历史中的原记录和部分文本继续保留。该收费重发策略需在产品讨论中明确采用，跨 provider 的恢复需用户主动选择。
- `DictationPipeline.swift` 的归一化、完整 prompt、自我纠正、疑似截断重试和保护性归一化行为不变。模型 adapter 只翻译鉴权、请求/响应封装；协议差异（thinking、SSE terminal）映射至相同语义。
- 现有 `chatGPTManagedAuth` / `openAICompatible` 两条持久化路线保留到讨论定案。B 或原生 DashScope 接入涉及产品路线调整，先明确获准替换/扩展范围；无自动第三 fallback、无凭据跨主机传递。

### 4.3 后续实施的文件范围

- 采集/状态/恢复：`Sources/ChatType/AudioRecorder.swift`、`AppCoordinator.swift`、`DictationPipeline.swift`、`RecoveryHistory.swift`，以及上表按所选方案创建的文件。
- 传输与配置：`TextPolisher.swift`、`AppConfig.swift`、`RuntimePreflight.swift`、必要的 Keychain provider adapter。配置默认值、域名和新增权限随所选方案明确。
- 展示/交付：`OverlayController.swift`、`OverlayVisualModel.swift`、`PreferencesWindowController.swift`、`LatencyRecorder.swift`、打包脚本的实际权限用途说明；沿用已存在的其他任务修改，由当前 owner 串行整合。
- 相关测试：采集测试、`DictationPipelineTests.swift`、`TextPolishTests.swift`、`OverlayControllerTests.swift`、`RecoveryHistoryTests.swift`、`AppCoordinatorCancellationTests.swift`，新增 stream/reducer/协议 fixture 用例。测试注入音频、网络、权限与存储，使用合成文本。
- 文档：`docs/operations.md`、`docs/architecture.md`、`docs/performance.md` 和发布说明，随着实际实现及验收更新。

恢复方式：新能力在用户选择并满足候选验收后切换；保留现有 provider 配置和录音格式。旧数据继续可读；失败可恢复原已选路径与原安装版。切换前归档当前签名安装包与版本记录，使用安装脚本恢复并通过 LaunchServices 启动。

## 5. 验证与采用判据（讨论稿）

**当前已完成：** doctor、源码链路读取、最新发布分支识别、匿名耗时统计、官方资料查证。三方案候选均未进行本轮真实 ASR/润色调用；运行代码、打包、安装和新能力现场验收待讨论后的实施。

建议测同一组公开/人工编写内容，30 条覆盖 5 秒短句、30 秒、120 秒；包含中文、中英混输、术语、数字、路径/URL、多目标、后文自我纠正和显式范围限制。记录每条完整参考文本、实际输出、原始音频时长、候选版本、模型/locale/词典、网络和冷/热状态。无声、取消、断线、尾音未定稿、迟到事件另作确定性用例。

确定性恢复/失败用例补充：已有 final → 断线 → 同记录保存 → 重开历史看到标为部分的文本 → 手动 Retry 整段音频一次；部分 final 已到达但 terminal 始终缺失 → 收尾期限退出并保留原文；取消立即结束收尾等待；完整 ASR 后润色 SSE 中断/HTTP 错误/二次截断 → 沿用规范化文本回退并记录错误；旧版恢复记录缺少 streamingSnapshot 继续可读。

| 验收维度 | 候选采用判据 |
| --- | --- |
| 首字 | 发声开始至首个非空可见文本，建议热态 p50 ≤0.7秒、p95 ≤1.5秒；冷启动另报 |
| 持续输出 | 连续说话期间持续修订；记录相邻可见更新间隔和最大停滞；建议 p95 间隔 ≤1秒 |
| ASR 收尾 | 停止至完整 ASR 定稿，建议热态 p95 ≤1秒；必须保留最后一句 |
| 最终速度 | 相同输入/提示词、模型固定的配对比较；建议最终可粘贴 p50/p95 比 A 基线均改善 ≥30%，同时单列润色首 token 与完整输出耗时 |
| ASR 质量 | 按类别报告 CER、术语/数字/路径准确率；采用候选的 CER 较基线恶化建议 ≤1 个百分点；关键字面量与明确限制逐条人工检查 |
| 润色质量 | 原有信息/顺序/纠正关系完整；30 条中关键要求、否定限制、数值和字面量零新增/遗漏；延用原 prompt 和保护逻辑 |
| 故障 | 取消后零晚到粘贴；断线/尾部缺失明确报错；原音频与已完成文本可恢复 |
| 资源和费用 | 记录 CPU、内存、热状态/电量、模型加载与下载、音频秒数和 Token；对照前台日常负载，报告实际值供决定 |

这些数值是待确认的验收目标。30 条用于候选筛选，p95 样本尾部仍需保留逐条结果；正式采用需按真实安装版旅程核验。豆包只在同设备、相同素材、相同计时口径下作体验参照，缺少数据时用上述目标描述。

检查顺序：注入式单元/协议检查 → `scripts/check.sh` → canonical package/install → 官方 Computer Use 在 `/Applications/ChatType.app` 验证 F5/F5、ESC、内联关闭、取消后重入、错误后 Retry、真实编辑器与剪贴板 fallback。正常菜单栏启动、无 Dock/额外窗口、设置访问、Cmd+Q、登录持久化、权限首用、最终正常运行按 `docs/operations.md` 分项报告。

原生安装、权限与 GUI 验收开始前读取项目指定的 native-product-acceptance runbook。设置页/新预览保留品牌图形与配色，做安装版前后比较；新增权限、域名、服务和费用在讨论中形成明确选择后实施。

## 6. 讨论需要确定的产品决定

1. 建议先走 B0 验证本地首字/混输质量，再以 B1 对照免费 GLM 和低价 Flash 的完整润色；C 用 Fun-ASR 作同素材云对照。选择 B/C 需要明确产品两路线规则的调整范围。
2. 本轮把“边说边出字”定义为 ChatType 浮层实时预览、停录后一次最终插入；沿用用户原有基本操作。
3. 润色服务候选需要确定允许发送的文本/相关词典、地域、凭据和测试费用；免费资格与容量在实际账户核对。既有 ChatGPT 凭据继续只用于原账户主机。
4. 手动恢复建议按原 provider 重识别整段 WAV，一次动作对应一次识别；计费展示及具体握手/收尾期限随方案一并定稿。

责任：本 chat 负责研究、候选整合和 ChatType 验收；Longbiao 决定服务、数据与费用、可见体验和采用判据。EGM 提供独立意见，意见与处置记录保存在同目录评审报告中。
