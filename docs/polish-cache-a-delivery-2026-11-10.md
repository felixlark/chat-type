# 110：同模型词表缓存加速验收

> Historical evidence for the date/build recorded below. Current requirements: [PRODUCT](../PRODUCT.md).

2026-11-10，M1 Max / 64 GiB。Longbiao批准A：保持当前模型、术语与整段润色流程，完成速度对比和安装版验收后再讨论换模型。

## 实施结果

- 0.5.1（110）新增不可变VocabularyIndex，缓存原ASR排序、姓名优先词与glossary匹配键/渲染行。强持原数组，identity+count+locale校验与完整发布由同一NSLock保护；词表编辑触发CoW失效，hintTerms仍逐次合并。配置加载/保存/导入沿既有入口预热。
- 模型仍为ChatGPT Auth `gpt-5.6-terra`。本地实时预览→原ChatGPT账户完整录音ASR→术语规范化→整段润色→术语保护及中英数字空格→一次粘贴保持。当前完整配置与109备份相等，词库17674项、重点词3项、glossary预算240保持；凭据和目的地沿用原状态。
- 实时引擎为Apple SpeechAnalyzer（fastResults + volatileResults）；最终音频上传原账户的`chatgpt.com/backend-api/transcribe`，该接口未回传ASR底层模型名称。整段润色调用`chatgpt.com/backend-api/codex/responses`，模型`gpt-5.6-terra`、reasoning=none、stream=true、store=false。两者均为既有私有账户接口依赖。
- 新增单调计时：ASR词表/提示构建、姓名检索、前后规范化、排版、polish提示/凭据、HTTP headers/content delta/completed和usage。二次全文润色与HTTP鉴权重发分别编号；缺失字段为unknown。计时不记录正文、词表或凭据。服务缺少流式Content-Type时被动观察data行，原响应字节和读取结束条件保持。
- 产品源码已移除临时109对照注入和运行分支；冻结表达式仅留测试及Caches研究材料。

## 同账户配对结果

固定10条合成WAV，使用当前17674词项的同一快照、相同preview上下文与相同模型。签名安装版验收入口依赖注入冻结的109词表/提示表达式，对照缓存实现；其余pipeline相同。每文件3轮、A/B与B/A交错，共30对暖态；另每文件新进程1对，交错次序，共10对冷态。80/80完整请求成功，全文润色fallback为0；全部80份实际ASR输入对应的原/新polish提示相等。

计时从pipeline构造前开始，包含词表准备、完整ASR、整段润色、保护与排版返回，排除讲话、实体停止键投递和最终粘贴。冷态首次构建包含在construction内。连接/服务端缓存状态随原账户自然运行，未添加预热模型请求。

| 指标 | 109表达式对照 | 缓存实现 | 观测 |
| --- | ---: | ---: | --- |
| 暖态文件就绪中位，30次/组 | 5439.6 ms | 4330.5 ms | 改善20.4% |
| 暖态nearest-rank样本p95 | 9481.5 ms | 6825.3 ms | 改善28.0% |
| 暖态两处本地热点合计中位 | 1619.4 ms | 19.8 ms | ≤100 ms目标通过 |
| 暖态polish阶段中位，含本地prompt | 3019.5 ms | 2789.0 ms | 网络与模型输出波动仍在 |
| 冷态文件就绪中位，10次/组 | 5969.5 ms | 4484.2 ms | 改善24.9%，单独报告 |
| 冷态缓存首次构造中位 | — | 324.6 ms | 正常入口后台预热 |

暖态30对中14对raw ASR完全相同，其余16对有ASR文字差异；冷态10对中7对相同。全部配对保留，未按时长或文字筛样。中位目标≥20%、暖态样本p95不劣化以及本地热点≤100ms均达到；这些数值属于文件就绪基准。

## 保真与适用范围

108组合逐条比较ASR提示和polish消息role/content的UTF-8字节，另11个600字符截断边界，覆盖NFD/重音去重。并发、同数编辑、旧新快照和动态重点词检查通过。EGM最终实现复核0 Blocker / 0 Major / 0 Nit。

合成语音的pstack/SmartShadow、数字改口、会议改期、草稿确认和长句要求在两组均保留。逐条核对同时记录既有缺口：109组3/3、缓存组2/3的合成人名音频把李卓玟识为其他名字；两组OpenClaw均误识；两组位置音频均遗漏“只”；缓存组一次将“只修改”识为“支持修改”。相应原ASR文字已含误识，润色沿相同提示处理。该组覆盖合成素材，真人姓名与约束另做现场验收。

## 已完成的交付门槛

- implemented：缓存与分段计时完成，临时产品对照路径已删除。
- checked：最终canonical scripts/check.sh通过，267项测试及policy/landing/package检查通过。
- packaged：0.5.1（110），稳定本机签名；输出在Library/Caches/chat-type/dist。
- installed：通过canonical install安装到/Applications/ChatType.app，LaunchServices正常启动；Account显示Ready，麦克风/Accessibility均Granted。

现场F5已真实运行并粘贴到Codex，姓名质量验收失败，当前应用保持正常运行。具体见下节。

## 现场回读与未通过项

14:51:15实际11791ms录音，ASR2184ms、polish3672ms、规范化324ms、注入75ms，总处理6490ms，状态pasted。原ASR出现陈龙标、李泽文、戴景才；最终陈龙彪正确，后两名仍错误。用户确认本次只读到“下午三点”，尾句遗漏项已排除。

当前安装版运行记录另显示14:54:30录音取消，14:54:37开始的下一次录音最终pasted，取消后重入和注入路径已有实际执行记录；预览及浮窗收起的最终用户反馈仍待取得。

新计时成功观测同一次HTTP：headers2170ms、首正文delta3162ms、末delta3499ms、completed3556ms、读完3653ms；真实usage为369输入/38输出、cached input=0。估算698/120与真实usage分开。当前主要等待落在联网请求和首正文输出前。

针对本次原ASR和实际pre-normalize输入，以真实词库作离线表达式回读：109与110的ASR hints及polish消息UTF-8一致。两个人名均在词库；李卓玟、戴锦钗均未进入这次近音召回和glossary，陈龙彪已有user correction优先词并进入glossary。后续Foundation音译与缩池实验进一步定位：李泽文/李卓玟的ze/zhuo编辑距离3，超过现有上限2；戴景才/戴锦钗有两处音节差异，超过最多1处的门槛。缩至3个人名仍复现两处漏召回。匿名对照见[规模审计](/Users/longbiao/Library/Application%20Support/ChatType/contacts-audit-20261110/vocabulary-size-audit.json)。

最小修正候选是把这两个既有名字追加到当前重点词，保留模型、整本词库内容及来源、匹配算法和整段流程。离线已确认候选使两名进入ASR600字符提示与polish240字符glossary。该调整改变A的原提示不变合同，尚未获批且未执行；用户选择先调查词库规模和Apple Contacts重复情况。[后续只读调查与EGM设计](https://github.com/felixlark/chat-type/blob/5350f037b3782e875f0f23e8cb8421fddcdedcac/docs/contacts-optimization-2026-11-10.md)。原生调查后干净110保持，词库17674、重点词3、模型gpt-5.6-terra及配置字节一致。

## 可复核证据

后续检查时原Library/Caches/chat-type/polish-cache-a及Library/Logs/ChatType目录已不可见，下面同批音频原始日志链接当前不可读。本文保留当时工具实际回执的统计；当前联系人只读审计与本机规模实验回执另存在Application Support路径，范围分别报告。

- 统计JSON (`/Users/longbiao/Library/Logs/ChatType/polish-cache-a-20261110/comparison-summary.json`; private historical receipt, unavailable in a repository checkout)
- 暖态60次原始配对 (`/Users/longbiao/Library/Logs/ChatType/polish-cache-a-20261110/warm-paired.jsonl`; private historical receipt, unavailable in a repository checkout)，同目录cold-*.jsonl为20次冷态配对；正文全部来自上述合成素材。
- 最终canonical检查 (`/Users/longbiao/Library/Logs/ChatType/polish-cache-a-20261110/check-final.log`; private historical receipt, unavailable in a repository checkout)
- [EGM复核](https://github.com/felixlark/chat-type/blob/5350f037b3782e875f0f23e8cb8421fddcdedcac/docs/reviews/polish-speed-options-2026-11-10.md)

109安装包与配置备份位于本机Caches/chat-type/polish-cache-a/R109-installed和Application Support/ChatType/polish-cache-a；回滚沿canonical install，保留后续用户数据。当前ChatGPT私有账户端点依赖保持，后端延迟仍占主要剩余耗时。
