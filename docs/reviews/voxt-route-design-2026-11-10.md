# Voxt 技术路线设计：独立评审记录

日期：2026-11-10。正本：[CT-VOXT-20261110](../voxt-route-design-and-acceptance-2026-11-10.md)。范围为方案与验收标准，产品实现和运行验收分别留在后续执行批次。

## 评审方式与来源

按 GSE 内置 EGM（负责人保留任务上下文、独立新读者检查方案的审视方法）执行。通过宿主 `collaboration.spawn_agent`，所有 reviewer 显式 `fork_turns=none`。共享 checkout 的行为约束为严格只读，工具层文件系统隔离未强制；主 Agent 是文档唯一 writer。各 reviewer 的模型/推理档沿宿主继承，工具未返回实际模型ID或总token，均记未知。

reviewer 实读当前候选、项目AGENTS、对应persona与standards及直接源码；未用个人memory/旧chat。上游版本固定`voxt-v2.0.3`，公开源码通过`mcp__codex_apps__github_fetch`获取到本机研究快照；X原帖和同线程链接由`xurl --app xurl`以现有felixlark OAuth2读取。模型卡通过`mcp__huggingface__hf_fs`只读获取。运行时版本用Info.plist只读，进程用pgrep观察。

## 初审：v1

| Reviewer | 实际状态/读取范围 | 发现 |
| --- | --- | --- |
| voxt_design_review | complete；候选v1全文、design_critic、feature-spec-standard、AGENTS；本地录音/调度/pipeline相关源码、110与Stage A记录；上游pieces/live/models及长录音评测正文 | 0 Blocker / 1 Major / 0 Nit |
| voxt_readiness_review | complete；候选v1全文、implementation_readiness、implementation-readiness-standard、AGENTS；指定Swift恢复/路由/计时接缝、原设计10.7–10.8、package/install及上游分段/model manifest | 0 Blocker / 1 Major / 0 Nit |

### D1：生产分段质量采纳

- 原发现：P1文件接口质量通过与P2实时分段的输入上下文/切点不同。上游eval也分别记录whole与live-pieces的质量差异。
- 裁决：PROPOSE FIX；已核实`pieces.go`和`live.go`实际使用独立区间定稿，发现成立。
- v2修订：P2以生产同一路径1×实时供给重跑完整24条×3，预览/VAD/分段同时运行；全部满足质量门槛。指定姓名/数字切点与跨段撤回，P3绑定该识别候选。六条声学集继续验收交互和实际等待。

### R1：恢复身份与持久化

- 原发现：现有`RecoveryStore.record`按owned WAV文件名复用ID并覆盖journal。普通Retry、History Retry、进程重启需要明确分离录音与run归属。
- 裁决：PROPOSE FIX；主Agent读取`RecoveryHistory.swift`的record/writeJournal及`AppCoordinator.retryRecoveryRecord`，确认发现成立。
- v2修订：固定recordingID/WAV、runID/journal、sessionID/插入权三类身份；普通Retry复用run与快照，History创建关联新run；journal保存模型、坐标、快照引用、ledger与结果；WAV同步→原子ledger提交→发布进度；旧记录只读适配并保留原结果。增加旧格式/重启/同run/新run四类断言。

### 同批直接依赖

v2明确原WAV与16kHz模型PCM坐标转换/flush，分段cursor统一单位；将回环HTTP/WS每child临时secret鉴权列入P1适配和验收；补充当前模型卡许可证事实。两位fresh-context reviewer定向复核变化及其依赖。

## 定向复核：v2

| Reviewer | 实际状态/范围 | 结果 |
| --- | --- | --- |
| voxt_design_recheck | complete；v2全文、persona/standard/AGENTS，四份上游快照及三个Swift接缝；复核生产完整质量集、16kHz转换及回环鉴权 | 0 Blocker / 0 Major / 0 Nit |
| voxt_recovery_recheck | complete；v2全文、persona/standard/AGENTS，恢复/调度/录音/配置源码及install；复核run身份和持久化依赖 | 0 Blocker / 1 Major / 0 Nit |

### R2：重启恢复的实际入口

- 原发现：普通Retry依赖内存pendingRetry，History Retry创建新run，重启后继续原run的用户入口仍需固定。
- 裁决：PROPOSE FIX；对照当前AppCoordinator启动/Retry/History路径与v2合同，发现成立。
- v3修订：正常启动扫描未完成run并等待用户，History提供“继续本次识别”与“按当前设置重新识别”；前者复用原run/快照/cursor并新建session和当前目标，后者新建关联run。终态与交付结果未知的恢复分别处理。明确快照目录，加入真实重启入口及进程内首段调用次数断言。

## 定向复核：v3

`voxt_resume_final_review` 已实际完成fresh-context执行就绪复审：**0 Blocker / 0 Major / 0 Nit**。实读v3全文、persona/standard/AGENTS及AppCoordinator启动/两种Retry、RecoveryHistory持久化/启动修复、AudioRecorder落盘/停止。确认同run重启入口、快照/ledger持久化、当前编辑目标、新run保留原结果及交付未知分流都有明确实施与验收合同；必读材料齐备。

设计批评的v2有效覆盖保留；v3实质变化和直接依赖经上述定向复审，当前重要开放发现0。此结果为设计审视完成，生产质量/速度及安装版验收按正文执行。

## 当前交付状态

公开源调查、设计和相称独立评审完成；新增两份Markdown的本地链接与空白检查通过。模型下载、产品代码实现、构建、安装、F5交互及质量/速度采纳均属于后续批准后的执行。本轮只读核实安装版为0.5.1（110），收尾通过公开进程列表确认运行路径为`/Applications/ChatType.app/Contents/MacOS/ChatType`，保留已有运行态。
