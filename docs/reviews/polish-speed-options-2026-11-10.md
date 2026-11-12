# 润色加速研究：EGM审查结果

2026-11-10。目标：[方案正文](../polish-speed-options-2026-11-10.md)。仅研究与评审，产品源码、默认、凭据和运行态保持。

## 实读审查与处置

- fresh-context egm_polish_speed_critic实读design_critic persona/feature-spec standard、研究稿、指定源码、既有Qwen配对文档和本地计时元数据。0 Blocker/1 Major/0 Nit：旧38是重复请求数，独立输入仅10条。现改10+8=18独立输入×5轮=90次/模型，两候选180次；费用同步约¥0.54（1000入/300出示例），试验上限建议¥5，尚未发生调用或费用。
- fresh-context egm_polish_speed_readiness实读readiness persona/standard、当前稿、直接计时代码及offline-profile.json。0/2/1：缓存多线程发布、A音频配对/两级attempt口径待定、文件/测试清单未完全展开。已指定同一NSLock覆盖校验/构建/完整快照发布、强持数组的CoW身份与旧新Retry交错；补足至少30对暖态+独立冷态音频协议、文件prepare→最终文本ready端点、真人F5范围分列、两级attempt及unknown字段；写明精确源码和测试路径。
- fresh-context egm_polish_speed_recheck实读当前稿与直接依赖，定向复核上述三项Major及相关Nit，剩余0/0/0。其他已闭合范围沿用，无重复全量评审。

所有reviewer均只读，不访问真实配置/通讯录/录音/Keychain/memory/旧chat，不操作GUI、不运行构建或收费接口。初审材料中外部最新模型/价格以主Agent实读的官方源为依据，reviewer未冒称在线实测。

## 结论边界

推荐先做A（同模型/同提示/同词库结果的本地派生数据缓存），再单独验收新代际Qwen候选。两处离线热点合计约1.7秒是当前表达式profile观测；未来真实节省量、线上完整completion、F5到粘贴收益仍需方案规定的候选证据。公开OpenAI平台的缓存/预测输出与当前私有ChatGPT账户后端的能力分开核实。

现已完成研究、离线只读测量与EGM复核。当前109及gpt-5.6-terra保持，未调用新候选、未切换默认、未新增付费或数据目的地。

## A实施复核

Longbiao批准A后，fresh-context `egm_cache_a_implementation`实读readiness persona/standard、批准合同和缓存/计时/测试源码，初审0 Blocker / 0 Major / 1 Nit。缓存强持源数组、identity+count+locale、同一NSLock构建/发布、动态priorities、旧新快照及两级attempt均通过；Nit要求UTF-8字节比较与ASR600字符边界。

补齐108组合逐条role/content字节等价和11个截断边界后，定向复核0/0/0。随后复核最终清除的临时oracle分支，以及缺少流式Content-Type时的被动字节流计时observer，Major为0；读取原字节和结束条件保持。267项测试由主Agent执行通过，reviewer只读且未冒称执行。

冷态计时起点在pipeline构造前，包含求prioritizedHintTerms时触发的首次index构建；暖态30对与冷态每文件新进程10对分别报告。完整执行、既有合成ASR误识别和现场验收见[110记录](../polish-cache-a-delivery-2026-11-10.md)。
