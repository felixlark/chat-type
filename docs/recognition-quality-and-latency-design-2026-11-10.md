# 识别质量恢复、实时预览与停录延迟：设计与验收

状态：调研与方案，EGM架构/实施准备独立评审及定向复核完成。已报告的实质缺口闭合；A质量恢复与测量合同可供产品定稿，B/C/D保留为有决策门的后续实验。2026-11-10，Asia/Shanghai。负责人：Longbiao决定产品取舍与现场验收；主Agent维护当前checkout及最终集成。当前仅设计，产品代码、安装版、配置和凭据保持。

[EGM评审与处置记录](reviews/recognition-quality-and-latency-2026-11-10.md)

## 1. 决策摘要与需求

建议分开处理质量恢复与尾延迟：A“本地预览＋原账户完整音频正式转写”作为质量恢复候选；尾延迟先以当前本地final版R0为速度基线，拆解整段润色的首token、生成和重试，再决定正式流式ASR或保真通过的快润色模型是否有足够收益。原整段润色和前后术语保护保留。A单独属于质量阶段；完整目标要求最终候选同时达到旧版质量与相对R0的速度改善。

用户要求同时纳入：原版本的中英混输/专有词质量、讲话期间持续出字、停录后更快完成、完整保留要求/否定/更正/代码字面量、F5/F5与取消/恢复/一次粘贴保持。pstack与SmartShadow为强制回归词。实时字幕承担即时反馈；最终结果的来源必须明确并有完整性证据。

原版“效果最好”是用户评价，指本地ASR替代前的账户音频路径；精确旧安装二进制尚未固定。源码基线为当前branch HEAD faa5918，相关原账户请求实现仍在。正式评测需固定复现该旧路径的构建/配置，不能用另一个模型冒充旧版。

## 2. 现版根因与证据

### 2.1 正常流程仍有术语校正，识别前的能力已变化

当前工作区DictationPipeline.swift、TerminologyNormalizer.swift相对HEAD没有修改，实际顺序仍为完整ASR→术语规范化→整段ChatGPT润色（含既有疑似截断重试）→保护性规范化→一次粘贴/剪贴板。

当前macOS26+ managed路径使用SpeechAnalyzer/SpeechTranscriber zh_CN。LocalSpeechRecorder把预览与最终文字放入RecordedAudio.localTranscript；ChatGPTTranscriber发现localTranscript后直接返回，promptIncluded=false，上传字节0。文件Retry还会因usesLocalSpeechForFiles=true再次走Apple文件识别。这条路径绕开原账户音频识别，保留后面的术语与润色。

原账户路径调用TranscriptionPromptBuilder(config.promptHintTerms)，带轻度语音整理、专名和代码字面量保护；服务器400/422后可沿既有策略去掉prompt重试，并在进程中缓存能力。故“发出了词表”与“服务实际接受词表”需分别观测，私有后台真实ASR模型ID未知。当前文本润色是gpt-5.6-terra；GLM/Qwen入口存在，默认均未启用。

配置实读：hintTerms=0项，词库12315项，pstack缺失，SmartShadow条目aliases为空；glossaryBudgetCharacters=240。实时recorder只传hintTerms。原ASR提示裁剪为600字符并按输入顺序截取；海量联系人会竞争预算。润色词表先按转写文本匹配候选，错误拼写缺少候选时纠错依据减少。以上是术语召回与覆盖问题，前后校正并未跳过。

10:12现场原始ASR：pstack→peacteg，SmartShadow→smar shade；最终文字中SmartShadow已恢复，pstack仍为peacteg。Apple官方说明SpeechTranscriber不使用contextualStrings，DictationTranscriber支持。只向当前模块补传一整份词库无法建立术语增强效果。

### 2.2 最后仍慢的原因

近期本地识别样本：

| 音频长 | ASR停录收尾 | 润色 | 停录总耗时 |
| ---: | ---: | ---: | ---: |
| 5.797s | 111ms | 6531ms | 6783ms |
| 66.593s | 151ms | 5082ms | 5326ms |
| 226.591s | 136ms | 11237ms | 11720ms |

数据来自产品匿名latency字段；ASR时间仅覆盖收尾，计算已在讲话期间发生。polishMs包含凭据/请求/生成和必要重试，当前缺少首token/重试次数分解，网络排队与生成各占多少未知。现版主要停录等待集中于整段润色。原日志91个成功样本的停录p50=4.591s、p95=12.291s属历史观测，不作为同素材因果对比。

最新76次合成文字配对：GPT完整输出中位2735ms，Qwen461ms；Qwen人工语义29/38通过、GPT38/38。Qwen出现新增模型/范围和遗漏约束，因此保留GPT；GLM此前14.7–35.2s并出现429。单纯把润色换快模型已有保真失败证据。当前SpeechCleanup变化也影响输入：原账户ASR可先做轻整理，当前输入为Apple文字，需在同音频评测中单独记录输入/输出长度。

## 3. 开源与官方主流路线

以下是代表性实现样本，覆盖常见架构；未采集市场占有率。2026-11-10通过GitHub官方API读取main SHA与最近release，代码结论针对所列SHA。仅调研代码，没有运行这些产品或证明其中文质量。

| 路线 | 已读实现与行为 | 对ChatType的含义 |
| --- | --- | --- |
| 同一流式引擎partial→final | Handy main 73cc8579、最近v0.10.0。live.rs在讲话期间feed/emit；停止finalize，完整非空final可直接用，空/失败才batch；actions.rs之后再做文本post-process | 持续识别可复用计算；需要证明final覆盖尾音及全部音频 |
| 预览引擎与正式引擎分离 | TypeWhisper main 2a0ae3e2、最近v1.8.2。DictationViewModel明确preview-only引擎的文字仅显示，停止直接取消预览，交dictation引擎正式识别；同引擎模式另有finish和完整性回退 | 用户猜测的双路径确实存在；预览速度与最终质量可分别选型 |
| 流式优先、整段回退、独立润色 | VoiceInk main 4bc74cad、最近v2.26。TranscriptionSession使用流式final，失败则文件识别；Pipeline依次词汇纠错、文本处理、AI enhance。TypeWhisper也在LLM前后应用词典 | 音频识别、术语保护、文本润色是可独立验收的层 |
| 流式一遍＋句末二遍修正 | FunASR main 20f26b7c，WebSocket协议有2pass-online与2pass-offline、hotwords、句末输入标记 | 预览与最终修正可以共享音频流；这是ASR两遍识别，无须通用多模态LLM |
| 原生音频多模态 | Gemini官方音频文档展示音频＋文字指令并做转写/理解；OpenAI官方说明Realtime原生音频与独立ASR转写是两条过程 | 路线存在；把预览字稿也喂进去会引入锚定错误，需要专门对照；本轮保持既有整段润色语义，暂作实验候选 |

TypeWhisper/Handy等同时存在多种路径，这些源码样本分别证明不同路径存在，产品总体分布仍未统计。原私有ChatGPT音频接口内部实现未知，“音频＋术语prompt”属于请求形态，内部ASR/多模态模型仍为未知。

### 接线小妹最新聊天室核实

main为d65cbe36（当前本机checkout49a96379较旧）；聊天室代码在release/1.2-build23-voice-room，SHA1f8c00a6，提交时间2026-11-10 01:31:38北京时间。此为已核最新命名聊天室发布分支；当前生产部署SHA未知。

speech.py使用fun-asr-realtime，PCM持续送WebSocket；句中on_partial、sentence_end句末on_final，finish-task后等task-finished。main.py以稳定片段ID发布字幕和保存final。voice_room_m1.py的postprocess检查收尾、缺片和ready/partial/failed，未发现调用LLM重写整段文本。agent_text是被点名Agent的回答，其职责为聊天室回答。电话桥另用Qwen Omni，和聊天室是独立路径。

## 4. 方案比较与选定顺序

| 候选 | 质量依据 | 实时与尾延迟 | 成本/数据流 | 取舍 |
| --- | --- | --- | --- | --- |
| A 质量恢复桥接：Apple仅预览＋原账户全音频正式识别＋原全文润色 | 回到用户认可的音频路径，再做同素材验证 | 首字保留；停录仍要上传/ASR/润色，完整尾延迟未必改善 | 录音重新发送现有固定chatgpt.com账户主机；私有接口额度/稳定性沿原边界 | 推荐第一实施候选，单独交付质量恢复证据 |
| B 有术语能力的正式流式ASR＋原全文润色 | 专有词/混输需对照A；优先北京Paraformer realtime v2，Fun-ASR realtime作质量对照 | 音频在讲话时发送，停录只需末包final与原整段润色 | 需新的ASR模型权限和音频到百炼的独立决定；Paraformer官方每月10h，超额¥0.864/h，实际账户待核 | 推荐最终提速候选；本轮设计阶段不调用 |
| C 全本地正式识别：DictationTranscriber热词或WhisperKit多语种＋原全文润色 | 免费、本地；中文夹英文需真实音频验证，热词与长段能力分开 | 可流式，资源/耗电/精度存在取舍；最终润色等待仍在 | 无按量ASR费用，可能下载模型；Apple短语总数建议≤100是厂商边界 | 在用户坚持音频本地时优先做可行性对照，未通过前保持A基线 |
| D 音频＋术语＋可选粗稿的多模态一次输出 | 可能利用声音纠错；输出忠实性/听命令风险需重新验证 | 有机会合并识别与整理，实际尾延迟未知 | 新接口/模型/音频目的地与费用，原整段润色职责发生变化 | 暂列后续实验，本轮不替换既有主流程 |

B托管Fun-ASR与开源FunASR2pass分别核实；云托管内部重打分实现未公开。B的真实final与逐句稳定片段是全文输入来源，逐句不提前润色，后文撤回/否定由原整段prompt处理。

本轮授权是调研与EGM设计，当前“音频留本地”的运行态保留。A会恢复音频发往原账户的行为，B会新增百炼音频目的地/ASR权限，C可能改变正式本地引擎或下载模型；产品定稿时说明并选择这些数据与成本变化，再实施。现有Qwen Key只获Qwen-Flash文本模型权限，ASR能力与免费额度分别核对。无需为已批准的普通构建、安装或测试重复请示。

## 5. A的实现接缝：恢复质量、保证预览不拖慢定稿

### 5.1 数据与生命周期

单一麦克风tap同时写原WAV并喂预览引擎。预览文字只用于浮窗，不写外部编辑框，不作为失败时的成功final。F5停止先封口/同步WAV，取消预览解码，不等待Apple末尾final；随即把完整音频交给现有账户ASR。已有AAC上传优化按原完整性规则复用，保留原WAV。预热账户和连接可在录音期间做，预热失败不改录音生命周期。

关键源码必须同时调整：LocalSpeechRecorder不再把预览Task设置成正式localTranscript；AppCoordinator的文件Retry工厂关闭usesLocalSpeechForFiles；ChatGPTTranscriber对A显式走原账户路径。否则Retry或文件入口仍会回到旧Apple捷径。保留openAICompatible显式恢复和原先两条ASR路由，不增加隐式第三fallback。状态归coordinator，预览/识别回调沿session generation隔离，取消网络/预览并阻止晚到粘贴。

### 5.2 术语体系

复用现有词库与校正器；整段normalize→polish→normalize顺序不动。pstack、SmartShadow及用户确认的常用产品名作为显式优先词；ASR提示、润色glossary使用同一会话术语快照，保留各端现有预算。排序按显式重点词→已有使用频次→确定性次序，去重后裁剪；确认两个回归词在有效预算内，避免12315项联系人按原存储顺序占满600字符。

只为本次观测建立有证据的候选alias，例如peacteg→pstack、smar shade→SmartShadow，沿已有术语/替换规则供用户核对；不做任意中文谐音全局替换。候选选择与别名规则要用负例检查，例如普通shadow、真实英文smart shade、代码原文不被强改。声学热词、ASR prompt、转写后规范化、润色相关词表四个阶段分别记录是否进入与效果，写入配置与实际识别生效分别验收。

### 5.3 不完整与错误

正式ASR失败时保留WAV/可重试错误，不把短预览当成功稿。正式ASR成功而润色失败时继续原规范化ASR文本回退，并明确polish错误。400/422去prompt、403 challenge、401凭据刷新均沿已有有界策略；记录promptIncluded true/false，词表被服务器拒收时保留事实。一次成功仅插入一次；无有效编辑焦点用剪贴板，焦点改变不误写。

## 6. B的提速机制与润色尾延迟

A仅恢复质量，不作为“所有目标已完成”。B在润色预算和数据目的地通过决策后，才进入接入实验。其机制是在录音开始时建立正式流式ASR会话、送获准PCM，按session/task/segment ID替换partial，final按时间顺序收齐，不用字符串拼接/去重推定完整性。停止发末包并等待官方完成事件；断线/缺片失败保留原WAV并显示Retry；B首个实验版本只支持用户显式Retry：重建同模型、同地域WebSocket会话，从头回放完整PCM并等待完成事件，不引入另一文件模型/HTTP目的地或后台自动重识别。原请求发生断线后不静默续接旧片段；同段重放的重复计费在选择B时明确。整段润色在全文收齐后恰好一次启动，既有截断重试保留。

当前润色已禁思考并按SSE语义完成及时收束；追加首token、结束事件、尝试次数与阶段时间以定位6–11秒尾部样本。只保留必要匿名计时及引擎/模型/术语计数，词表、原文、凭据不进诊断日志。首token可在现有浮窗显示“正在整理”的真实增量，但在编辑框仍一次插入；若会造成文字跳动或重复阅读，保持原处理态。连接复用、认证预热和终止事件解析先做无语义变化的优化。

保留gpt-5.6-terra作为润色质量基线。新的轻量文本模型须用原prompt、同词表、同正式ASR输入复测；Qwen461ms已有保真失败，继续留作可选。分句提前润色、删全文润色、把预览当最后稿，以及直接换成多模态整理均不进入本轮主方案。

## 7. 评测设计和可观察验收

### 7.1 数据与因果对照

建立20条人工标注音频：8短句（约5–15s）、8中段（约30–60s）、4长段（约120–240s），覆盖同一次真实录音中的中文夹英文、pstack/SmartShadow/EGM/Codex、数字、路径、命令、否定和后文撤回。包含负例和静音/断录/取消。先用公开人工合成素材排协议问题，再优先复用用户本次失败WAV，并以最少3条真实口述补足；素材复用与云发送在所选方案数据边界批准后执行，原音频不删除。

固定同一WAV，R0当前Apple-final＋GPT、A0旧账户完整识别＋GPT、A1独立预览＋同账户正式识别＋GPT以及选定候选分别跑3轮、轮次交错；严格按10.7区分文件质量、1×实时供给组件计时和真实GUI停录到插入统计，注明引擎/模型版本（私有模型未知就记unknown）、prompt是否实际接受、术语快照、输入/输出长度及运行时间。语义质量以人工逐项判定，自动字面量检查单列，错误/失败全部计入，音频准确率用真实音频单独验证。预览体验必须真实麦克风实时回放/口述验证，文件ASR耗时不冒充首字或停录尾延迟。

### 7.2 质量红线与性能目标

质量：对人工标注要求/否定/撤回/专名数字与代码字面量完整保留；pstack/SmartShadow及目标词所有出现位置100%正确；中文CER与英文/术语WER按固定参考分别报告，候选不得劣于同素材A基线。误把普通词改成专名、凭空增加模型/范围/步骤、尾部丢句或重复粘贴均为拒绝默认采纳项。参考文本用口语逐字稿与“允许去口头语的最终意图稿”两份，避免CER和润色质量混在一起。

性能目标为待验证产品验收值：讲话到首个非空预览p50≤1s、p95≤2s；短/中段停录到插入p50≤3s、p95≤6s；长段p50≤5s、p95≤10s；最终候选相对同素材R0的停录中位数至少下降30%，p95不劣于R0，质量同时达到旧账户A0；另报告相对A1桥接的速度差异。仅相对A1变快保留为质量恢复后的效率收益，不记为当前慢问题已解决。20条×3轮对p95的估计范围有限，报告样本量和极值；绝对目标及相对目标分别判定，不用分段首字代替最终完成。超过240s的现有使用、异常停录另外列边界样本，保留实际现有录音能力，不按配置maxDurationSeconds=120新增截断。本机曾实际录到226s，配置与执行差异单独记录。

### 7.3 工程与现场

实现后canonical scripts/check.sh→package/install，全部输出在~/Library/Caches/chat-type与~/Library/Logs/ChatType。单元测试只注入网络/权限/Keychain，不启动GUI。关键覆盖预览与正式来源隔离、Retry仍走同一正式引擎、prompt/术语预算与别名负例、partial替换/final完整性、取消代际、一次粘贴与剪贴板回退。

官方Computer Use在/Applications/ChatType.app验F5开始/停止、实时文本、ESC/关闭取消、Retry、焦点变化/粘贴/剪贴板；记录ASR原文、规范化、润色结果的差异，按需在产品恢复记录可见，不输出到通用诊断。保留底部多行/拖动避让及品牌现状。implemented、checked、packaged、installed、live accepted、left running分别登记；任何阶段单独通过保留其实际范围。最后正常安装版运行。

## 8. 推进与恢复

1. 本轮：完成调研和EGM，交付选定设计及尚需产品定稿的数据流取舍。保持当前安装版。
2. 设计定稿后：先落A与术语接缝，用少量协议素材/真实失败样本确认质量恢复，旧当前本地final候选包保留为可逆恢复物。
3. 先完成下述润色收益预算；预算通过后再做B（北京Paraformer优先、Fun-ASR质量对照）或音频本地要求下C的正式配对。新云ASR凭据/权限及音频目的地在请求前确认；已有文本Qwen Key不直接扩权或复用。
4. 同素材通过质量和速度后才切正式默认；若音频ASR或润色质量不通过，保留A已验收基线。若A的私有账户挑战/不可用，保留录音、沿原错误/Retry，不静默把Apple预览提交成成功。产品决定采用C时再声明正式引擎与恢复策略。

本轮交付范围为研究材料和设计文档；现用运行态保持。

## 9. 来源与复核材料

- [TypeWhisper预览/正式分离](https://github.com/TypeWhisper/typewhisper-mac/blob/2a0ae3e2ec4a627dbc6e90b1a2c9c72757c8d860/TypeWhisper/ViewModels/DictationViewModel.swift#L3038)、[前后词典](https://github.com/TypeWhisper/typewhisper-mac/blob/2a0ae3e2ec4a627dbc6e90b1a2c9c72757c8d860/TypeWhisper/Services/PostProcessingPipeline.swift#L217)
- [Handy流式final与batch](https://github.com/cjpais/Handy/blob/73cc8579cff74e97e08de9d86035a92e4335ff7f/src-tauri/src/managers/transcription/live.rs#L225)、[正式结果后处理](https://github.com/cjpais/Handy/blob/73cc8579cff74e97e08de9d86035a92e4335ff7f/src-tauri/src/actions.rs#L742)
- [VoiceInk流式会话](https://github.com/Beingpax/VoiceInk/blob/4bc74caddfad6fdfab71e5957451b83b33c1a2c5/VoiceInk/Features/Recording/Workflows/TranscriptionSession.swift)、[词汇与AI处理](https://github.com/Beingpax/VoiceInk/blob/4bc74caddfad6fdfab71e5957451b83b33c1a2c5/VoiceInk/Features/Recording/Workflows/TranscriptionPipeline.swift)
- [FunASR两遍与热词协议](https://github.com/modelscope/FunASR/blob/20f26b7c4905d010768ec91206149df2a90104b6/runtime/docs/websocket_protocol.md)
- [接线小妹聊天室流式ASR](https://github.com/AlinaZhang0713/jiexian-xiaomei/blob/1f8c00a6ad6cc85dc606b29d05217e8d895ee187/services/voice-room-agent/src/voice_room_agent/speech.py)、[postprocess](https://github.com/AlinaZhang0713/jiexian-xiaomei/blob/1f8c00a6ad6cc85dc606b29d05217e8d895ee187/services/api/app/services/voice_room_m1.py#L1377)
- [Apple热词能力边界](https://developer.apple.com/forums/thread/811083)
- [OpenAI实时转写](https://developers.openai.com/api/docs/guides/realtime-transcription)、[原生音频与独立ASR事件](https://developers.openai.com/api/reference/resources/realtime/server-events)、[Gemini音频理解](https://ai.google.dev/gemini-api/docs/audio)
- [百炼ASR能力](https://help.aliyun.com/en/model-studio/asr-model)、[Paraformer价格/额度](https://help.aliyun.com/zh/model-studio/model-pricing)、[热词机制](https://help.aliyun.com/zh/model-studio/improve-asr-accuracy)

本机原始研究摘录、按SHA固定的源码和元数据位于~/Library/Logs/ChatType/quality-design-20261110/research。本文不把source读取或文档说明当作本机准确率/速度验收。

## 10. EGM修订后的可实施合同

本节补齐首轮设计critic的1项Major及readiness的4项Major；与前文相同主题冲突时以本节为准。B/C/D保留为有决策门的实验，本节仅把A质量恢复、双基线测量与术语接缝写到实施准备粒度。

### 10.1 先量化整段润色收益预算

当前R0的ASR已在讲话期间完成，正式流式ASR相对R0最多节省约0.1–0.2秒收尾；5–11秒润色需要独立优化。A0负责质量对照，R0负责当前速度对照，A1检验预览额外开销，三者都保留同一全文润色配置。

测量时间点固定为：第一次有效音频、第一条预览、停止收音、WAV封口完成、正式ASR首响应/完成、规范化完成、每次润色请求开始/首内容delta/语义完成、插入完成。polish尝试序号、失败类别和疑似截断重试分别计数。端到端等待从coordinator收到第二次F5停止请求的第一刻到插入完成，含编码、认证、队列、重试等成本。正常与错误/重试分层报告，全部请求仍进入总分母。

先做6条失败/混输素材每侧3轮的小样本，判断：

- 等待主要在首delta之前：复核连接复用/认证刷新/请求排队及地域网络，不通过分句先润色规避。
- 等待主要在输出生成：记录正式ASR后的字数、输出字数与生成速率，比较原ASR轻整理是否减少后续改写负担；不删除内容来换快。
- 多次尝试占比明显：保留完整性保护，定位被触发的具体长度/缺失条件，使用已标注完整/截断样本检查保护器，避免无证据删除重试。

对每条样本按实际关键路径估算预算，首字、ASR完成和整段润色完成分别统计。若保留gpt-5.6-terra时，润色阶段本身已超过p50/p95目标，则B的新增ASR集成先保持实验状态；优先在已有获准文本目的地内寻找保真通过的更快模型，以同prompt、同完整ASR文本配对。新模型权限、费用超出已有授权时按具体动作另行决定。没有已通过的快模型时明确记录“质量恢复已达，尾延迟目标未达”，继续保留已验收质量基线。需要合并ASR/润色、分句润色或省去全文阶段时，作为改变原语义流程的独立产品决定，当前方案保留原流程。

首轮Qwen/GLM及Luna的失败结果继续保留；任何新的候选均重新过完整语义门槛。当前没有证据承诺某条路线已同时解决两项目标。

### 10.2 录音可靠性与预览故障隔离

A的WAV采集是唯一必须成功的链路；Apple preview是可失败的消费者：

| 故障 | 录音/WAV | 浮窗和后续 |
| --- | --- | --- |
| preview locale不可用/准备失败 | 照常初始化麦克风并保存音频 | 显示“录音中，实时预览暂不可用”，F5照常停止并送正式ASR |
| preview格式转换失败/结果流提前结束 | 独立previewError，只停止预览喂入；磁盘转换和写入继续 | 电平和时长继续，已见预览保留为预览，正式ASR使用完整WAV |
| 磁盘转换/写入失败或麦克风实际中断 | 沿录音完整性失败处理，保留可恢复原文件和错误事实 | 明确录音异常，避免提交不完整音频为成功稿；重录/恢复沿现有路径 |
| 取消/第二次F5 | 先结束采集并封口；取消preview Task并阻止晚到回调 | 正式ASR只在非取消且录音完整时启动，取消后不触发网络或粘贴 |

LocalAudioSink分离captureFailure与previewFailure；磁盘写入的guard只受capture状态控制。预览buffer使用自己持有的转换结果/拷贝，tap回调结束后不引用可复用音频内存。预览preparation不放在录音启动的必要条件中；其异步结果沿session generation隔离。preview结果/取消不会清WAV或更改正式ASR结果。

注入测试必须逐一模拟准备失败、转换失败、流提前结束，断言采集帧数/WAV时长持续到F5、账户ASR收到完整封口文件、一次结果交付；模拟磁盘失败则断言错误和文件保留。既有TCC和真实麦克风提示路径保持。

### 10.3 唯一会话词表快照及预算规则

新建轻量RecordingSessionSnapshot值对象，在F5开始、请求麦克风与任何preview准备之前，一次捕获transcriptionConfig、injectionConfig、词库、hintTerms和显式模式。当前Settings更新仅影响下一次录音。正式识别、前后规范化、全文润色消费同一快照；无需新增持久化路由开关。配置的普通值/COW数组可复用，凭据仍由原Keychain边界在请求时读取。

普通错误浮窗Retry沿PendingRetry保留的原快照。History Recovery Retry明确视为“用当前词表重新识别”：用户点击时创建新快照，界面说明该语义，旧恢复记录与原音频保留；不复制12315项词库到每个恢复记录。配对评测使用工具固定的同一快照，Recovery新会话不混入该实验。

本轮用户已明确指认pstack和SmartShadow，方案定稿时将二者写入现有hintTerms（显式重点词），pstack补规范term条目。普通候选顺序固定为：重点词按用户列表次序、其余term按usageCount降序、canonical经en_US_POSIX折叠后升序、原索引升序。仅term进入ASR提示，correction规则仍交给现有规范化器；去重保留优先出现项。

ASR提示的600字符预算沿现有计数：每个trimmed canonical的Swift Character数加词间2字符，header不计；重点词先占预算，其余按上述次序填充。润色glossary沿现有240字符配置，计canonical及“ aliases: ...”整行的Character数，保持现有prefix计数契约；重点词无须先与误识别文本匹配，先进入glossary，普通词继续按当前文本相关性筛选。两端使用同一快照但各有上述预算，两个必需词必须进入有效提示后才通过本轮验收；其他未纳入重点词在设置/评测证据可见，录音入口不新增准入限制。

本轮明确候选alias为用户已指认的peacteg→pstack、smar shade→SmartShadow；先做正例和普通smart shade/shadow/代码字面量负例，随本方案定稿一并确定生效，其他猜测别名继续待用户指认。规范化器保留现有保护规则。语音提示、glossary与aliases分别按“已发送/服务接受/实际纠正”记录，缺少服务证据时不声称热词生效。

### 10.4 A的错误与Retry映射；B实验边界

| 类别 | 自动动作 | UI与显式Retry |
| --- | --- | --- |
| 用户取消 | 取消现有网络/预览，保留原录音政策 | 正常收起；晚到结果不插入 |
| 无信号/录音中断/磁盘失败 | 原完整性策略 | 录音异常/重录入口，保留可恢复文件；不伪装为ASR成功 |
| ASR超时、断线、DNS/离线、5xx、429、2xx空文本/不完整 | A不新增自动网络尝试；429展示提供方等待信息 | 保留WAV和快照，Retryable HUD；每次显式Retry仅一次业务请求，后续仍可由用户发起独立动作 |
| Cloudflare HTML403 challenge | 原初始策略最多3次自动尝试 | 明确challenge，原录音保留；每次显式Retry仅1次，不刷新token规避challenge |
| 401及原有可刷新账户失败 | 沿既有一次刷新逻辑 | 最终仍失败则给登录修复入口，恢复记录保留 |
| 400/422 prompt拒收 | 沿原去prompt重试并记录promptIncluded=false | 两种请求均失败时显示配置/服务错误；修复后由History以新快照重试 |
| 正式ASR成功、润色失败/两次疑似截断 | 原整段保护与规范化ASR回退 | 明确polish失败，交付的文本来源为正式ASR；不启用其他目的地 |

实现将网络可恢复/服务状态归类映射到coordinator现有PendingRetry，而非仅依赖LocalTranscriptionFailure和challenge。权限类403 JSON与HTML challenge分开，实际响应体仅供分类且安全裁剪，不记录凭据/词表。文件Retry仍走A账户正式ASR。

B当前不具备默认发布准备结论。选定provider后，先锁定同模型同地域WS请求、vocabulary_id/授权、原PCM编码、官方最大时长/分包及完成事件；Retry以同WS会话全段PCM重放，采用每次显式动作一次请求、无自动跨模型回退。提供方SDK超时/Retry-After等外部约束逐项落到配置并说明依据，新增限制按项目流程定稿。完成协议失败/缺final/断线/重放费用等小样本后才进入配对；这份实验计划不授予新ASR权限。

### 10.5 A和测量的逐文件实施白名单

| 文件 | 具体动作 |
| --- | --- |
| Sources/ChatType/RecordingSessionSnapshot.swift（新增） | F5与History Retry的不可变值快照、术语优先排序及有效提示选择；不持有凭据 |
| Sources/ChatType/AppCoordinator.swift | 录音开始快照；preview-only recorder；关闭managed文件Retry的Apple捷径；PendingRetry/错误分类映射；使用新会话History Retry说明 |
| Sources/ChatType/LocalSpeechRecorder.swift | 将WAV采集与preview准备/转换/结果分离；preview-only停止不等待final；保留AVAudioEngine单tap和完整性事件 |
| Sources/ChatType/AudioRecorder.swift | RecordedAudio明确预览不填正式localTranscript；保留既有WAV/完整性契约 |
| Sources/ChatType/ChatGPTTranscriber.swift | A明确走原账户请求，文件Retry同源；网络/服务错误安全分类；promptIncluded事实传递 |
| Sources/ChatType/TranscriptionPromptBuilder.swift | 消费快照中已排序、裁剪提示；保留600字符既有边界及正文语义 |
| Sources/ChatType/TextPolisher.swift | 消费同快照，显式重点词保留到glossary；增加每次SSE阶段计时接缝，原prompt、mode及整段顺序保持 |
| Sources/ChatType/PolishResponseTransport.swift | 首内容delta/语义完成和取消计时；维持连接复用和凭据固定域名/拒绝重定向 |
| Sources/ChatType/LatencyRecorder.swift、RecoveryHistory.swift | 必要匿名阶段字段/来源事实及恢复操作语义；旧记录可读；恢复记录为产品本地数据，不把文本/词表写通用诊断 |
| Sources/ChatType/PreferencesWindowController.swift | 标明本地预览＋账户正式识别的数据去向、History用当前词表重新识别；保留品牌与既有主交互 |
| Sources/ChatType/BenchmarkRunner.swift | R0/A0/A1与候选同WAV、同快照、交错顺序；阶段原始记录和失败完整分母 |
| Tests/ChatTypeTests/RecordingSessionSnapshotTests.swift（新增）、StreamingTranscriptTests.swift | 错拼仍含重点词、预算边界、录音中改词库、Retry快照、preview三故障对完整WAV的隔离 |
| Tests/ChatTypeTests/AppCoordinatorCancellationTests.swift、ChatGPTTranscriberTests.swift、TextPolishTests.swift、LatencyRecorderTests.swift | 正式引擎/Retry目的地、错误映射、取消晚到、一次粘贴、首delta与重试计时、旧记录解码 |
| scripts/benchmark_quality.py（新增）、docs/recognition-quality-and-latency-design-2026-11-10.md、docs/operations.md、README中英文、CHANGELOG.md、AGENTS.md项目B0已知状态 | 元数据/质量统计与真实词表快照；同期发布文档明确A经用户定稿后的新行为。脚本只读合成/获准样本和结果，不读取系统凭据 |

当前审查已读的其他模块保持，变更超出白名单时先记录直接依赖与必要性。B/C具体provider源码在选择后补相同粒度白名单，不提前写兼容工厂或新增路由框架。

### 10.6 可恢复的产物与A首阶段验收

实施开始且确认无正在录音后，用ditto复制当前/Applications/ChatType.app到 `~/Library/Caches/chat-type/quality-redesign/R0-installed/ChatType.app`，验证其原签名并保存版本/现行安全配置。配置全量备份仅在产品本地受保护运行目录，凭据仍留Keychain；诊断中仅输出白名单字段。只覆盖本任务创建的同名备份，原音频/旧证据不删。精确版本0.5.1(1)相同，因此收据还要标原构建来源、R0用途与配置，不靠展示版本号区分行为。

R0保持当前Apple-final行为。A0由改动前当前源码中仍保留的原账户ChatGPTTranscriber（usesLocalSpeechForFiles=false、RecordedAudio.localTranscript=nil）＋同一原DictationPipeline重现，无预览；A1仅新增独立预览并走同一正式ASR。工具保存这两个显式实例化策略及源码候选，不用当前配置标签猜引擎。原旧安装包若可核验则另列质量参考，未取得时报告A0为“原账户路径复现”。

A1首验固定6条音频各3次＝18次：pstack/SmartShadow短句、混输/命令/数字、后文撤回、普通shadow/smart shade负例、30–60s多需求、120–240s长段；其参考稿人工确认。A0同素材18次作质量比较，R0同素材18次作现用速度比较。另以注入而非真实外发覆盖preview三故障、403/429/5xx、无信号、取消和焦点变化。两个必需词全出现位置正确、需求/否定/撤回/字面量保留、质量不低于A0；18次均完成且无缺尾/重复插入。这个小样本只批准质量恢复候选；完整20条×3轮才用于最终速度目标和默认采纳。

package/install显式CHATTYPE_DIST_PATH=~/Library/Caches/chat-type/dist、scratch/cache沿现有缓存。部署通过scripts/install_app.sh，LaunchServices启动/Applications/ChatType.app；绝不从dist做真实验收。A1安装后官方Computer Use执行F5/F5、ESC、关闭、Retry、编辑框/无焦点结果并读安全配置，保留正常运行。

需要回到R0时先等待空闲，在未更改现有运行配置的前提下，将备份签名包用ditto复制到本任务缓存的R0-package/ChatType.app，再以CHATTYPE_DIST_PATH指向R0-package运行同一install_app.sh；它负责停止旧进程和原子范围内替换，随后LaunchServices恢复正常运行。若实施中改过配置，只恢复本任务拥有的字段，保留用户期间其他设置和词条；Keychain无迁移/删除。恢复后核签名、R0本地正式来源、F5出字/停止/一次粘贴和正常运行。该操作在设计批准后的实施/故障恢复范围内执行，本轮没有备份、安装或重启。

### 10.7 唯一音频重放与停录时钟协议

EGM定向复核指出：当前BenchmarkRunner在prepare阶段才调用Apple整文件识别，其耗时不能作为现版“边录边算”的停录基线。本次采用以下三个数据集，时间字段和分母各自保留：

1. **文件质量集**：同WAV、同术语快照，A0及候选文件接口只用于ASR/最终文字质量和阶段成本。原现有文件benchmark明确标file-replay，结果不进入30%停录提速结论。
2. **1×实时PCM配对集**：新增可注入AudioFrameSource（麦克风真实来源与文件重放来源共用下游采集/预览接缝）；RealtimeAudioReplaySource用AVAudioFile读取相同WAV，按原采样率的20ms frame与单调时钟绝对计划1×供给，不瞬时送完整文件。R0在第一帧起实际运行SpeechAnalyzer，A0边供给边保存WAV且不启动preview，A1同时保存WAV和运行preview-only；录音结束在最后一帧被接受时发唯一stopRequested，封口/正式识别/全文润色沿各自生产策略。B按获准同协议在帧到达时送WS。记录供给漂移/背压，不通过加速播放降低等待。该模式不打开真实麦克风、不请求TCC、不调用真实粘贴；其时间名为stop_to_ready_ms（至PreparedDictation完成），独立记录预览首字、录音期计算与末尾final。它用于收益预算和组件因果对照，结果保持ready口径。
3. **真实安装版端到端集**：速度采纳门槛只使用此集的stop_to_insert_ms。固定6条源WAV（5–15s两条、30–60s两条、120–240s两条），R0-measured与最终候选各3轮共每侧18次，轮次交错。官方Computer Use打开真实空白可编辑目标，F5开始；用系统afplay以1×声学回放源WAV，经同一扬声器/麦克风实际采集；播放完后官方Computer Use按F5停止并观察一次粘贴。固定并记录音频设备、音量、距离和环境；保存每次实际采集WAV，它们是独立输入证据，声学差异单列，源WAV相同不声称采样字节完全相同。失败/取消/无焦点分支另有现场用例，不混入成功分位数；失败数仍计总分母。再用最少3条用户真实口述做可理解性/术语确认，声音回放不替代自然口述结论。

真实时钟统一使用应用内单调时钟：t_stop_request在coordinator处理第二次F5的第一刻写入；t_capture_closed、t_asr_final、每轮polish首delta/完成、t_prepared、t_paste_dispatched和t_insert_observed分别记录。最终指标=t_insert_observed−t_stop_request，包含停止收音、封口、认证、全部识别/润色/重试/注入。记录音频firstSpeech到首预览的时钟；首token与ready指标不冒充插入完成。时间采样不写文本、词表或凭据。

R0-measured先在A源码变更前建立：以当前正式R0源码及配置，只增加上述匿名计时字段和入口采样，录音/识别/词表/润色/插入分支保持，单元检查与人工音频结果复核后打包归档 `~/Library/Caches/chat-type/quality-redesign/R0-measured/ChatType.app`。原R0-installed仍作无改动恢复包。真实端到端集在R0-measured与候选之间使用canonical install串行切换，绝不同时运行两个处理热键的正常实例；条件相同的冷/热启动分别分层。

阶段A首轮6条×3的R0速度证据来自真实端到端集；A0质量证据来自同WAV文件质量集；A1同时有实时PCM集和真实端到端集。完整20条×3集按同协议扩展，长短层各报n、p50/p95和极值。18次现场分位数仅代表本机小样本；30%改善与p95不退化要求由真实端到端同条件结果判定。窗口点击和MCP调用往返不进入应用计时，但实际应用内部收到F5之后的所有等待都进入指标。

白名单补充：`Sources/ChatType/AudioFrameSource.swift`（新增来源协议及1×文件重放实现）、`Tests/ChatTypeTests/RealtimeAudioReplayTests.swift`（1×计划/顺序/停止唯一性、R0录音期间实际供给与末尾时间边界），`BenchmarkRunner.swift`增加file-quality与realtime-ready明确模式。计时/PCM测试使用可控时钟和输入，不启动GUI/真实麦克风；真实安装版端到端集仅官方Computer Use。现有环境变量benchmark入口只用于实验，不新增用户路由模式或产品后台任务。

### 10.8 目标插入回执及声学停顿配对

最后定向复核发现当前TextInjector在投递Cmd+V后即可返回pasted。最终速度终点固定为本节的目标观察回执；paste返回时间保留为t_paste_dispatched，单列其与真实插入的差值。

**只读插入观察**：真实端到端集固定TextEdit纯文本空白测试文档；由官方Computer Use创建、聚焦，并验证窗口属于本轮测试文档。测量版在发出粘贴前记录目标pid/window/AX元素身份、空白内容/选择区条件；仅对此目标注册公开Apple AXObserver的value-change通知，并在通知时读取AXValue。observer只观察，不驱动点击/按键，不扩大当前已授予的Accessibility权限；真实操作和可见结果仍由官方Computer Use完成。

完整预期文本来自本轮PreparedDictation.finalText。只有目标AXValue等于预期全文（仅统一CRLF/LF，不截短、不做模糊匹配）才在应用同一DispatchTime时钟写入t_insert_observed，保留通知到达/AX读取成本。目标变化、窗口变更、额外用户输入或部分匹配分别标失败。测量配置显式设receipt等待窗口5s，作用为实验失败分类；超窗样本保留并计失败，不把事件已发出标为成功可见插入。剪贴板回退、取消与焦点改变走独立功能用例，实际没有插入的样本只报告copied/失败，不进入成功插入分位数。

测量前用已知短/长纯文本在同一TextEdit目标做6次公开框架写入/粘贴对照，由官方Computer Use确认完整文本；记录t_paste_dispatched到t_insert_observed延迟和偶发超时，确认观察机制可用。该观察延迟进入最终等待指标，R0-measured和候选使用同一实现。原R0记录的injectMs继续保留其事件返回语义，不能混用为实际出现时间。

测量机制限定在显式的installed acceptance启动模式、指定测试目标，正常产品模式保持现有注入行为和隐私范围，不在其他应用后台遍历/读取内容。诊断输出只含时间、目标匹配布尔、长度和状态；预期全文/AXValue只在本次进程内比较。测试结束注销observer、清理内存。白名单补充 `Sources/ChatType/TextInjector.swift` 的只读测量接缝、`Tests/ChatTypeTests/TextInjectionReceiptTests.swift`（新增，用注入的目标/时钟验证全文/部分/目标变更/超时，测试不操纵GUI）以及10.6的R0-measured归档说明；无需新增产品权限或更改生产粘贴策略。

**停顿条件**：真实端到端速度集预先固定“实际采集WAV末尾语音结束到t_stop_request”的窗口500–1500ms，R0-measured与候选同一源WAV的配对停顿差≤250ms。该窗口是实验输入条件，不改变产品VAD、录音时长、hotkey或用户停录行为。基于每次实际采集WAV人工标注/离线对齐的最后语音采样位置，加上采集首帧的同源单调时钟与样本索引，得到speech_end_time；使用实际捕获时长，不只用afplay进程退出时间推定。记录stop_pause_ms、标注方法和不确定度。

源WAV去除多余尾部静音，并在实验清单标出语音末尾；官方Computer Use在播放结束后发F5，通过实际stop_pause_ms核验工具往返产生的停顿。超窗或差值超250ms的轮次保留为unmatched输入，计入总尝试分母并补测；这些轮次不进入配对速度门槛。每条素材须有3组匹配轮次，无法取得时结论为该层速度证据不足，保持当前质量基线而不通过默认提速验收。原音频完整性/转写错误仍作为失败保留，不通过筛停顿去除质量失败。

500–1500ms与250ms是本轮标准回放的显式条件，结果适用范围按该停录习惯报告。3条用户自然口述保留其实际停顿，单列体验结果，不强制改变用户讲话/按键习惯，也不外推标准回放覆盖所有停顿。时钟与样本到时间映射的单元覆盖加入RealtimeAudioReplayTests；实录末尾标注和配对选择由benchmark_quality.py输出，可人工复核。

## 11. EGM结论与当前交付边界

EGM先由fresh-context design critic和implementation readiness两路独立审查；随后仅对实质修订及其直接依赖作定向复核。首轮5项、实时供给1项、最终插入/停顿2项实质缺口已分别形成明确合同并复核闭合；最后定向复核剩余Blocker/Major/Nit为0/0/0，前次已闭合范围沿用。评审者均实读所需persona/standard及直接源码，未检索个人memory/旧chat，未操作GUI或运行态。

这份结论覆盖设计可实施性和产品讨论准备；音频质量/速度、观察器校准与真实用户验收将在方案定稿后的实现中建立。A涉及恢复完整录音发送至现有chatgpt.com账户主机；B涉及新的百炼ASR音频权限和计费。当前音频本地识别、ChatGPT全文润色配置保持，未发出新ASR请求。
