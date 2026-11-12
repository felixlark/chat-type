# Stage A：恢复原账户最终转写

2026-11-10。执行电脑为当前 Mac，候选 0.5.1（108）。用户批准完整录音恢复上传原 ChatGPT 账户；本阶段先恢复质量，后续单独优化停录速度。

## 当前实现

- 单麦克风 WAV 先启动，Apple SpeechAnalyzer（zh_CN，fastResults + volatileResults）随后异步挂接，负责实时预览。准备、转换或结果流失败时保留已有预览并显示状态，继续保存完整录音。磁盘与麦克风失败沿正式错误路径处理。
- F5 停录封口 WAV，取消预览；原 chatgpt.com/backend-api/transcribe 负责正式 ASR。其具体 ASR 模型 ID 未公开。预览结果不写入正式 ASR 字段；生产录音、普通 Retry、History Retry 和 CLI 都关闭 Apple 最终识别捷径。显式本地文件实验仍可运行。
- 保留术语对齐 → ChatGPT Auth gpt-5.6-terra 整段润色 → 术语保护 → 一次粘贴。GLM、Qwen 继续作为用户选择项。
- F5 开始使用 AppConfig 值快照，普通 Retry 沿用快照；History Retry 按当前设置重新识别。重点 hintTerms 进入 ASR 前600字符提示，且优先进入润色240字符词表；其余 ASR 词项按使用次数、折叠拼写和原序排序。实际 promptIncluded 按后端传输结果记录。
- 词表配置使用 pstack / SmartShadow 两个重点提示，pstack canonical 项，peacteg→pstack 和 smar shade→SmartShadow 两条精确 correction。smart shade→smart shade 复用现有纠正保护机制，保留普通短语；错拼使用精确纠正，避免扩入模糊匹配参考集。代码反引号/围栏、路径等字面量受保护，原显式文件名 hint 语义保留。
- 离线、超时、DNS、429、5xx、空 ASR 保留录音并提供 Retry；Retry-After 按秒或HTTP日期安全解析。Cloudflare challenge 沿原三次自动/一次手动上限，无新增自动重试。

## 检查与恢复

252项单元/进程内集成测试通过；policy 与 landing 检查通过。签名包、安装、18次音频质量与安装版交互实际结果如下。

源码基础为当前分支既有提交与本轮既有未提交改动；保留全部无关文件。原安装签名包保留于 ~/Library/Caches/chat-type/quality-redesign/R0-installed/ChatType.app，配置备份在 ~/Library/Application Support/ChatType/quality-redesign/R0-config.json，凭据仍由 Keychain 管理。恢复时将备份作为 CHATTYPE_DIST_PATH 传入 canonical install，随后通过 LaunchServices 启动正式路径；恢复配置须保持用户后续新增内容。

## EGM 实现复核

fresh-context readiness reviewer 实读批准设计及本轮直接依赖，复核预览隔离、精确错拼保护与 Retry-After 修复后剩余 Major 0。额外显示建议已处理：预览故障保留已有字幕并追加状态。快照使用现有 AppConfig 值拷贝，保持文件规模。

## 实际验收

- implemented / checked / packaged / installed：当前0.5.1（108）包含Stage A与最终中英文/数字空格排版。canonical scripts/check.sh全部通过：252 tests、policy、landing、签名包metadata。正式路径 /Applications/ChatType.app，签名沿用现有身份。
- live F5：用户实际录入8.295秒验收句，恢复完整WAV上传402292 bytes，正式ASR 1295ms、原ChatGPT润色2781ms、处理总计5204ms、pasted。pstack和SmartShadow正确；“整段润色”在原始ASR已误为“诊断润色”，原润色随后保留该错误。
- 本轮按明确上下文补入“整段润色”重点词与“诊断润色→整段润色”精确纠正，保留独立“诊断”原文。通过官方Computer Use在安装版History对同一8.295秒录音显式Retry一次，ASR1253ms、polish3173ms、总处理5567ms、pasted；安装版History可见最终句：“请用 pstack 评审 SmartShadow，先不要发布；只改设置页，保留原有整段润色的流程。”此前真实F5字幕是否持续更新尚缺本次明确反馈；既有浮窗验收与fastResults测试按原范围保留。
- 最终排版在原术语/润色流程后执行：中文与Latin/数字相接时插入空格；已有空白、反引号/代码围栏、路径、URL、邮箱内部保持原样；覆盖重复执行和数字/版本场景。History与粘贴使用同一最终文本。
- 文件质量集：6条Tingting合成音频×3=18次，全部完成原账户ASR及原模型润色，18/18实际promptIncluded=true。SmartShadow最终18/18出现；排除口头被EGM取代的3条pstack后，pstack出现12/15；普通smart shade保留0/3。有1条scope样本原ASR把“只修改”转成“并修改”，最终保留了范围误差。此前R0本地文件ASR在6条中均漏掉pstack，保留原对照。合成音频发音与真人口音分别看待，文件耗时单列；本集未通过完整质量门槛，速度下一阶段待质量样本收敛。排版增量未更换ASR/润色模型，复用18条语义证据；252项最终检查及同一真人录音重试绑定最新候选。
- EGM复核的Major已处理；实际语音质量缺口继续开放。没有新增供应商、网络域名、付费接口或系统权限。
- left running：正常安装版保留运行，Settings → History → AI polish结果可供核对。取消/重入/Retry保存/迟到防粘贴采用252项内相关回归；本轮真人F5与安装版History Retry已实测，ESC/inline-close本轮未重复走真人交互。

本机详细脱敏证据位于 ~/Library/Logs/ChatType/quality-restore-20261110/。历史全本地方案的模型与速度数据继续保留原候选标记。
