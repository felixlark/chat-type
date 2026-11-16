# 本机通讯录报告 111：实施与验收记录

> Historical evidence for the date/build recorded below. Current requirements: [PRODUCT](../PRODUCT.md).

2026-11-10，Mac M1 Max / 64 GiB、macOS 27.2。用户批准的首批实施：本机报告、分层姓名清单和离线对照；真实转写不切换，联系人实体不写入。

## 交付与边界

0.5.1（111）已通过 scripts/check.sh 全量 274 项测试及策略/打包检查，已安装到 /Applications/ChatType.app。通过 LaunchServices 独立进程运行 contacts-report，复用已有 Contacts 授权，退出后正常启动菜单栏应用。签名 designated requirement、Bundle ID、entitlement 与干净110一致；报告入口未请求新权限或初始化认证/模型，代码没有联系人保存请求。未使用 Computer Use、云服务或私有通讯录数据库。

正式路径原生验收通过的是报告生成、关联展示结构、文件权限、原词保留和只读边界。未进行新的真人 F5 测试，也未启用分层检索；本次不是姓名识别修复验收。原模型 gpt-5.6-terra、ChatGPT Auth、17,674 项词库、3 个重点词以及整段润色保持，配置从实施前到正常启动后逐字节一致。全部旧标准字形/别名及三个已确认姓名在新清单中保留，旧纠正映射仍在原配置。

## 当前原生口径

09:46:47 UTC（北京时间17:46:47）读取：原始卡片9,215，统一显示卡片8,927，个人8,669、组织258；同名候选65组，同昵称候选77组。候选报告逐原卡列出统一卡片标识、原始卡片标识和该原卡来源；同名不视为同一身份，未知关联明确标注。

旧 Apple 来源在当前姓名/昵称投影中缺席619项；它们均保留。当前原生投影相对于全部来源的标准字形和别名，未覆盖66项。此前8,685是Apple来源标签差集，不能当作全部词库缺词数。

新清单23,652个归一化字形，角色允许重叠：姓名8,590、昵称6,546、机构1,102、通用词215、待核16,814。数量增加来自原始字段、来源和别名保留，不代表又增加了相同数量的联系人。机构独占标准字形及其已有别名从离线姓名池排除，其通用术语记录仍保留；未把旧词任意归为真实姓名。

## 离线对照及采用决定

两池均沿原 PersonalNameHints 匹配规则；每例预热后5轮中位数。以下毫秒仅为本机 Swift 调试安装版 utility 队列下的姓名查询，不含ASR、网络、润色、粘贴，也不是交互耗时保证。该批仅4例，不构成通用准确率结论。

| 本机样本 | 原池命中 | 新池命中 | 候选数 原/新 | 暖查询中位ms 原/新 |
| --- | ---: | ---: | ---: | ---: |
| 问题样本 | 1/3 | 1/3 | 4 / 4 | 67.0 / 741.4 |
| 原成功样本 | 3/3 | 3/3 | 3 / 3 | 66.2 / 143.3 |
| 时间/预算负例 | 0/0 | 0/0 | 1 / 1 | 78.1 / 731.3 |
| 设置/范围负例 | 0/0 | 0/0 | 1 / 1 | 73.9 / 903.2 |

负例预期姓名为0，命中0/0仅表示没有预期目标；候选数各为1说明原规则和新清单仍会建议无关姓名，不能记为负例通过。候选尚未发送模型或插入文本。问题样本仍只命中1/3，原成功样本两池均3/3；本次分层查询更慢，未达到采用门槛。新清单保持离线，真实转写继续原池；近音召回与性能仍待独立设计和验收，未追加重点词、放宽匹配或更换模型。

## 本机证据

私有报告目录0700，8个文件均0600，HTML转义字段、无脚本、CSP禁止外部资源。报告和清单含真实个人数据，仅供本人本机核对，不作为云评审或评测输入。

- [本机候选报告](</Users/longbiao/Library/Application Support/ChatType/ContactsReports/Report-0262413A-5E0A-4113-8734-E90CB26271C6/index.html>)
- [匿名原生汇总](</Users/longbiao/Library/Application Support/ChatType/contacts-report-111/report.stdout>)
- [274项检查与打包记录](</Users/longbiao/Library/Application Support/ChatType/contacts-report-111/check-final.log>)
- [签名、安装和配置回执](</Users/longbiao/Library/Application Support/ChatType/contacts-report-111/install-receipt.json>)
- [正式路径验收与正常运行回执](</Users/longbiao/Library/Application Support/ChatType/contacts-report-111/acceptance-receipt.json>)
- [EGM审读记录](https://github.com/felixlark/chat-type/blob/5350f037b3782e875f0f23e8cb8421fddcdedcac/docs/reviews/contacts-report-111-2026-11-10.md)

实现、检查、打包、安装、本机报告原生验收均完成；生成后的正常运行PID13358。联系人合并/删除0，生产清单启用0，真人姓名识别修复验收未进行。并行Voxt路线由另一个已授权项目chat负责，此回执只描述111交付现场。
