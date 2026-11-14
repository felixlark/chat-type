# 识别质量与尾延迟设计：EGM处置

2026-11-10。目标：[设计正文](../recognition-quality-and-latency-design-2026-11-10.md)。本轮为设计，运行态保持。

## 独立审查与处置

| 来源/实质缺口 | 处置位置 | 最终结果 |
| --- | --- | --- |
| design critic：流式ASR只节省桥接A新增等待，R0慢润色仍在 | 10.1：R0速度/A0质量/A1成本、首delta/生成/重试与收益预算 | 定向复核闭合 |
| readiness：preview失败可阻断/截断WAV | 10.2：采集/预览失败分离、buffer所有权及三类故障 | 定向复核闭合 |
| readiness：词表快照、错拼召回和预算不确定 | 10.3：F5快照、普通Retry旧快照/History新快照、重点词优先及glossary保留 | 定向复核闭合 |
| readiness：正式网络错误Retry及B重放路径缺失 | 10.4：按错误映射、challenge有界策略、B同模型同地域显式重放 | 定向复核闭合 |
| readiness：写入路径/基线/恢复和A首验不固定 | 10.5/10.6：文件白名单、签名包备份与canonical恢复、18次质量候选集 | 定向复核闭合 |
| clock recheck：整文件基准未重现R0讲话期识别 | 10.7：文件质量/1×PCM ready/真实CU端到端三集 | 后续定向复核闭合 |
| receipt recheck：事件投递与实际全文出现的时钟不同 | 10.8：固定测试目标、只读观察回执、同源单调时钟/校准 | 最后定向复核闭合 |
| receipt recheck：afplay到F5停顿改变R0提前计算量 | 10.8：按实际采集WAV标注500–1500ms停顿、配对差≤250ms、超界保留补测 | 最后定向复核闭合 |

## 审阅实况与结论范围

- egm_quality_architecture：实读design_critic persona、feature-spec standard及方案/源码；首轮0 Blocker、1 Major、0 Nit。
- egm_quality_readiness：实读implementation_readiness persona、implementation-readiness standard及指定7份源码；首轮0/4/0。只读persona约束下，正文由主Agent按真实返回落盘归纳。
- egm_quality_recheck：两套persona/standard与直接依赖，已闭合首轮5项，发现实时供给Major1。
- egm_quality_clock_recheck：readiness persona/standard、BenchmarkRunner/LocalSpeechRecorder/AppCoordinator/TextInjector，实时供给主体闭合，发现实际插入/停顿Major2。
- egm_quality_receipt_recheck：readiness persona/standard全文、10.7/10.8、TextInjector1–245及coordinator停止/注入路径；最后剩余0/0/0。其他已闭合范围沿用。

所有reviewer为fresh-context原生代理，未读memory/旧chat、未改产品源码/配置或运行态。研究源文件按GitHub SHA固定，见正文来源节与本机Logs/ChatType/quality-design-20261110/research。

A及测量合同已具备方案定稿所需的实施细节；B/C/D需各自的产品数据流/权限/费用选择及具体模型协议后才进入实现。此审查没有产生音频质量/延迟通过结论，也没有改变已安装应用。
