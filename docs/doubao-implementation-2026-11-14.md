# 126 豆包接入实施与验收

2026-11-14。负责人：当前 ChatType 实施任务。用户批准按方案实施、保留 ChatGPT，并让用户逐阶段选择，默认使用豆包。基线为 `5a2f40d36e86fc924ca7d40e64a523c3b8a6f245`，规范 checkout 串行写入。

## 已实现的行为

- 全新配置默认豆包 ASR 与豆包整理。旧配置按原值解码，避免未经选择迁移；本机默认切换通过安装版设置保存并单独验收。
- Dictation 的六步提供实时预览、ASR 服务、Terms 对齐、润色及服务、Replacement 修正、粘贴或仅复制的独立控制。录音开始固定快照；重试沿用原快照。
- 保留 ChatGPT 原账户转写、macOS 26+ 本地预览和整段润色。ASR 与润色可混选；任一启用阶段需要 ChatGPT 才检查原登录。兼容 ASR、GLM/Qwen 保留独立凭据，不作为自动回退。
- 豆包实时路径从正在写入的 16 kHz PCM 文件连续读取，20 ms Opus 帧上传；停录后等待最终分段和 SessionFinished。原声始终单份本地保留，历史重放由 Core Audio 转换采样。
- 本机私有恢复库按 attempt 保留路线、ASR/部分结果、实际整理输入、每次整理输出、终稿和错误。处理中断与取消关闭云任务，失败不自动粘贴。原声校验与审计持久化先于输出；不确定是否已输出时要求先核对目标。
- 应用独立获取配置并存自身 Keychain；不导出浏览器或豆包输入法凭据。Opus 1.6.1 固定来源和 SHA，随应用签名分发并包含许可证。

## 审查与自动检查

两位 fresh-context 方案 reviewer 未报 Blocker/Major。两位代码 reviewer 共发现五个需修复问题：接收错误被取消遮蔽、无索引终稿重复、独立云任务漏取消、重试丢失失败阶段证据、旧润色标志阻止用户重新启用 ChatGPT。已修复并补回归。

fresh-context 定向复查五项均 PASS，Blocker/Major/Minor 均为 0。复查 manifest SHA-256 为 `c69d7fbb9c68c00b2439b8c998b9681cf384e8f78111ed11c8b4d472d9f9739e`，108/108 源码及测试文件哈希匹配；语义阅读限于受影响链路，不能解读为全仓逐文件审计。

修复后 canonical `scripts/check.sh` 返回 0：322 项 Swift、34 项工具测试通过，策略、落地页合同和打包元数据检查通过。签名包带 Opus 动态库及许可证；安装到 `/Applications/ChatType.app` 后 deep/strict 验签通过，版本 0.6.0（126）。单元与协议模拟不代表麦克风、TCC、全局热键或安装版验收。

## 真实服务证据

证据目录：`/Users/longbiao/Library/Logs/ChatType/doubao-implementation/20261114/`，原声及 harness 位于 Library/Caches，均非仓库数据。

`service-multivad-probe.json` 使用真实实现和新生成的三段合成语音，完整配置 → TaskStarted → SessionStarted → 多个索引终稿 → SessionFinished → SSE completed/done 成功，约 22.9 秒。凭据注入内存存储，未访问真实 Keychain。这证明文件业务链路可用，不代表安装版实时麦克风验收。

“只校对”被 ASR 识别为“支教队”；原文保留该错误，未加替换规则掩盖。豆包整理重排了段落，不能据此宣称质量优于 ChatGPT。早先一次上游 `40200011` 的原因未证实；同一 app_name 的后续成功推翻了“名称必然不被接受”的假设。

增长文件探测首次返回 `50700000 / service discovery failure`，在 SessionStarted 后、音频结果前由后端拒绝。应用保留真实错误，不把它归为用户取消；这次失败本身不能判断增长文件读取是否可用。编译失败后误用旧 harness 的一次输出另标记为 `service-growing-stale-harness-invalid.json`，排除在有效验收之外。

一次明确重试 `service-growing-probe-retry.json` 成功；20 条文字结果消息中有 15 条在文件封口前收到，随后完整分段终稿、SessionFinished 和 SSE 整理均完成。总探测约 27.1 秒，包含 15.6 秒合成语音的按帧写入与调度开销；不用于宣称真实用户停录延迟或速度优势。

安装版通过 LaunchServices 对新生成的同一受控语音分别验证三条完整文件流程：ChatGPT ASR＋豆包整理、豆包 ASR＋ChatGPT 润色、豆包 ASR＋豆包整理，均为 1/1 成功。逐阶段输入/输出和 provider 写入 `installed-*-*.log`；这也验证已签名安装版加载随包 Opus 与应用自身凭据，而非开发缓存。保留“只校对”识别错误；两个 ASR 均未准确识别该短语，不能从该样本推出广泛质量比较。

安装版 Dictation 的 Voice/Align/Correct/Paste 控件逐一切换并恢复，ASR 与 Polish 分别混选保存后读回；进程重启后仍显示 ChatGPT ASR＋豆包整理。最后通过界面保存为豆包 ASR＋豆包整理，实时预览、术语对齐、润色和纠错开启，自动粘贴保留原设置。原模型 `gpt-6.1-terra` 与原账户未更换。前后界面截图和每个开关的 AX 状态另存私有证据目录；产品名、图标、颜色及原五页导航保留。

用户要求继续后的安装版全豆包重试再次 1/1 成功。canonical visual acceptance 覆盖录音、处理、结果、错误、可重试错误五个 HUD demo 状态并通过；它只证明显示状态，不等同于真实麦克风或错误重试交互。脚本随后恢复正常菜单栏运行。当前 KVM 会话已读回，现持有人确认 HDMI/USB 仍物理接 Janus、没有已验证的远程切到 Mac 硬件路径；没有向错误电脑发键。实体 F5 录音与跨应用注入尚无本轮证据。

CI 与手动构建说明补齐 Opus 准备步骤，避免全新 runner 直接跑 Swift 测试时缺少库；本机 cache 成功不代替远端 CI 结果。

## 交付门槛

| 门槛 | 当前证据 |
| --- | --- |
| implemented | 已实现，见上文 |
| checked | canonical check 0；322 Swift、34 工具项通过 |
| packaged | 0.6.0（126），嵌套库与 app deep/strict 验签通过 |
| installed | 已装 `/Applications/ChatType.app`；125 与原配置备份保留 |
| live accepted | 阶段控件、混选持久化及三条安装版文件业务流通过；真实 F5 麦克风、取消/重试、注入待验 |
| left running | 正常菜单栏进程保留，最终关闭前再核对 |

本记录不构成公开发布、第三方协议授权或免费承诺。私有端点稳定性、长期配置有效期、云端热词和广泛质量提升均未证实。
