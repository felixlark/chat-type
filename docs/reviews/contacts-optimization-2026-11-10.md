# 通讯录优化方案：EGM评审回执

2026-11-10。候选：[通讯录与识别词库优化方案](../contacts-optimization-2026-11-10.md)。用户范围为本机Apple接口调查和设计，联系人写入/词库切换待单独批准。按本机GSE技能的EGM合同执行独立审读；只向reviewer提供代码和匿名计数。

## 结果

| 审读范围 | 独立reviewer | 实际结论 |
| --- | --- | --- |
| 只读采集入口执行就绪 | egm_contacts_audit_readiness | 初审3 Major：配置写回、离线范围、默认路径 |
| 上述修订定向复核 | fresh-context egm_contacts_audit_recheck | 0 Blocker / 0 Major，采集字段与恢复路径通过 |
| 优化方案执行就绪 | fresh-context egm_contacts_optimization_readiness | 0 Blocker / 0 Major / 0 Nit |
| 优化方案设计批评 | fresh-context egm_contacts_design_critic | 0 Blocker / 0 Major / 2 Nit |
| 两项证据补强定向核对 | egm_contacts_design_critic | 两项闭合，剩余0 / 0 / 0 |

采集入口修订为main最前分流，独立最小只读解码，早于配置保存和认证管理器；使用已有本机锁定依赖、离线签名、显式路径；退出审计后恢复干净110与既有正常功能。主Agent实际运行267项检查、原生匿名统计及恢复读回，配置字节一致，联系人写入0。

设计评审两条Nit分别补齐：45次本地查询的轮数、编译/预热/计时端点及冷启动未测范围；匿名T2/T3的音节/字形差异与最早拒绝规则。成对规则核对与完整查询结果分列，避免扩大证据范围。

## 实读与隔离

两名优化方案reviewer实读方案全文、GSE评审标准、原生计数/规模对照/恢复3份匿名JSON及PersonalNameHints、TerminologyPolicy、TerminologyImporters源码；定向复核另读取匿名音近门槛回执。采集入口reviewer实读相关main/AppDelegate/ConfigStore/依赖/打包安装路径。

所有reviewer均fresh-context起步并只读；个人配置、联系人原文/标识/数据库、音频、Keychain、memory和旧chat未提供且未读取，网络/GUI/构建/写入均0。宿主未强制文件系统只读，实际只读依本轮行为约束。独立reviewer的运行模型ID及token数据未由工具回传，记未知；产品模型仍为已读回的gpt-5.6-terra。

评审结论适用于调查结果与待采用设计。当前身份重复判定未完成，65组属于同名候选；本轮合并、删除、重点词调整及模型切换执行量均0。后续报告、姓名视图和原生写入按方案各自门槛推进。
