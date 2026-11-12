# 当前交付：本地预览与账户最终转写

2026-11-10，用户批准恢复完整录音上传原 ChatGPT 账户。当前候选保留 macOS 26+ Apple SpeechAnalyzer 的 fastResults/volatileResults 实时预览；F5 停录后完整 WAV 沿原账户转写后端处理，再沿用术语对齐 → gpt-5.6-terra 整段润色 → 术语保护 → 一次粘贴。

预览准备、转换或结果流失败时继续保存 WAV。预览文字仅供浮层显示，正式 ASR 字段来自账户转写。停录立即结束预览，无需等待本地 final。原 localFinalizationTimeoutSeconds 配置保留供旧本地实验兼容，当前 managed 停录路径不等待此超时。

F5 开始时冻结配置和术语；浮层 Retry 复用该快照与保存录音，History Retry 使用点击时当前设置重新识别。重点 hintTerms 优先进入 ASR 提示和润色词表；实际后端 promptIncluded 仍按传输结果记录。

当前实施与验收见[质量恢复记录](quality-restore-stage-a-2026-11-10.md)。以下为之前本地最终识别版本的历史证据，耗时与识别效果按原候选保留。

# 本地实时转写交付记录

日期：2026-11-09—10，Asia/Shanghai。候选仍在实际交互验收中。

## 实现

macOS 26+ 的 managed 路径使用 Apple SpeechAnalyzer，单一 AVAudioEngine 输入同时驱动本地 ASR、音量和恢复 WAV。`volatileResults` 与 `fastResults` 同时启用，同一时间范围的临时文本覆盖更新，定稿片段稳定保留。浮层在收到文字后扩展宽度，沿用原图标、配色、波形、关闭和计时控件。

第二次 F5 停止收音并收齐 final，之后原有整段术语归一化、ChatGPT 润色、疑似截断重试、保护性归一化和安全粘贴继续执行。录音不再发送给云端 ASR；润色文本仍发送到原已配置的 ChatGPT 账户端点。显式 compatible 路径保持原实现。

录音和每个 final 写入现有恢复记录；失败保留已定稿文字并在历史中标为部分转写。手动 Retry 使用整段保存的 WAV 做新的本地识别，不重复拼接旧结果。旧历史记录格式保持可读。会话取消和重入隔离旧结果，取消 processing 时同时取消模型收尾。

润色网络读取复用 URLSession.shared 的连接，在完整 response.completed 事件结束；HTTP 错误、incomplete、提前断流继续进入现有规范化文本回退。prompt、模型和润色顺序保持原值。

## 新增限制

`transcription.localFinalizationTimeoutSeconds` 默认 10 秒，可通过现有配置文件修改。位置：`AppConfig.swift`、`LocalSpeechRecorder.swift`。计时从停录开始，超期取消 analyzer 并保留 WAV 与 final，展示错误/Retry。依据为接线小妹发布版 finish-task 等待政策和本机尾部收齐风险；该参数仍需负责人在发布 PR 中定稿，当前没有合并 main。

## 已有证据

- canonical `scripts/check.sh`：211 项测试通过，策略检查、网页内容合同与打包元数据检查通过。生产权限流程保持原实现；协调器测试注入麦克风边界。
- 安装路径 `/Applications/ChatType.app`，Developer ID Application: LONGBIAO CHEN，Team HJG65XBC25，Hardened Runtime 与安全时间戳。
- 原安装版备份：`~/Library/Caches/chat-type/pre-realtime/ChatType.app`。新构建产物在 `~/Library/Caches/chat-type/dist`。
- 安装版通过 LaunchServices 处理人工编写的 14.936 秒合成录音，本地 ASR 文件识别 472ms；相同素材 WAV 的现有账户 ASR 对照为 1455ms。单次观测，文件识别耗时和实时停录后的尾部等待分别报告。
- 相同合成音频以实时速度输入 SpeechAnalyzer：仅 volatile 首次文本约 12.335 秒；volatile + fastResults 首次文本约 1.158 秒，停录前持续输出，59 次事件中最后一次为 final。此项验证模型事件，真实浮层需另验。
- 安装版完整本地文件识别 → 原整段润色 → 归一化：单次 ASR 472ms、归一化 122ms、润色 2457ms、合计 3052ms。
- 用户已反馈实际 F5/F5 能转写并返回文本；2026-11-10 进一步确认启用 fastResults 后浮层实时出字出现，效果很好。其余完整交互矩阵继续分项核对。

原始合成夹具、模型事件统计和匿名耗时记录位于 `~/Library/Logs/ChatType/realtime-20261109/`。其中本地/账户识别对照显示 Apple 对个别中文词和 API 等缩写存在误识别，准确率验收保持开放。历史观测中一次润色请求超时后按既有流程返回了规范化转写；其后已有实际成功润色记录，供应商尾延迟继续单列。

## 待关闭的验收

真实安装版的实时浮层、ESC、内联关闭、取消重入、错误 Retry、编辑器粘贴和无编辑焦点剪贴板，及准确率/延迟的配对样本。外部 GLM/千问润色尚未接入，当前凭据未改变。上述事项完成前保留“实施/检查/打包/安装已完成，现场验收进行中”的状态。

## 2026-11-10 专有词准确率诊断

当前实际路径为SpeechAnalyzer + SpeechTranscriber（zh_CN，本地系统模型、fastResults/volatileResults），原整段术语归一化→ChatGPT gpt-5.6-terra润色→保护归一化→粘贴。近期匿名耗时记录为local-speech、uploadedAudioBytes=0、textPolishProvider=chatGPTAuth、pasted。Qwen/GLM仅可选，当前均未启用。

官方Computer Use对照10:12原始ASR/最终输出：用户目标pstack在ASR和最终均为peacteg；目标SmartShadow在ASR为smar shade、最终已纠为SmartShadow。识别错误首先出现在本地ASR。当前hintTerms为空；词库有12315项，SmartShadow条目无alias，pstack无条目；实时recorder只传hintTerms，未传词库。润色glossaryBudgetCharacters实值240，候选还需先与输入匹配。

更关键的能力边界：[Apple官方答复](https://developer.apple.com/forums/thread/811083)明确contextualStrings作用于DictationTranscriber，SpeechTranscriber当前不使用此上下文；[官方属性说明](https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings)同样围绕DictationTranscriber描述热词。当前代码setContext调用保持，但术语增强效果未建立。把完整词库直接传入该模块缺少能力依据；切换识别模块需要独立验证实时性、准确率和术语能力。

前述76次Qwen/GPT配对覆盖人工文字润色，专业词真实音频识别验收仍有缺口。本次为诊断读回，保留现行默认模型与处理顺序；未声称专业词已修复。
