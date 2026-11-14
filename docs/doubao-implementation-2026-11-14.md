# 豆包接入实施与验收（当前 127）

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

## 127 实机缺陷修复与恢复

继续验收后，远端首轮 CI 暴露了一项 preflight 测试直接读取本机 Keychain 的问题。本机已有登录掩盖了缺口；已注入账户状态并明确区分兼容 ASR 单独凭据、兼容 ASR＋ChatGPT 润色的两套凭据。修复提交 `486a319` 的远端 CI [43574533862](https://github.com/felixlark/chat-type/actions/runs/43574533862)通过，323 项测试。此结果不替代后续候选的 CI。

正常安装版随后产生了一条 18.821 秒的真实麦克风录音，ASR 完成而整理失败。另用自生成短句抓到真实 SSE：`scene.delta` 带 `no_rewrite=true` 和空 content，`scene.completed` 空 content，随后 `done/[DONE]`。它表示无需改写；旧客户端一律拒绝空完成结果，导致误报失败。127 只在明确标志、无 delta 文字、空 completed、两个完成信号齐全且原文非空时接受保持原文；断流、无标志空结果、部分输出仍失败。不增加自动服务回退。

两个解析层均已修复，独立新上下文复审无阻塞发现。325 项 Swift、34 项工具测试及 canonical check 全部通过；真实生产 HTTP 字节流返回原文且 `applied=false`。127 已重新打包、签名验证并安装到正式路径。安装前确认没有正在录音或处理的会话，保留 125/126 回退包及所有原声。

在 127 中通过 History 对上述实录重试，追加第二次 attempt，最终记录为 `pasted`；原失败 attempt、ASR/整理输入/输出/终稿与原声 SHA 全部保留。这证明真实麦克风业务恢复及产品输出动作完成，单独的 `pasted` 回执不能证明目标输入框可见文字。隐私证据仅在本机保存元数据，不把该录音或文字提交到 Git。

自生成 15.6 秒历史录音的安装版 GUI 验证还覆盖了：成功后剪贴板保留、真实上游 `50700000` 错误、点击 HUD Retry 后成功；三次 attempt 沿用同一原声 SHA、同一豆包路线，旧失败不被覆盖。系统剪贴板临时保护仅存进程内存；结束时发现已被另一来源修改，保留当前值，未覆盖用户新内容。

用户另有 F5/Fn 快捷键排障任务。GUI/安装/键鼠现场在安全点交给原任务 `01a1d925-5345-71a0-a30c-0bfca82f861e`；本任务没有发送 F5、Fn、ESC 或 KVM HID，也不把其他来源的新录音推断成已独立验清所有实体键位。该任务负责热键冲突与相应现场读回，这里继续负责豆包源码、CI及恢复证据。

此次提前收尾的失误有三项：没有等远端 CI 读回；以最小长句样本替代短句成功语义覆盖；把 PR 工具的表单中间态扩大成整项停止点。现已分别以干净环境回归、真实 SSE 短句探测与修复、官方 CLI 写入并读回 PR 信息纠正。后续结案只依据实际候选和各自覆盖的证据，不把“诚实列出缺口”当成停止动作。

## 最终安装版验收回执

127 生产源码候选 `4557b92` 的远端 CI [43575791105](https://github.com/felixlark/chat-type/actions/runs/43575791105)通过，325 项 Swift 测试；本地完整检查另含 34 项工具测试。下述补充只更新验收文档，不改变已安装二进制；最终 PR head 的远端检查另行读回。

快捷键任务在用户实体测试后交回现场：F5 只唤起 ChatType，Fn 只唤起豆包，Esc 取消已实际操作。按用户决定，本机 Karabiner 将实体 F5 转成独立 F18，ChatType 保存 `hotkeyKeyCode=79`，豆包仍为 Fn；产品默认及操作习惯仍为 F5 开始/停止。本机后续保存配置须保留 79，不能用通用默认值 96 覆盖。无产品源码热键改动；独立任务的本地证据为 `~/Library/Logs/ChatType/f5-fn-20261114/result.json`。

随后在同一 127 安装版完成两项界面验收：受控短语从 History 处理后，TextEdit 自建草稿实际包含完整终稿；处理中的浮层 × 通过官方 Computer Use 点击，状态变为 cancelled，原声 SHA 不变。取消后再次处理成功，阶段完整留存。工具在按钮动作令控件消失时曾返回点击失败；以新界面、取消记录及无重复点击的读回裁定，未盲目重放。此前 `50700000` 错误后的 HUD Retry 也已真实成功，三次独立 attempt 及同一音频均保留。

最后用户在 `final-f5-target.txt` 上用实体 F5 开始，说指定测试句，再按 F5 停录，并明确回复“已出现文字”。本地独立读回证实：新增 2.287 秒麦克风原声，识别/润色均为豆包，内部键码 79；ASR、整理输入/输出、终稿非空，状态 pasted，原声 SHA 匹配；目标 TextEdit 窗口实际包含该条完整终稿。证据分别为 `final-f5-physical-result.json`、`final-f5-visible-check.json`，均在本机私有证据目录。

受控测试用的剪贴板已恢复；最终用户实录的正常输出保留。没有向错误电脑发送 HID，没有导出凭据或上传私人验收录音到 Git。结束保持正式安装版正常运行，保留豆包默认及原 ChatGPT 登录/模型；PR 交付审阅，不自合并或公开发版。

## 交付门槛

| 门槛 | 当前证据 |
| --- | --- |
| implemented | 已实现，见上文 |
| checked | 127 canonical check 0；325 Swift、34 工具项通过；远端结果按 PR 当前 head 读回 |
| packaged | 0.6.0（127），嵌套库与 app deep/strict 验签通过 |
| installed | 已装 `/Applications/ChatType.app`；125/126 与原配置备份保留 |
| live accepted | 阶段选择/混选持久化、三种云端组合、实体 F5 开停、Fn 分离、Esc/×取消、错误后 Retry、取消后重入、原声/阶段留档及 TextEdit 可见终稿通过 |
| left running | 127 正常进程保留；已读回豆包默认及本机键码 79，不改回已修复的映射 |

本记录不构成公开发布、第三方协议授权或免费承诺。私有端点稳定性、长期配置有效期、云端热词和广泛质量提升均未证实。
