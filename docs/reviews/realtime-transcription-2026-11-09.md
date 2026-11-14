# 实时转写三方案：EGM 独立评审

日期：2026-11-09（Asia/Shanghai）。

评审对象：[三方案评估与迁移设计](../realtime-transcription-options-2026-11-09.md)。

用户要求：参考接线小妹最新聊天室实现，保留 ChatType 基本操作与整段润色流程；比较 ChatGPT、本地算力、低价全云三类方案，EGM 评审后进一步讨论。

## 评审方式和适用范围

采用 EGM 的独立设计与实施准备度评审。两名 reviewer 使用 `fork_turns=none` 的原生 sub-agent，分别读取插件的 `design_critic.md` / `feature-spec-standard.md` 与 `implementation_readiness.md` / `implementation-readiness-standard.md`。只读报告、相关源码和已列官方来源，独立于作者上下文；没有运行收费推理、构建或读取凭据。

- 设计评审：`/root/egm_design`。
- 实施准备评审：`/root/egm_readiness`。
- 修改范围定向复核：`/root/egm_recheck`。

评审针对本轮方案讨论阶段。后端、费用、数据流、产品路线与验收阈值仍需 Longbiao 讨论定案；本报告评估方案是否具备讨论依据。

## 发现与处置

| 严重度 | 核实的缺口 | 文档中的处置 |
| --- | --- | --- |
| Major，两名 reviewer 重复提出 | final/terminal 信号缺失、连接存活或 analyzer finalize 停滞时，缺少退出处理 | §4.2 明确可取消收尾期限、partial/failed、退出 processing、原音频/片段保存与禁止缺失文本自动插入；§5 增加 terminal 缺失与取消等待测试。具体参数随选型/实测定稿，遵守项目新增限制要求 |
| Major | 已完成片段的保存、恢复展示与 Retry 没有接入现有恢复存储 | §4.2/4.3 纳入 `RecoveryHistory.swift`，设计可缺省快照、逐 final 更新、部分文本复制、缺失范围、旧记录兼容和原 provider 整段手动 Retry；§5 增加完整恢复旅程测试 |
| Nit | 完整 ASR 后润色失败的现有安全回退需要显式保留 | 固定流程与 §4.2 保留规范化文本回退和错误标记；§5 补充 SSE 中断、HTTP 错误、二次截断用例 |

作者核实依据：参考发布版 `speech.py` 在 `finish-task` 后等待 `task-finished` 时使用有限等待；ChatType 当前 `recordRecoveryFailure` 写入 `asrText: nil`；`DictationPipeline` 在润色错误或二次截断时返回已有规范化文本。上述缺口已在方案中补齐。

## 独立核验结论

设计 reviewer 核实：参考分支 `f93627388902aae8ec95749f6c2093050cf1dd7d` 的 ASR 实际过滤 partial、只保存 final；聊天室 postprocess 负责状态收尾。ChatType 串行 ASR/归一化/整段润色/保护性归一化和收齐 SSE 后解析的描述与源码一致；报告月费算术与阿里官方价格一致，提速保留为配对测试目标。

实施准备 reviewer 认为文档覆盖单一 PCM 源、会话代际、去重与取消、尾部定稿、原润色保护、低版本路径、安装版回退及真实交互验收，适合进入产品讨论。该阶段无 Blocker。

定向复核已返回：两项 Major 和一项 Nit 的文档处置均通过，当前比较阶段没有新增 Blocker、Major 或 Nit，适合继续三方案产品讨论。结论针对方案文本；运行代码与安装版仍为原有状态。

## 下一阶段决定

建议先验证本机 Apple ASR + 原整段润色，再配对比较免费 GLM / 低价 Flash 的润色；Fun-ASR + Flash 作为全云对照。Longbiao 讨论确定服务、数据与收费、两条产品路线的调整范围、预览位置、恢复重发与具体等待/采用判据后，再形成对应实施候选。源码、打包、安装、真实交互和最终运行状态分别验收。
