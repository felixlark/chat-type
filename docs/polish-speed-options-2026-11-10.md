# 润色加速：实测热点、候选与验收方案

2026-11-10；研究与EGM评审。研究阶段保持0.5.1(109)运行。Longbiao随后批准实施A、保持当前模型/术语/整段润色流程；实际交付与对比见[110实施记录](polish-cache-a-delivery-2026-11-10.md)。主Agent负责集成和验收；产品取舍由Longbiao决定。

## 建议

先实施A：同一ChatGPT模型、同一提示与词库匹配结果，消除每次请求的本地重复排序和字符串加工，再比较B的新代际模型。A收益先测，B需单独批准模型/凭据权限与小额费用。保留本地实时预览→原账户完整音频ASR→术语对齐→整段润色→术语保护/中英数字间空格→一次粘贴。

## 当前证据与瓶颈

- 当前硬件M1 Max/64GiB；正式应用109仍用ChatGPT Auth `gpt-5.6-terra`，reasoning=none、stream=true，共享URLSession连接池，response.completed到达即结束读取。关闭思考、开启stream、复用连接已落地。
- 109最近两条真人成功样本（北京时间12:27:40、12:28:52）分别：ASR1171/748ms，polish3004/2535ms，归一化202/58ms，注入88/70ms，总processing5705/4691ms。扣除已计auth/encoding/ASR/polish/normalization/inject后，余额1240/1280ms；n=2仅报告单例/范围，性能p95待新基准。
- `ChatGPTTranscriber`在ASR网络计时开始前调用`promptHintTerms`，对17503条term按usageCount及每次比较即时fold排序；`OpenAICompatibleTextPolisher`在polish计时内逐条fold约17674个词项、再过滤glossary。姓名召回在归一化计时开始前执行。现有分项无法分清这些CPU、凭据、网络等待和输出生成。
- 离线只读profile：从当前源码抽取同一computed property、姓名索引及prompt builder表达式，以本机已导入17674条词项执行，独立Swift -Onone进程（正式包目前同为debug构建），没有网络、GUI或凭据访问，输出仅计数/计时。ASR全量排序5轮1012–1043ms；polish prompt构建5轮663–689ms；预热后的姓名查询约40ms，姓名索引一次预热435ms。预先计算的排序结果读取近零；完整生产缓存实现仍须测量，不能将该读取值作为整段耗时。表达式profile独立于安装版，1.7秒是两个热点之和的观测，节省量待候选实测。
- 两条真人polish输入估算640/650 tokens；输出估算固定下限120，属于估算器产物，不能据此认定模型实际输出120 tokens。应记录服务usage或标unknown。

## 已测模型与新的候选

| 路线 | 现有证据/成本 | 本轮判断 |
| --- | --- | --- |
| A 当前ChatGPT + 本地缓存 | 原账户、原模型；两个本地热点合计约1.7秒 | 第一优先，目标回收约1–1.6秒待实测，无额外模型费/目的地 |
| B1 `qwen3.8-flash` 非思考 | 北京官方表0.8/2.7元每百万输入/输出token，100万试用额度90天规则，具体账户资格未知；1000入+300出约0.00161元/次 | 新一代首轮候选，速度和保真仍未实测 |
| B2 `qwen3.7-plus-2026-05-26` 非思考 | 北京固定版本原价2/8元每百万，1000入+300出约0.0044元/次；该固定版本表列无免费额度 | 质量候选，账户模型权限/非思考参数接受性均须先核；官方通用错误页与混合思考说明有口径差异，实测若只支持思考则退出低延迟组 |
| C Gemini 3.5 Flash-Lite | 官方有免费档，付费0.30/2.50美元每百万；免费输入/输出用于产品改进，付费栏为No | 免费探索仅限人工合成素材，姓名/真实文本需单独的数据目的地决定；不列第一批生产候选 |
| D 本地MLX整段润色 | M1 Max 64GiB具备本地试验条件，无调用费；当前无本机token/s和中文保真证据 | 备选；首token、生成、冷启动和后台负载需实测，再决定模型与下载 |

此前旧`qwen-flash`真实配对38/38请求成功，7类×5轮完整输出中位461ms（GPT2735ms），人工完整语义29/38（GPT38/38），发生添写/漏要求/改范围；保真门槛失败，保留失败结论。官方现确认该alias仍是`qwen-flash-2025-07-28`，故3.8须单独评价。GLM-4.7-Flash此前3/4成功、14.7–35.2秒且429；6-Luna此前仅约16%加速并丢意图；均不作为本轮优先默认候选。

DeepSeek当前官方首调页已将推荐模型标为`deepseek-flash`、实际服务V4.1-Flash-1017，默认思考开启，允许disabled；旧deepseek-chat/reasoner说明不能沿用。本轮价格入口的页面回读未建立有效定价表，故不作免费或更快结论，列后备研究。

## 其他机制的适用性

- OpenAI公开API Predicted Outputs适合“大部分原文保留”的整段修改；官方支持GPT-4o/mini、GPT-4.1/mini/nano，使用Chat Completions prediction。当前ChatGPT私有账户Responses接入的支持未知，不直接加参数。公共API需要独立Key/计费/目的地授权；预测被拒绝部分仍计输出费。可作后续候选E。
- Prompt caching：官方GPT5.6+要求至少1024个可缓存可见输入tokens；目前约640–650是本地估算，须实测usage/cache命中。当前私有账户后端能力与公开平台文档分开核实。先保留固定system前缀、动态词表后置；有用few-shot扩充需要单独质量/缓存计费比较。首阶段不靠填充到阈值或新增预热请求取得收益。GPT5.6+的prompt_cache_key仅作分账，不以加入该key承诺路由提速。
- 短prompt可减少本地/服务prefill，但当前约650估算token，保持原提示做A的对照。后续压缩须单独重跑否定/更正/字面量/人名保真；实际生成长度影响解码耗时；max tokens设得过小会截断。当前maxOutputTokens=1200用于ChatCompletion；当前ChatGPT请求体未发送此字段，不能将其当成已生效的生成上限。
- 流式展示润色delta可改善可见反馈；最终整段completion与保护校正通过后再一次粘贴。此为体验选项，真实完成速度单列。本轮不实施HUD视觉改动。
- 录音中提前润色依赖volatile预览，最终原账户ASR常改人名；命中率/作废率和浪费调用未知。保留为实验，不改变当前最终完整ASR后整段润色语义，不通过提前粘贴抢时间。

## A：最小实施合同（已批准实施）

1. 先补单调时钟分解：词项准备、姓名检索、pre-normalize、prompt构建、凭据、请求派发→headers、首content delta、最后content delta、protocol completed、post-normalize、排版、注入。首delta仅指正文content；usage/cache无响应字段则记unknown。保留原总processing计时及重试总耗时。每个session有polishCallOrdinal（DictationPipeline因截断再次调用时递增），每个call有httpAttemptOrdinal（TextPolisher鉴权刷新重发时递增）；两级attempt独立计时，外层processing/polish累计包含全部重试。缺失headers/content delta/usage字段为optional unknown，零仅表示实际测得零耗时或真实usage为0；不记录正文、整本词库或凭据。
2. 新增纯本地不可变VocabularyIndex，预计算同一排序结果、fold过的canonical/alias键与glossary渲染行。缓存仅派生数据，输入配置和匹配/排序/预算语义保持。复用当前normalizer的缓存身份思路：缓存强持有源entries数组，按buffer identity+count取用，持有源数组保证同数量原地编辑触发Swift CoW；hintTerms按每次会话合并，不冻结旧重点词。配置加载/保存/来源导入后utility预热。冷缓存走相同正确构建；普通Retry持原配置；History Retry用当前配置；旧快照与新快照交错始终按各自输入取得正确index。单缓存被旧Retry替换时允许重新构建，避免引入持久缓存/多版本迁移框架。VocabularyIndex.Cache使用同一NSLock覆盖key验证、构建与完整快照发布；调用者取得不可变index即释放锁。旧预热以自身源数组发布，后续读取再次验证identity+count，始终不会把旧index用于新entries；允许额外冷构建，不允许半成品发布。测试预热A/读取B交错、同数改名、旧Retry后恢复新配置。
3. ASR仍按prioritizedHintTerms→相关姓名→同一ordered terms去重、600字符提示；polish仍按优先词及同一exact匹配、240字符预算、相同seen/break行为生成原messages。全部词项保留，个人姓名召回保持。性价比目标是把两个warm热点合计压至100ms以内；此为验收目标，非已实现结论。
4. 写入：新增Sources/ChatType/VocabularyIndex.swift；修改Sources/ChatType/AppConfig.swift、Sources/ChatType/TextPolisher.swift、Sources/ChatType/AppCoordinator.swift。计时与验收修改Sources/ChatType/ChatGPTTranscriber.swift、Sources/ChatType/DictationPipeline.swift、Sources/ChatType/PolishResponseTransport.swift、Sources/ChatType/LatencyRecorder.swift、Sources/ChatType/BenchmarkRunner.swift。新增Tests/ChatTypeTests/VocabularyIndexTests.swift（等价/预算/并发/失效）；修改Tests/ChatTypeTests/LatencyRecorderTests.swift（两级attempt/unknown）、Tests/ChatTypeTests/ChatGPTTranscriberTests.swift（ASR提示）、Tests/ChatTypeTests/TextPolishTests.swift（prompt）、Tests/ChatTypeTests/AppCoordinatorCancellationTests.swift（快照/Retry）。实现者保持本轮尚未改动的产品默认、个人来源、F5/ESC/关闭/Retry和品牌视觉。

## 比较与发布门槛

- 本地A先比较缓存前后至少100种确定性词库/上下文组合（空、重复、同数改名、user覆盖、aliases、普通词负例、600/240边界、hint变化、旧Retry快照/新配置交错），ASR提示和polish messages字节一致；261项既有检查及必要新增回归通过。用同一实际词库内容/合成上下文独立profile冷/warm，保留旧函数作临时研究oracle，不在产品保留双路径。
- 线上文本比较沿用此前10条独立素材（7类基本输入+3条独立质量输入，旧38是重复请求数），加8条匿名姓名/技术术语/中英数字/近音歧义及普通词负例，共18条独立输入×5轮=每模型90次；GPT和候选交错、首轮/热态分别报告，同一prompt和合成词库。完整completion耗时、TTFT、输出生成和错误率分开；每次尝试保留状态和实际耗时。成功completion分位明确成功数/总尝试数，失败/超时无completion端点、字段unknown，不填0、不冒充ready耗时；有业务失败的组须先解决再作采用判定。actual tokens与估算分列，真实语音F5耗时与文件/文本benchmark分列。
- A单独的线上音频配对：固定10条人工合成WAV、同一合成词库与预览上下文，每条3轮，形成至少30对/60次完整ASR+polish pipeline.prepare。签名验收构建的BenchmarkRunner依赖注入冻结109原表达式oracle与缓存实现，按轮交错A/B、B/A；产品正常入口固定用缓存实现，oracle仅留研究/测试，不引入公开切换或长期双路径。基线精确复现109各阶段表达式，禁止用重复构建两个完整index夸大基线。测试结束删除验收构建的oracle，重新跑受影响的确定性检查及真实小样本。
- 音频配对的pipelineReadyMs从调用prepare前同源单调时钟到正式ASR、全文润色、保护规范化/排版全部返回为止，包含本地词项准备、姓名检索、凭据和全部重试；不含真人讲话/停止键投递/最终注入，按“文件pipeline就绪”报告。纯文本polish基准单独隔离ASR变动；音频配对保留全部原ASR文本差异分层及尝试数，不按快慢筛掉配对。冷态为新进程首次派生词库，暖态为同进程同snapshot预热完成；冷/暖各自报告，至少30对暖态用于门槛；首次冷态另保留一对每文件，10对/20次，不混入暖态。API服务缓存与连接状态记录，顺序交错控制其影响，usage无字段则unknown。
- A发布：原提示逐字一致，词库/Retry行为一致；warm本地热点目标≤100ms；上述至少30对暖态file pipelineReady中位目标改善≥20%、nearest-rank样本p95不劣化，失败如实另列且业务失败未解决的组不进入通过判定。真人3类抽验报告F5单例/范围和行为，真人端到端p95保留到自然样本足够时再评价。短句期望回收本地1–1.6秒，以实测为准，文件指标不命名为真人F5到粘贴延迟。
- B替换默认：全部90次输出逐条核对请求、否定、更正、收件对象、数字/路径/代码字面量和未新增要求；关键术语/人名100%、无新增语义错误。短句≤80字组polish完整输出中位目标≤1.5秒，中长组目标相对同批GPT中位改善≥30%；各组p95不劣化。基线失败的素材先独立归因/修复，再定稿，不用降低门槛消除失败。
- 真实安装版抽验3种用户输入（姓名+技术词、较长含否定/改口、取消/重试），保留一次粘贴、剪贴板fallback和终态收起。真人小样本报告单例/范围；真实流量n不足30时不报告产品p95，不要求用户手工录30次。
- 候选达到门槛才讨论默认切换。失败继续当前109和原模型；备份当前签名包与配置，回滚用canonical install，保护后续用户数据；最终正常运行。当前既有质量缺口单独记录，不把此次小样本外推全姓名。

## 授权与费用

研究阶段完成调研、离线profile和评审；随后Longbiao批准A实施及既有账户对比，实际完成80次原账户完整请求和110安装，见实施记录。B1/B2虽沿DashScope北京主机，现有专用Key只获旧Qwen-Flash权限，新模型仍需确认权限与小额试验费用后用官方控制台办理，Key始终Keychain。建议候选两模型合计试验预算上限¥5，先核各自免费额度，预计按1000入/300出共180次约¥0.54；实际长度、模型原价和到账为准，达到授权预算前停止新付费请求；usage缺失时按请求大小/输出上限的保守费用上界占用预算，避免用估算器的120输出下限代替真实费用。B费用未发生。

新目的地Gemini/DeepSeek/OpenAI Platform、本地模型下载与独立凭据各按选择说明数据/费用后办理。初筛仅合成文本与合成词库，真实通讯录与录音不发给新服务；真实数据验收必须在该目的地获批准后。原账户ASR目的地保持。

## 来源与证据

- 本机日志：~/Library/Logs/ChatType/polish-speed-research-20261110/offline-profile.json；harness位于Caches/chat-type/polish-speed-research/Profile.swift，仅表达式和计数输出。旧Qwen配对见docs/qwen-flash-polish-2026-11-10.md，GLM/Luna见docs/iteration-108.md。真人n=2取当前latency.jsonl元数据，未提取个人转写正文。
- [阿里模型选择](https://help.aliyun.com/zh/model-studio/text-generation-model)、[模型价格及北京免费额度](https://help.aliyun.com/zh/model-studio/model-pricing)、[非思考参数](https://help.aliyun.com/zh/model-studio/deep-thinking)。上述价格仅引用表内北京短上下文原价/固定版本，未核账户新模型余额。
- [OpenAI延迟指南](https://developers.openai.com/api/docs/guides/latency-optimization)、[Predicted Outputs](https://developers.openai.com/api/docs/guides/predicted-outputs)、[Prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching)。仅作公开平台机制依据，私有账户可用性逐项待证。
- [Gemini官方价格/免费数据使用](https://ai.google.dev/gemini-api/docs/pricing#gemini-3.5-flash-lite)；web正文抓取content-type失败后用同域pricing.md公开文档读回，缓存于本机研究日志。DeepSeek只引用[首调模型说明](https://api-docs.deepseek.com/quick_start/pricing)、[思考开关](https://api-docs.deepseek.com/guides/thinking_mode/)，不沿用过时价目。


## EGM首轮处置

设计批评指出旧38是请求数、独立素材仅10条；已改为10+8=18条独立输入×5=90次/模型，两个新候选180次与对应费用同步修正。readiness指出缓存并发发布、A音频配对与两级attempt计时缺口，均补成合同；补齐源码/测试路径。fresh-context定向复核已实读修订合同与直接依赖，剩余Blocker/Major/Nit为0/0/0。此前已闭合范围沿用；本轮结论为方案准备完备，实际提速与新模型保真仍待实施后验证。


本地推理框架依据：[MLX LM官方仓库](https://github.com/ml-explore/mlx-lm)支持Apple Silicon上的文本生成、流式生成与量化；本轮没有下载/运行任何本地润色模型。

评审记录：[EGM报告](reviews/polish-speed-options-2026-11-10.md)。研究结束时正式安装版仍为109，当前model/provider与原状态一致，正常进程89368保留运行。runtime-baseline.json与offline-profile.json均仅含安全配置和统计。
