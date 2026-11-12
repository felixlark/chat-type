# Voxt P1 实现审查

本记录归属 CT-VOXT-20261110，评审范围为实验运行时、模型下载及文件质量对照；生产本地分段尚未实现。所有 reviewer 均使用宿主子代理、独立上下文，只读共享 checkout；工具未强制文件系统只读，执行合同禁止写入、安装及访问个人词库/通讯录。模型档位继承，工具未提供可核验模型 ID 或总 token。

| 评审 | 发现与裁决 | 验证/状态 |
| --- | --- | --- |
| omni_runtime_security_review | 重复写入 rpath；完整 partial 遇到416无法发布 | 移除重复 rpath；完整 partial先本地校验发布，坏文件重取、416恢复。下载器4项测试及真实HTTP/WS鉴权探针通过 |
| omni_p1_evaluation_review | 重放时钟混用；捕获失败中断整批；任意配置可能触发未获批付费provider；模型顺序按整批运行 | 分开filePipelineMs/postprocessReplayMs；asr-failed单列并继续；managed+ChatGPT Auth在读取凭据前强制校验；新实验默认同文件AB/BA交错，早期batch数据仅作探索质量 |
| omni_p1_evaluation_recheck | 上述四项关闭；新发现模型启动失败未计入样本行 | row在启动前创建，启动失败按样本记录，条件性回收；模型2×轮次2的故障分母测试通过 |
| omni_quality_guard_review | P2：identity correction出现次数强等与后续口述改口冲突 | 接受发现；移除输出次数/存在性拒绝，提示只保护保留内容中的字面拼写，后续改口优先 |
| omni_literal_guard_recheck | identity提示定向复核无可确认P1/P2 | 实读TextPolisher、VocabularyIndex、ProtectedPolishLiteralTests、Pipeline、TerminologyEntry及AGENTS；确认后续改口不再触发次数回退，correction原拼写能命中带空格ASR。源码审查完成，模型实际效果由独立质量运行验收 |

117 canonical检查279项通过，包括真实网络边界注入的改口回归；policy、landing及签名包metadata通过。Python工具11项通过。评测和基础设施实现审查已完成；候选语料参考、英文输出目标、完整质量门槛与正式分段/安装版新路线验收保持各自状态，审查通过单独记录。

117边界复核（omni_correction_boundary_review）：独立只读实读Normalizer的correctionRules/applyExactRules/protectedLiteralRanges和correctionPattern、ProtectedPolishLiteralTests及AGENTS，无可确认P1/P2。最终修复在原规范化阶段处理ASCII纠错项的分隔差异，词表试验改动已撤回；原有路径/反引号保护与词边界继续有效。源码审查通过与整体质量验收分别登记。
