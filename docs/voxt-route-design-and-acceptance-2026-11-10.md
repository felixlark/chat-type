# 吸收 Voxt 技术路线：ChatType 设计与验收

日期：2026-11-10。文档编号 CT-VOXT-20261110，候选 v3。范围：技术调查、GSE 方案和验收标准。产品负责人：Longbiao；本 chat 维护方案。实施、模型下载、安装和默认路径切换待单独批准。

## 1. 建议与目标

推荐保留 ChatType 的 Swift/AppKit 产品，评估接入 SGLang-Omni 的本地语音运行时，以 Qwen3-ASR 1.7B 8bit 为质量候选；录音期间按停顿完成正式分段识别，停录后识别尾段，拼成完整转写，再沿用当前术语处理、ChatGPT 全文润色、保护与一次插入。0.6B 4bit 作为同场轻量对照；最终模型由质量与实际等待共同决定。

GSE（生成式软件工程）在本案覆盖需求、源码调查、架构、独立评审、分阶段验证和安装版验收。ASR 指把语音转换为文字；MLX 是 Apple Silicon 上执行模型计算的框架；VAD 是识别语音与停顿的检测器。SGLang-Omni 团队发布的 Voxt 使用原生 C++/MLX 运行时，Voxt 2 的界面与调度代码使用 Go/MyGo；ChatType 直接复用运行时和算法思想。

用户可观察目标：中文、英文、姓名与工程词识别准确；长段讲话持续显示预览；F5 停录后的总等待缩短；改口、否定、限制条件和字面量完整；失败后录音和可恢复进度保留。

本轮产出为可评审方案。本文所有性能阈值均为建议验收目标，数值待实际测量判定。

## 2. 已核实来源与当前基线

### 2.1 上游来源

原帖作者 @GenAI_is_real 于 2026-11-10 发布 Voxt，其同线程回复给出源码及 2.0.3 下载。本案固定 `voxt-v2.0.3` 标签研究，实施时解析并记录实际 commit SHA，禁止直接随 main 漂移。

| 证据 | 核实内容 |
| --- | --- |
| [原帖](https://x.com/GenAI_is_real/status/2119974696079004067)、[作者后续链接](https://x.com/GenAI_is_real/status/2119976602914492870) | 项目身份与发布入口 |
| [版本 README](https://github.com/sgl-project/sglang-omni/blob/voxt-v2.0.3/Voxt/README.md)、[架构](https://github.com/sgl-project/sglang-omni/blob/voxt-v2.0.3/Voxt/docs/architecture.md) | 本地语音、独立文本润色、录音恢复；Swift 到 Go 是 Voxt 的产品重写 |
| [pieces.go](https://github.com/sgl-project/sglang-omni/blob/voxt-v2.0.3/Voxt/internal/omni/pieces.go)、[live.go](https://github.com/sgl-project/sglang-omni/blob/voxt-v2.0.3/Voxt/internal/omni/live.go) | 后台正式分段、预览故障隔离、停录收尾及完成事件 |
| [models.go](https://github.com/sgl-project/sglang-omni/blob/voxt-v2.0.3/Voxt/internal/omni/models.go)、[模型清单](https://github.com/sgl-project/sglang-omni/blob/voxt-v2.0.3/Voxt/internal/models/catalog.go) | 模型 revision、逐文件校验、参数与轻重模型差异 |
| [上游评测](https://github.com/sgl-project/sglang-omni/blob/voxt-v2.0.3/Voxt/docs/eval.md#long-recordings-on-the-speech-model-10-17-testevallongasr) | M4/24GB，286 秒音频：同一组较低内存压力试验中，识别收尾从 32.3 秒到 2.6 秒；原始样本、共享模型/内存压力均列明 |
| [final.go](https://github.com/sgl-project/sglang-omni/blob/voxt-v2.0.3/Voxt/internal/omni/final.go)、[echo.go](https://github.com/sgl-project/sglang-omni/blob/voxt-v2.0.3/Voxt/internal/omni/echo.go)、[构建脚本](https://github.com/sgl-project/sglang-omni/blob/voxt-v2.0.3/Voxt/scripts/build-omni.sh) | 回环传输、词表回声处理、原生运行时打包 |
| [NOTICE](https://github.com/sgl-project/sglang-omni/blob/voxt-v2.0.3/Voxt/NOTICE)、[LICENSE](https://github.com/sgl-project/sglang-omni/blob/voxt-v2.0.3/Voxt/LICENSE) | SGLang-Omni/ActNow、Auralink/AudioSmith 来源，代码 Apache-2.0；运行库与模型各有许可证 |

上游“92%”的终点为正式 ASR 完成。ChatType 的采纳指标终点为目标编辑框出现全文。模型润色和插入耗时均进入本案总等待。

上游还有语音翻译、多轮改写、按应用增强、自动学词、DFlash（小模型先提出候选词、主模型验证的推测解码）。本案首批聚焦输入质量和等待；后续能力独立立项。首批复用现有词库及人工维护方式。

### 2.2 ChatType 当前事实

- 源码基线：本 checkout HEAD `faa5918` 加现有大量未提交改动；各文件已有 writer 的工作保留。本轮新增本设计和评审记录，产品源码保持原状态。
- 直接读取安装包 Info.plist：`/Applications/ChatType.app` 为 **0.5.1（110）**，ChatType 进程存在。此项覆盖版本和进程；本轮真实 F5 业务验收列为未执行。
- 当前电脑：Apple M1 Max / 64GB，系统报告 macOS 27.2（26B123）。实施前再次核对硬件、系统、签名和运行环境；结果限定在实际测试设备。
- `AppCoordinator` 在 macOS 26+ 的 managed 路径使用 `LocalSpeechRecorder` 做 Apple 实时预览，生产 `ChatGPTTranscriber` 设置 `usesLocalSpeechForFiles=false`；停录后完整 WAV 交原 ChatGPT 账户正式识别。`DictationPipeline` 继续全文术语 → 全文润色 → 术语保护/排版。
- [110 交付记录](polish-cache-a-delivery-2026-11-10.md)记录词库缓存优化和姓名/“只”等范围词误识，以及部分原始日志当前不可读。文档统计用作选题依据；本案重新采集可读取的对照证据。当前 gpt-5.6-terra 是记录中的全文润色模型，实施前只读核对安全配置字段。
- [Stage A](quality-restore-stage-a-2026-11-10.md)是现行质量恢复决定。现有产品两条转写路线为 `chatGPTManagedAuth` 和用户选择的 `openAICompatible`。本方案提出的本地正式 ASR 是新的产品路线，需负责人批准后更改该合同。

## 3. 关键取舍

| 路径 | 质量/延迟/数据特征 | 本案安排 |
| --- | --- | --- |
| 当前 110：Apple 预览 + ChatGPT 完整音频 ASR + 原全文润色 | 维持现有产品合同；音频、文本分别沿既有账户请求离机；已知姓名与约束词缺口 | 运行与质量对照、恢复路径 |
| 本地 Qwen3-ASR 1.7B 8bit + 后台正式分段 + 原全文润色 | 新增约 2.5GB 权重下载、本机模型计算；音频本地，整段文本仍发当前 ChatGPT 润色；质量和本机速度待测 | 推荐质量候选 |
| 本地 Qwen3-ASR 0.6B 4bit + 相同流程 | 权重约 713MB；上游测试更快且部分混输/词汇准确率较低 | 同场质量/资源对照，通过同一门槛才供选择 |

保持既有全文润色模型、提示与词库内容，首先分离 ASR 路线的贡献。上游分块润色和本地语言模型分别改变上下文与质量，后续有证据再评估。首批模型列表收敛到上述两项及 Silero VAD，避免模型平台化。

## 4. 数据流、接口与状态

### 4.1 一条录音、三个消费者

F5 → 固定本次配置/词库/模型快照 → 立即采集原始音频并持续保存 WAV → 同源 PCM（未压缩音频帧）送预览和后台正式分段 → F5 封口 → 等待在途分段并识别剩余尾段 → 按采样区间顺序组装正式全文 → 现有 DictationPipeline 后处理 → 一次插入/剪贴板 → History。

保留单一麦克风 owner，采集/落盘独立于模型准备。启动模型同时保存音频，模型就绪后按采样偏移补送录音起点至当前位置；补送和实时尾部共享顺序 cursor，保证首字与中间帧完整。采集回调只完成有界内存交接/现有落盘工作，推理和网络移到后台；推理落后时从已保存音频追赶。原 WAV 保持当前录制格式；单一有状态转换器形成供 Omni 使用的 16kHz mono PCM16 流，停录 flush 后固定 canonicalEndFrame。下文 ledger 区间均采用该流的采样坐标，另存原 WAV 采样率/帧数和映射，避免24kHz录制与16kHz模型的偏移混用。

当前 `RecordingControlling.stopRecording()` 同步返回录音，继续负责迅速停止收音/封口；异步正式识别由 session 持有并通过 transcriber 等待。新增专用本地会话结果句柄，明确 preview 与 authoritative transcript（正式结果）类型。`RecordedAudio.localTranscript` 的旧 Apple 文件实验保持隔离，生产本地路由使用专用句柄，避免意外恢复旧捷径。

`OmniRuntimeSupervisor` 管理受签名保护的进程与模型 lease（使用权）；`OmniTranscriber` 提供文件重试与实时会话收尾；`IncrementalASRSession` 管理 frame cursor、preview revision、piece ledger（分段账本）和最终结果；`DictationPipeline` 保持通用 ASR 接缝及全文处理；`AppCoordinator` 持有 sessionID、取消与一次交付权。

### 4.2 分段及全文语义

- 每段记录 `sessionID / pieceIndex / startFrame / endFrame / modelRevision / text / outcome`。正式覆盖区间采用左闭右开，连续、无重叠；只在正式结果成功后推进 committed cursor。预览可覆盖更新，保持独立版本号和显示位置。
- 以 VAD 停顿作为优先切点，连续语音用安静窗口切分。上游起点：总录音过 60s 开始后台定稿；未处理区达到 30s 后，在 20–45s 区间找 ≥300ms 停顿，45s 达到时按最安静 100ms 切分。60s 是上游的策略起点，ChatType 将其作为显式实验参数比较首段更早定稿的收益。
- 每个区间正式识别一次并缓存成功结果。F5 封口后等待正在识别的段，再处理未覆盖尾部。终态要求 `committedEndFrame == capturedEndFrame`；静音区间可用显式 empty/silence 状态覆盖。错误/取消保留录音和 ledger，禁止把部分覆盖标成功。
- 组装依赖音频区间，重复口述仍保留；中英文接缝沿现有排版处理。切点发生在词中、数字中或拼写中的用例是质量门槛。跨段的“刚才 A 撤回，改成 B”交完整全文润色处理。覆盖终点的 capturedEndFrame 指上述转换器 flush 后的 canonicalEndFrame；原音频帧数独立保存。
- 首批保持当前重点词优先及相关词召回，复用 VocabularyIndex；避免把 17674 项整本词库作为模型上下文。模型上下文使用独立预算，实验比较当前重点词+相关词与上游策略；0.6B 上游使用 30 词、1.7B 使用最多 500 词/8000 字符，均标记为来源参数。静音/弱音加大词表时检查回声，疑似词表回声使用同区间无提示重识别核对，记录实际增加耗时。
- 主语言采用用户明确设置，中文使用 `zh` 并保留原语言混输；界面语言与语音语言分别存储。旧配置无主语言时沿当前中文预览基线建议中文，首次启用本地模型页明确展示，验收覆盖英文 UI 下的中文与英中切换。

### 4.3 失败与恢复

恢复数据采用**一份录音、多次识别 run**的合同。`recordingID` 固定标识 `Recovery/Audio/<recordingID>.wav`；原有 RecoveryRecord.id 可作为旧录音的 recordingID。每次新识别建立 runID，原始录音的第一次识别与 History Retry 分别建立新 run；普通 Retry 保持 runID。sessionID 是当前执行与插入权的进程内身份，每次 Retry 可重新生成。

新增受保护 `Recovery/Runs/<runID>.json`，权限0600、目录0700；schemaVersion=1，保存 recordingID、runID、parentRunID、开始时间、原音频/16kHz坐标与转换参数、路由与runtime/model revision、配置/词库快照引用、分段ledger、raw/final文本、状态和指标。快照在 `Recovery/RunSnapshots/<runID>/` 按独立文件保存，属于恢复数据；token/API key 留在Keychain，日志保持脱敏。每次普通 Retry 复用同一快照，History Retry 按当前设置建立新快照与parentRunID。

分段提交顺序：确认对应 WAV 已落盘并同步 → 得到完整识别结果 → 将新增段、text和连续cursor一起原子写入run journal并同步 → 发布内存进度。进程在提交前退出时，该未确认区间可再次识别；提交后重启则复用已持久化区间。加载时检查音频帧数、转换参数、模型revision和快照引用一致，截断/缺失时保留材料并提示从完整音频新建run。整段成功后保存最终结果及覆盖状态，随后才获得当前session的一次交付权。

旧 Records 和 WAV 保持可读取；缺少 run 字段的旧记录按已有ID映射为只读 legacy run。首次 History Retry 创建新 run journal，保留旧记录原文与结果。历史列表适配为按 run 展示并关联原 recordingID，音频共享同一原 WAV；每条可查看其结果、时间及来源模型。新增 `RecoveryStore.recordRun` 接口按runID更新本run，当前按WAV文件名复用ID的 `record` 接口仅继续服务录音/旧格式路径。升级阶段采用惰性读取适配，原记录与模型文件均保留；回退旧安装版前恢复本任务拥有的配置route/model字段，新 Runs 目录保留供新版本继续读取。

**重启后的同run入口**：正常启动在现有 `recoverInterruptedRecordings` 完成WAV修复后扫描Runs，将非终态识别记为interrupted；菜单栏仅显示可恢复数量，History对应行提供“继续本次识别”和“按当前设置重新识别”两个动作。启动阶段等待用户选择，麦克风/推理/网络/插入均由用户动作启动。前者沿原runID、持久化快照和已提交cursor继续，创建新sessionID并在用户触发时重新取得当前编辑目标；本次识别只处理已经保存的录音。后者沿History Retry合同建立新run与当前快照。旧legacy记录只显示新run重识别入口。

继续时检查原模型与快照可用，显示准确缺失项并保留原run；用户可选择新run改模型。finalizing/识别错误从未覆盖区间继续，polishing阶段已有完整正式ASR时复用该全文。cancelled/done为终态，保留查看与新run动作；delivering时退出、且投递结果未知的run显示“交付状态待核对”，只提供查看/复制已保存全文并要求用户显式操作，避免自动重放旧交付。新session只向本次重新取得的可编辑目标交付一次，无编辑目标按原剪贴板合同。

| 情况 | 可观察处理 |
| --- | --- |
| 预览失败/断线/落后 | 保留已显示文字、标记预览状态，继续保存录音与正式分段 |
| 模型缺失/损坏/准备失败 | 本地路线显示具体原因和恢复入口；保持录音或在开始前明确提示，已保存材料可重试 |
| 正式分段失败、运行时死亡 | 保存已成功 ledger 和完整录音；停止推进失败区间，终态为可重试错误；Retry 在同一本地路线恢复失败/未覆盖区间 |
| Retry 时模型或词库设置改变 | 普通 Retry 沿用录音开始快照及成功分段；History Retry 按当前设置从完整文件重新识别，记录新 runID 并保留原记录 |
| ESC、inline close、处理期间取消 | sessionID 失效，停止采集/后续请求、保留已有恢复材料；晚到结果失去插入权；随后 F5 可开始新会话 |
| 润色失败/截断 | 沿现有保护逻辑保留规范化的正式 ASR 全文和提示；该次计为 polish fallback，单列质量与速度 |
| 本地模型故障后改用云 | 由用户显式选择现有 ChatGPT 路线并确认该段音频上传，记录实际目的地；自动流程留在本地 |
| 磁盘失败/音频中断 | 现有录音错误路径停止采集并保留可读取材料，明确显示覆盖缺口 |

状态主线：idle → recording（模型加载/预览/分段为内部进度）→ finalizing → polishing → delivering → done。每步可进入 cancelled 或 retryableError；每个 run 至多一次最终交付。沿用原 403 challenge、429、登录过期等错误分类，ChatGPT 原有三次自动/一次手动 challenge 策略保持。

## 5. 本地运行时、费用与产品授权

推荐首批以受监督的原生进程接入，复用 Voxt 已验证的回环 HTTP/WebSocket 协议；Swift 内进程绑定可在后续以崩溃隔离和打包成本实证比较。运行包内包含 `qwen3_asr_server`、Silero 所需二进制、MLX 动态库与 Metal 资源；应用安装后运行阶段使用原生文件。构建时上游 Python/uv/CMake/Ninja 依赖进入 Caches，与最终用户运行依赖分别记录。

| 项目 | 方案合同 |
| --- | --- |
| 转写路由 | 提议新增显式 `localOmni`，形成“现有两条 + 新本地”三条选择。仅在该产品变更获批后实施；安装升级维持用户原选择，默认切换另由验收与负责人决定 |
| 凭据/费用 | 本地 ASR 使用公开模型，增加下载流量、磁盘、内存和能耗；继续使用现有账户全文润色，其订阅额度/服务限制继续适用。下载凭据保持现有受支持存储；Cloud ASR/新云润色采购另案 |
| 下载数据 | 用户主动下载时向批准的模型源发送模型文件请求、IP 与常规传输元数据；音频、转写、词库均留在本地下载器之外。Hugging Face 与实际重定向/CDN 域名在实施前列成精确名单，经负责人批准。首批指定单一源，错误时明确提示来源问题 |
| 固定模型 | 1.7B：`mlx-community/Qwen3-ASR-1.7B-8bit@a8379a2e2f9e313c9292cdf1af4055ab56d50d55`；0.6B：`mlx-community/Qwen3-ASR-0.6B-4bit@313d850181767edf09f00a9c289becca70e58cd0`；Silero：`mlx-community/silero-vad-v6@2ebf4a5e10726a2e78ddd4d70eedfb6f1c33eb06`。逐文件 manifest 校验决定能否激活，断点续传写 `.partial`，完整验证后原子发布 |
| 数据目的地 | 本地 ASR 只到 `127.0.0.1` 随机端口；生产会话只接受自有签名 child 的 ready 端口并禁重定向、禁代理。ChatGPT OAuth header 固定在原官方主机 transport；本地连接与下载器均使用全新无凭据会话。全文润色仍将文本/相关术语发送既有 ChatGPT 端点，产品文案明确此范围 |
| 访问范围 | 本地 listener 仅回环，客户端验证自有child的host/port/PID；HTTP及WS使用每个child独立的临时随机secret，存内存、经继承管道交付，服务端验证请求，退出即作废。上游运行时适配该鉴权入口纳入P1并测试，端口可达性与会话鉴权分别验收。远端监听/额外系统权限均另行批准 |
| 进程生命周期 | 懒加载与录音重叠；父进程退出释放子进程；取消会话释放 lease；切模型等待当前使用结束。原录音 owner 和热键 owner 各一个。空闲卸载参数建议先测上游 10min；保持显式配置 |
| 资源参数 | 上游 512MiB MLX cache、60s 文件 chunk 为显式实验配置，依据见 eval；记录峰值 footprint、内存压力、swap 和预览间隔。产品新限制在 PR 单列位置、默认值、依据，由负责人定稿；首次读实际硬件后测定启用值 |
| 分发 | 保留 ChatType 原签名、bundle identity、图标/颜色/菜单栏渲染、F5/F5。逐层签名原生库和 helper，再签 app，安装版验证动态库/Metal 资源。导入代码保留许可证、NOTICE 和修改标识，模型许可证及下载分发条件逐项确认 |

模型卡只读核验补充：[1.7B](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit/blob/main/README.md)、[0.6B](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-4bit/blob/main/README.md)标注Apache-2.0；[Silero v6](https://huggingface.co/mlx-community/silero-vad-v6/blob/main/README.md)标注MIT，权重约1.2MB。实施核验以所固定revision及随包许可证为准，当前模型卡与固定版本分别记录。

首批可实施批准应明确：第三条本地正式路线及 UI 选择、上述模型与下载主机、回环服务、存储和文案。默认路径迁移及品牌视觉调整分别判断。本轮调用限原帖/公开源码读取与本地只读取证，未下载模型、调用付费转写或更改权限。

## 6. 最小交付批次与文件边界

| 批次 | 交付物与主要路径 | 退出条件 |
| --- | --- | --- |
| P0：固定对照与接缝 | `scripts/doctor.sh`；记录当前安装包/安全配置/源码候选；复用现有 `BenchmarkRunner.swift`、`ProcessingTiming.swift`、`LatencyRecorder.swift`，增加必要 stop/insert 观察点与 1× PCM 重放接缝 | R110 原行为、关键质量缺口、可读取基线、恢复包齐备；计时验收校准完成 |
| P1：本地引擎质量试验 | 新增 `OmniRuntimeSupervisor.swift`、`OmniTranscriber.swift`、模型 manifest/本地模型存储；原生构建及回环HTTP/WS鉴权适配；文件级接口与独立测试 | 审核后的模型/许可证/主机可用，1.7B 与 0.6B 完成同集原 ASR/最终全文质量对照，进程/资源可回收，跨child/无凭据连接被拒绝 |
| P2：录音期间正式分段 | `LocalSpeechRecorder.swift` 提取共用采集/PCM 接缝；新增 `IncrementalASRSession.swift`；`AudioRecorder.swift` 专用结果句柄；`AppCoordinator.swift` / `DictationPipeline.swift` / `RecoveryHistory.swift` 接入快照、ledger、Retry；Settings History加入两种恢复动作 | 生产同一路径1×重放24×3并通过7.1全部质量门槛；覆盖全帧/尾段/取消，旧格式读取、同run重试、History新run保留原结果、进程重启后通过明确入口复用已提交段通过；原 managed/compatible 路径定向回归 |
| P3：显式选择及真实验收 | `AppConfig.swift`、`PreferencesWindowController.swift`、preflight/CLI/history route consumers；`scripts/package_app.sh`、`scripts/check_packaged_app.sh` 与 install；更新 README 中英文、架构、operations、release/CHANGELOG 及 AGENTS 的获批产品合同 | canonical checks、打包/安装/真实 F5 矩阵及质量/速度门槛全部有候选绑定证据；保留正常运行 |

逐批在规范 checkout 串行写入，编辑前核 git status 与有关文件 writer。若同一文件有活跃 writer，通过既有协调入口确定拥有的增量。保持现有合法改动。首批增加协议仅覆盖生产真实边界；fakes 注入模型、时钟、麦克风、网络、Keychain 和 AX（系统辅助功能）边界。

P0 前保留当前已签名 `/Applications/ChatType.app` 恢复包至 `~/Library/Caches/chat-type/voxt-evaluation/R110-installed/ChatType.app`，记录签名、版本、来源候选及本次拥有的配置字段。若 110 原包已被其他 writer 更新，重新固定实际在用基线并改名。恢复包复用 `CHATTYPE_DIST_PATH` 指向的 canonical install 路径；等待空闲后替换，再经 LaunchServices 启动正式路径，验证一次真实 F5 及正常运行。恢复仅修改本任务拥有的 route/model 字段，词条/历史和 Keychain 保留。

缓存/构建在 `~/Library/Caches/chat-type/voxt-evaluation/`，模型在 `~/Library/Application Support/ChatType/Models/`，恢复 ledger/录音沿现有 Recovery，脱敏报告在 `~/Library/Logs/ChatType/voxt-evaluation/`。本设计文档在 docs；源码研究快照在本次 `~/Library/Logs/ChatType/voxt-design-20261110/sources/`。

## 7. 验收标准

### 7.1 固定样本与质量门槛

按2026-11-11用户再次明确指示，主集改为 **24 条完整历史录音**，每模型/基线各重复 3 次：8条5–15s、10条30–60s、6条长录音（五条120–300s、一条343.901s）。当前历史只有六条完整长录音，全部纳入，替代旧8/8/8定额；不以拼接或合成音频补数。公开英文朗读/朗读拼接仅作独立补充。选样、参考核准和覆盖规则见[历史录音主评测](voxt-history-validation-2026-11-11.md)。至少核对中文、英文、英中切换、三个人名正例、pstack/SmartShadow/OpenClaw、普通 smart shade/诊断等负例、数字/日期改口、末尾否定/撤回、代码路径/URL、连续无停顿、弱音/静音及长段多需求。缺项保持可见并按规定补测，主24条外的补充覆盖单列，保留原主集分母；参考稿和必保字段在正式计分前核对冻结。

文件质量集在同一当前稳定候选中对照原账户 ASR、1.7B、0.6B；文本润色统一当前获批模型、语言目标、词库快照及配置。R110结果保留历史身份；涉及基线的质量/速度门槛以当前同配置原账户对照判定。候选顺序按文件交错，保留全部失败与输出。自然口述和公开朗读、raw ASR 和最终文本分别统计。词库内容只在受保护运行目录用于测试，报告用样本 ID/汇总。

P1文件结果用于模型筛选。P2最终候选须通过**生产同一路径的1×实时PCM供给**重跑完整24条×3，预览、VAD、后台正式分段、全文润色同时按实际策略运行，并满足下表全部质量指标；R110按相同供给模式建立对照。固定样本中明确指定姓名/数字附近切点、跨切点的否定和后文撤回，保存实际切点。P3绑定该候选及实际runtime/model revision，影响识别的参数变化使相关质量证据重新采集；六条安装版声学速度集继续用于真实交互与实际等待。

| 指标 | 通过标准 |
| --- | --- |
| 中文字符错误率 CER / 英文词错误率 WER | 最终文本整体不高于 R110，同一语言/时长层恶化 ≤1 个百分点；同时报告 raw ASR，避免润色掩盖识别变化。样本数及删除/替换/插入分开 |
| 重点词与姓名 | 每次预期出现的位置全部正确，正例 100%；各负例保持原意，误替换 0。姓名以实际读出的参考稿为准 |
| 语义与范围 | “只/先/暂缓/保留”、否定、数字、日期、跨段改口与撤回最终 100% 符合参考；新增事实、遗漏必要需求各 0 |
| 完整性 | 24×3 所有已保存音频均有覆盖完整的最终结果或明确失败；成功样本缺尾、接缝丢词、重复段各 0；任何缺陷保留在总分母 |
| 文本安全 | 代码、路径、URL、邮箱及既有中英数字排版通过当前合同；普通短语保留；同一结果最多插入一次 |
| 降级 | 每个 polish fallback 显式计数；质量验收分别报告 ASR-only 与完整润色，主速度结论使用完整流程，并公开 fallback 率 |

关键语义/完整性任一失败，继续修复和定向重测受影响范围；保持当前默认路线。轻量候选独立通过相同质量门槛后才可推荐。

### 7.2 性能：三种时钟分别报告

1. **文件识别/就绪**：同 WAV 文件接口测质量及阶段成本，标为 file-replay；完整文件瞬时供给的时间保持该口径。
2. **1× PCM 重放**：同一 WAV 按原采样率实时供给同一生产下游。记录首语音、首预览、正式分段、封口、ASR 完成、全文 ready，以及供给漂移。预览与定稿同时实际计算。stop_to_ready 包含在途分段/排队/尾段/全部润色。
3. **真实安装版**：复用已有设计 [10.7–10.8](recognition-quality-and-latency-design-2026-11-10.md)的单调时钟和完整插入回执合同。通过官方 Computer Use 聚焦 TextEdit 纯文本测试目标，F5 开始，1× 声学回放，F5 停录；应用 `t_stop_request` 从 coordinator 收到第二次 F5 的第一刻采样，终点为同一目标完整全文被观察到。观察只用公开 AX 框架、仅显式测试目标，正文仅进程内比较，日志只存时间/长度/布尔。测量前6次短/长文本校准，观察开销进入两侧指标。

真实速度集从冻结样本取每层 2 条，共6条；R110 与最终质量候选每条3轮＝每侧18次，A/B 与 B/A 交错，分别安装、单实例运行。冷启动每层至少1条×3次，独立报告；暖态集各有3组有效配对。固定设备/音量/距离/网络及词库/润色模型，保留每次实际采集 WAV；停顿条件沿原合同500–1500ms、配对差≤250ms，超窗仍计总尝试且保留原因，补齐有效配对。另做至少3条自然真人口述，分别报告实际停顿与体验。

| 性能项 | 建议采纳门槛 |
| --- | --- |
| 首预览（首语音至首字） | 暖态每层 p95 ≤1s；冷启动单列；静音样本独立 |
| 长录音停录至 ASR 完成 | 120–300s 层暖态 p50 ≤3s，完整算入在途请求与尾段；分段故障回退单列 |
| 停录至真实全文出现 | 6条真实集整体暖态 p50 较 R110 改善 ≥30%，各层 p95 ≤各自 R110；长层目标 p50 ≤5s、样本 p95 ≤10s |
| 质量耦合 | 性能通过同时满足7.1；通过减少润色、遗漏文本或忽略失败获得的时间保持为独立实验 |
| 资源/稳定性 | 一次连续30min录音/重入演练，已录音频可恢复；20次启动/取消/切换后自有会话与lease归零、子进程可退出；记录 footprint、swap、thermal 和最长预览空窗，与同配置初始稳定平台比较末5轮无持续增长趋势 |

统计使用 nearest-rank 样本分位数，列明 n、全部失败、p50/p95、极值与适用设备；18次属于本机小样本证据。云润色若成为主要等待，沿相同模型先拆分首正文/完成耗时，再单独提出优化决定。DFlash 后续可在同一模型/样本测量，额外权重、下载域名和实际收益另行评审。

### 7.3 确定性与真实用户旅程

- 单元/进程内集成：采样覆盖首尾及切点、转换器尾帧flush、24k→16k及原采样索引映射、准备期间补送、预览故障、静音回声、超预算/截断、同一完成事件、重复停止、取消晚到、进程崩溃、ledger 恢复和配置快照；fakes 覆盖系统与网络，真实权限提示独立验收。恢复明确断言旧格式读取、普通Retry同run与快照、History新run保留旧结果、重启复用已提交分段；回环协议覆盖无secret/跨child/旧secret拒绝及HTTP/WS正常会话。
- 故障注入：在分段请求前/中/提交后分别取消或令 runtime 退出；读回完整 WAV、已确认 ledger 和后续 Retry 的最终全文。失败段以连续覆盖 cursor 恢复，成功段复用；改模型的 History Retry 从原 WAV 开新 run。断网时本地 ASR 可完成，远端润色按既有 fallback 提示。
- 重启恢复：进程内集成用受控父进程覆盖“首段提交→退出→重新启动→继续本次识别”，首段ASR调用次数保持1、尾段完成、沿原run/快照并在当前目标交付一次。安装版再通过官方Computer Use实际走History两种动作，核对重启时保持待选、继续后当前目标一次全文、另一动作创建新run并保留旧结果。投递结果未知的中断覆盖独立用例，启动后只展示保存全文，等待显式复制动作。
- 安装版：冷启动菜单栏、Settings、无 Dock 主窗口、Cmd+Q/重新启动、登录持续与 device-code UX；真实编辑目标 F5/F5、ESC、inline close、取消后重入、错误后 Retry、History Retry；检查 editable 的一次插入及无焦点剪贴板回退。验证本地路线音频网络出站为0，文本仅到已选润色主机；当前两条路线各完成一次定向回归。
- 权限/品牌：正式安装路径 LaunchServices 启动；`.notDetermined` 用独立首次权限用例，真实系统授权由用户完成。现有图标/颜色/布局合同保留并做安装版前后比较；模型选择页沿当前 Settings 组件。涉及新增视觉设计再由负责人定稿。
- 发布链：`scripts/check.sh` → `scripts/package_app.sh` → `scripts/install_app.sh` → `scripts/check_packaged_app.sh` → 受影响真实交互；显式 Caches 输出与scratch路径，一次一个 release build。浮窗状态改变时运行 canonical visual acceptance。最终通过 LaunchServices 恢复正常 `/Applications/ChatType.app`，Settings 本地模型页可供复核，保留运行。

每条证据绑定源码候选、安装包签名/版本、模型 revision、配置快照标识、机器/音频设备和日期；报告分别列 implemented / checked / packaged / installed / live accepted / left running。缺少的实际门槛保持待验收。

## 8. 本轮交付与后续决定

当前完成公开源调查、当前版本只读核对和本设计；两路独立初审及必要定向复核完成，三项实质缺口已修订并复核关闭，当前重要开放发现0，详见 [评审记录](reviews/voxt-route-design-2026-11-10.md)。本轮收尾确认正式安装路径的110进程运行，模型试验与产品变更待实施批准。

建议产品决定为：批准上述本地 ASR 实验及所需模型/精确下载主机后，先完成 P0/P1 的质量判别，质量通过后进入 P2/P3；默认路线在真实验收通过后定稿。下载主机和许可证清单属于 P1 前置产物，发现新增成本/目的地时提交具体差异。
