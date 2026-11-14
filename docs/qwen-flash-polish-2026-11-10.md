# Qwen Flash 整段润色接入与配对验收

状态：Qwen接入版已检查、打包、安装；独立Keychain凭据及真实API连接通过。76次合成配对已完成；Qwen速度门槛通过、保真门槛失败，默认保留ChatGPT gpt-5.6-terra。本地ASR和原整段润色流程保持。主Agent负责源码、配置、安装、GUI单writer；EGM只读审查。

## 边界与当前基线

正式安装版0.5.1(1)，Team HJG65XBC25，现有本地SpeechAnalyzer实时识别；润色默认ChatGPT gpt-5.6-terra。doctor读回签名有效、运行PID31999、无crash。本轮保留本地音频、F5/F5、ESC/关闭/Retry、整段术语规范化→整段原prompt润色→保护规范化→一次插入/剪贴板。此前235项检查有效，改动后跑本项目canonical检查。

## 最小实现

新增文本润色provider qwenFlash，沿现有TextPolisher私有provider分支；保持两条ASR路线。固定北京已支持域名 `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions`，固定model `qwen-flash`，`enable_thinking=false, stream=true`，temperature/max_tokens沿现有值。官方文档仍支持该公共域名；本轮不引入可编辑端点/跨地域或动态Workspace host。采用现有ChatCompletion SSE完整stop结束语义，拒绝全部redirect；Qwen key只发固定北京host，不取ChatGPT OAuth/GLM key。新协议兼容分支复用现有prompt及整段输出处理；无自动跨目的地fallback，失败沿原规范化文本回退。

独立QwenKeyStoring/KeychainQwenKeyStore，service `me.longbiaochen.ChatType.QwenAPIKey`, account default；仅load/save/metadata contains，存储不进入配置/日志/报告。Settings增加Qwen安全框、Save Key及元数据状态；缺Key阻止保存Qwen，其他provider正常；Save Key仅保存凭据，Save Settings从下一会话生效。Test Connection同生产polisher发一条人工合成文本，选择变更时使测试generation失效、清理消息并允许新测试；每次异步成功/失败和defer忙碌状态仅在generation仍匹配时回写，覆盖A→B→A与交错完成。状态/路由展示涵盖Qwen实际模型和host。

写入范围：新增Sources/ChatType/QwenKeyStore.swift；修改AppConfig.swift、TextPolisher.swift、PolishResponseTransport.swift、PreferencesWindowController.swift、BenchmarkRunner.swift；新增Tests/ChatTypeTests/QwenTextPolisherTests.swift，按需扩展ConfigTests/StreamingTranscriptTests。文档本文件、README中英文/CHANGELOG/release。保留全部既有dirty和凭据。

## 费用与账户

[模型信息](https://help.aliyun.com/zh/model-studio/qwen-flash)：北京短上下文输入¥0.15/M、输出¥1.5/M，1000输入+300输出约¥0.0006。免费额度按模型与90天有效期/账户控制台核实；当前账户余额未知。优先使用现有北京额度；如无额度，合成35次预计远低于¥1，低成本调用已授权；不订阅套餐、不充值。控制台如要求本人认证/协议或创建新安全凭据动作确认，交由用户完成对应最小动作。仅使用标准API key，独立存Keychain。新增供应商与目的地授权来自本轮“继续接入并实测Qwen Flash”。

## 验收与切换

1. 注入凭据/网络测试：旧配置默认保持GPT，Qwen保存/缺key和mode，固定host/model/非思考/完整prompt，三方凭据隔离，SSE完成/坏流/length/filter/取消、429安全错误与无隐式转发。
2. canonical scripts/check.sh、package/install，缓存输出在~/Library/Caches/chat-type；只一个release build。官方Computer Use在/Applications/ChatType.app验证安全保存、缺Key、连接测试与持久选择；原默认在benchmark期间仍GPT。
3. 复用现有7类人工素材，每模型每类5轮交错，当前GPT gpt-5.6-terra与qwen-flash共70请求。Qwen首个失败即停该模型，保留失败类别；各provider显式凭据门禁。另补3条否定/数字与精确字面量/术语素材，包含专名、邮箱、金额、撤回修正、收件与暂不发送意图，同prompt、独立人工素材，不使用用户录音。7类每侧5轮是主速度对比，新增素材各侧1次独立质量检查；报告分母与严格字面量结果。
4. 手工读取全部Qwen输出，与输入逐条比较；每个请求/限制/自纠/否定/专名数字和精确字面量保留为质量门槛，任何有效语义丢失保持GPT。普通词polish/Polish差异单列，命令/路径/版本大小写严格保留。成功35/35，完整输出中位数比本次GPT下降≥20%、多数类别中位数下降，新增质量素材全部通过，才进入默认切换。首token未采，完整输出耗时为产品等待的主要指标，结论仅限本机素材和当前账户。
5. 通过后官方Computer Use在现有Provider Picker选Qwen、Save Settings，读回磁盘provider及真实连接；正常安装版实际F5录音/停止、实时出字、完整粘贴/剪贴板和收起。若缺少可理解的真实麦克风素材，只请求用户一句话，等待现场并继续读匿名耗时。出现质量/粘贴问题按同一Provider UI回GPT并保存；原模型/密钥保留。失败则保留GPT并记录精确结果，应用正常运行、Settings可见。

EGM定向评审、实测结果、最终默认和遗留依赖分别补充于此。

EGM首轮已读persona/standard，发现1项Major：异步Test Connection旧请求可覆盖当前provider状态。实现已加generation并约束所有回写；提交定向复核。账户通过系统已有凭据登录，北京控制台qwen-flash显示额度/到期为“-”、用完即停“不支持开启”，本轮按已授权低成本调用，免费余额没有建立。

## 当前执行证据

- 最终接入候选243项测试通过，策略/landing/正式包元数据检查通过；canonical check日志 `~/Library/Logs/ChatType/qwen-flash-2026-11-10/check.log`。GLM原流式解析器重命名为共用ChatCompletionPolishStream，stop/取消/错误契约保持。
- EGM定向复核已实读persona、standard及修复：generation隔离的原Major关闭，剩余0/0/0。静态审查与真实GUI分别记录。
- 已由canonical install安装 `/Applications/ChatType.app`，LaunchServices以 `--settings` 正常启动。官方Computer Use可选Qwen Flash、安全框及Save Key；缺Key点击Save Settings显示“先保存Qwen API Key”。持久默认仍GPT。用户随后完成专用Key创建并回复“done, cont”，已继续安全配置与线上配对。
- 北京控制台已登录。免费额度筛选显示qwen-flash无可用免费余额，额度/到期为“-”、用完即停“不支持开启”；采用已授权低成本实测。专用Key为ChatType Qwen Flash Polish，自定义权限仅1项Qwen-Flash，IP保留平台默认；2026-11-10 09:59:14创建。Agent经官方Computer Use将一次性Key直接填入ChatType SecureField并保存Keychain，看到Key saved，输入框清空；临时变量及剪贴板已清理，网页一次性显示关闭。凭据未进入终端、日志或报告。应用真实Test Connection返回Connected: Qwen Flash。

安装版连接切换验收：在ChatGPT Auth启动真实合成Test Connection，观察Testing及按钮disabled；随后切到未保存的Qwen，观察消息清空、测试按钮恢复可用。待原请求完成后继续核对Qwen状态，生产配置始终GPT。

当前配对由正式安装版通过LaunchServices运行，`CHATTYPE_BENCHMARK_POLISH_MODELS=gpt-5.6-terra,qwen-flash`、`CHATTYPE_BENCHMARK_RUNS=5`；主7类每侧35次加3条独立质量素材，计划共76次。日志目录 `~/Library/Logs/ChatType/qwen-flash-2026-11-10/`，原始合成结果 `paired-polish.jsonl`。仅发送人工素材，生产默认仍GPT；掩码创建凭据 `key-created-masked.jpg`。

## 配对结果与采用决定（本机北京时间2026-11-10上午）

| 模型 | 网络成功/尝试 | 主测试完整输出中位数 | 范围 | 主测试严格字面量 | 人工完整语义保真 |
| --- | ---: | ---: | ---: | ---: | ---: |
| ChatGPT gpt-5.6-terra | 38/38 | 2735ms | 1714–5444ms | 30/35 | 38/38 |
| Qwen qwen-flash | 38/38 | 461ms | 261–1995ms | 35/35 | 29/38 |

主速度统计覆盖7类×5轮＝每侧35次；额外3类各1次仅作独立质量核验。Qwen中位完整输出下降83.14%，7类各自中位数均下降；长段中位数1370ms，对照5160ms。自动字面量检查与人工语义检查分别报告。GPT严格字面量5项差异均为普通词polish→Polish，全部有效要求/约束保留。两侧额外3条的字面量均3/3。

主Agent逐条读完双方76个完整输出，按输入的每个请求、限制、更正、事实和字面量标注：Qwen的9项语义差异为主测试8项、补充1项，见 `fidelity-review.json`。明确例子：

- literals第2轮遗漏“只整理表达、不要执行这些命令”，加入原文没有的“只修改设置页、先不要发布”。
- long第3/5轮新增Whisper-tiny/DistilWhisper模型建议和设置页/发布限制；其他长段增加永久保留、仅使用副本等原文无要求的条件。
- negation第4轮把文本润色限制收窄到设置页；mixed第2轮省略连接已断的事实。
- quality-scope省略了“给同事整理消息”的收件对象和请求；其他否定、草稿/确认后发送仍保留。

这些差异覆盖新增、遗漏及范围改变，触发预设保真门槛失败。Qwen保留为已配置可选路线，默认继续ChatGPT；本轮按用户“通过验收后再切换”执行，无Qwen默认采纳或Qwen真实F5语音验收声明。原始素材/prompt/整段流程保持，未做模型专属prompt补丁或放宽门槛。

## 费用与当前现场

北京qwen-flash当前无可用免费额度，本次按已授权低成本方式实测。专用Key费用页面当前显示总消费/账单¥0.00、暂无数据；正式入账费用仍待提供方结算。参考价1000输入+300输出token约¥0.0006/次；此为测算，当前账单视图的零值没有作为免费调用结论。

官方Computer Use已重新选择ChatGPT Auth并Save Settings，随后验证现有默认的真实连接；安全配置读回、最终运行与结果见最后收尾记录。Qwen Key仅存Keychain，独立专用Key的模型权限保持仅Qwen-Flash。凭据一次性显示已关闭，中转剪贴板已清理。

证据目录：`~/Library/Logs/ChatType/qwen-flash-2026-11-10/`。`paired-polish.jsonl`原始人工合成输出，`paired-summary.json`分组统计，`fidelity-review.json`逐条语义判定，`acceptance.json`采用决定，`key-created-masked.jpg`创建掩码凭据。质量结论仅覆盖这批素材和当前模型/账户，不外推所有自然语音。

## 最终状态读回

- implemented / checked：Qwen固定非思考流式接入及独立Keychain完成，243项检查通过；源代码在该次检查后保持。
- packaged / installed：正式版0.5.1(1)在 `/Applications/ChatType.app`，最终签名校验通过。
- live accepted：Qwen密钥安全保存与真实合成API连接成功，双方38/38请求完成；Qwen速度通过、完整语义保真失败。Qwen默认切换及真实语音F5后续验收按预设条件保留，生产继续ChatGPT。
- default / left running：持久配置 `provider=chatGPTAuth, mode=always, model=gpt-5.6-terra`；官方Computer Use观察Provider=ChatGPT Auth、Connected: ChatGPT Auth，AI Polish窗口保持可见。当前正常运行：`59794 /Applications/ChatType.app/Contents/MacOS/ChatType --settings`。
- 原录音、本地转写、全文术语/润色/保护规范化及一次粘贴流程保留。专用Key仅存Keychain，未写配置、日志或报告。最后现场收据 `final-runtime.json`。
