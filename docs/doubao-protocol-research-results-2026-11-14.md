# 豆包输入法协议调研：实测结果与接入边界

> Historical evidence for the date/build recorded below. Current requirements: [PRODUCT](../PRODUCT.md).

后续状态：用户在本报告完成后批准产品实施与豆包默认，126 已进入安装验收，见[实施记录](doubao-implementation-2026-11-14.md)。本报告保留调研时点的质量与覆盖结论。

2026-11-14；范围是分析引擎配置、协议调查、隔离工具重放与方案更新，未实施 ChatType 产品接入。

## 结论

**协议层已取得可复用的最小完整路径：配置取 ASR 凭据 → WebSocket 识别自有音频 → 独立 SSE 文字整理。** 两次完整 ASR 会话、一次主动中断后重放及独立整理已实测；有一份原声 SHA 连到真实 ASR 再连到整理结果。本轮没有使用用户的豆包登录 token、浏览器 Cookie、ChatGPT 凭据或历史私人录音。

这是后端可行性证明，不能等同于正式产品通过验收。样本只有一条本地合成语音，识别把“只讨论”写成“之讨论”，接续整理未充分清除旧时间与改口，质量门槛尚未通过。热词生效、长语音跨 VAD 合并、真实麦克风中断、凭据过期和长期服务条件仍需验证。

完整证据位于[本轮日志目录](</Users/longbiao/Library/Logs/ChatType/doubao-research/20261114/>)；工具源码位于[隔离研究目录](</Users/longbiao/Library/Application Support/ChatType/DoubaoResearch/>)，没有写入产品 Sources。

## 研究对象与证据等级

- 本机对象：`/Library/Input Methods/DoubaoIme.app`，1.1.0(1)，bundle ID `com.bytedance.inputmethod.doubaoime`。原可执行文件 SHA-256：`5b48748fa6394811cba0f8c05905ffebb9a2cd02faf6d47b26deb3d9b86247e0`。
- REA 的 Ghidra 路线要求 thin Mach-O。使用 Apple `lipo` 在研究缓存中拆出 arm64，SHA-256：`a6a3ac886111eda4bb271ddfd37769fd94ecdd57d04112d77a60e32d74e36cbf`；未修改安装包。
- **静态证据**包括本机常量、Apple 工具的反汇编、字符串引用候选及第三方公开源码；它们不证明某次原客户端实际联网。
- **运行证据**来自本轮隔离重放工具的真实服务应答。它证明当前请求可用，不证明原客户端的所有版本／登录模式都采用同样请求。
- AID `685343` 来自安装包字面量线索；配置服务为它返回 ASR 配置，识别服务接受了该 AID 与新研究标识。本轮未捕获原客户端的实际 URL query，故不把它称为原客户端全部通信的精确还原。

## 分析引擎

安装 REA 6.9.0 支持的 Ghidra 12.1.4，来自[NSA 官方发行](https://github.com/NationalSecurityAgency/ghidra/releases/tag/Ghidra_12.1.4_build)。归档 SHA-256 与官方 asset digest 一致：`ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db`。

该归档只附 Linux／Windows 原生反编译器，故用**同一归档内的 C++ 源码**编译 `mac_arm_64/decompile`；复用已安装 JDK 21.0.12.1。没有安装收费引擎、接受新许可对话框、修改系统代理或新增敏感权限。REA scoped setup 已把引擎路径和 JAVA_HOME 写入原 Codex REA 注册并保留恢复备份。

doctor 的引擎、架构、原生组件、Java 与注册检查均通过；另以独立 Mach-O 小函数完成真实反编译，得到 `return param_1 * 3 + 7`，证据 `ev_57c11a28f957214e6d0b9d293f4017d2e7286167716f940d337a0d836fb5f819`。该探针只验证引擎执行能力，不能冒充豆包函数分析。

豆包整个主程序的默认分析出现 330 秒 provider 超时；扩大到 900 秒后，客户端请求也到达期限。日志有 `ObjcMessageAnalyzer.findMessages` 数组越界异常，未确认内存不足。随后按线程证据缩减本目标的全局推断：在独立研究进程中关闭 `Objective-C Message Analyzer`、`Demangler Swift`、`Decompiler Switch Analysis`、`Call Convention ID` 及与覆盖配置不兼容的 checkpoint。两次中间尝试由研究者主动停止、核对清理后重启，不能记成自然超时。没有改变全局引擎默认配置。

**最终配置已在豆包本体通过：分析 240 秒，含请求开销约 249.8 秒，取得 `0x100c8bc5c` 请求构造函数的完整反编译文本（3,251 UTF-16 单元），另取得域名访问函数 `0x100bf1a38` 返回全局地址的结果。** 原始反编译 Evidence 为 `ev_2a65ffc1183b9596a8c4327ae9552baab8b55b8b2b17284da547507078ae93b2`；见 [REA 导出包](</Users/longbiao/Library/Logs/ChatType/doubao-research/20261114/rea-doubao-evidence.json>)及 `ghidra-target-profile-final.json`。它与 Apple 反汇编共同支撑五字段整理请求，不是只做小函数探针。

覆盖仍有限：关闭上述分析器会减少 Swift 类型／调用约定、动态分支和 Objective-C 消息引用的恢复；其他函数出现 VarnodeContext 错误，伪代码也有未恢复的 Swift 寄存器语义，不能当作原源码或完整程序还原。所需四条 Evidence 已导出；最终 REA 状态 `open=false / cleanup_pending=false`，本轮客户端正常关闭，没有留下分析进程。

安装与执行证据：[engine-manifest.json](</Users/longbiao/Library/Logs/ChatType/doubao-research/20261114/engine-manifest.json>)、`ghidra-doctor-ready.json`、`engine-functional-probe-address.json`。当前 chat 在本轮开始时已能发现 REA；引擎新环境由同包官方 MCP SDK／stdio 连接实际加载，未要求重启用户桌面。

## 三条不同的认证／传输链

### 1. ASR 的 Odin／配置凭据：本轮真实识别采用此路

配置请求为 GET `https://is.snssdk.com/service/settings/v3/`。研究请求使用 AID、mac 平台和版本等应用参数，没有携带用户设备 ID、账户登录态或 Cookie；响应含 `data.settings.asr_config.app_key`。值仅写入本轮专用 Keychain 条目，未写入源码、日志或配置。

随后连接 `wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws`，query 包含 `aid` 和每次新生成的研究标识 `device_id`。该标识没有冒充用户已有设备，也未声称已通过设备注册；本次服务实际接受了它。headers 包含 `proto-version: v2` 和 `x-custom-keepalive: true`，UA 明确标识研究客户端。

请求 Protobuf 字段号为 `token=2`、`service_name=3`、`method_name=5`、`payload=6`、`audio_data=7`、`request_id=8`、`frame_state=9`。这一结构与[Python 固定提交 proto](https://github.com/yangmoling/doubaoime-asr/blob/267972f815f519fd7c6149f85a8b7cc99daf61a5/doubaoime_asr/asr.proto)及 VoxType 编码相符，并被本次服务接受。

实际状态顺序：StartTask → TaskStarted → StartSession → SessionStarted → TaskRequest 音频帧 → FinishSession → SessionFinished。成功状态码为 `20000000`。音频采用 `speech_opus`、16 kHz、单声道、20 ms 帧；首帧 1、中间帧 3、末帧 9。

这次已成功请求的最小会话合同如下，不能据此宣称所有字段都是必需字段或原 Mac 客户端的完整 schema：

| 方法／响应 | 本轮发送或等待的内容 |
| --- | --- |
| StartTask | Protobuf 中携带配置 key、service_name=`ASR`、method_name 和本次 request_id；无 JSON payload |
| TaskStarted | 等到该响应且未收到失败后才发 StartSession |
| StartSession | JSON `audio_info={channel:1,format:"speech_opus",sample_rate:16000}`；enable_punctuation=true、enable_speech_rejection=false；extra 包含明确的研究 app_name、新研究 did、cell_compress_rate=8、enable_asr_threepass=true、enable_asr_twopass=true、input_mode=`tool` |
| SessionStarted | 收到后才上传音频 |
| TaskRequest | audio_data 为单个 Opus 帧；JSON payload 为 `extra={}`、timestamp_ms 从 0 按 20 递增；按实时节奏发送 |
| FinishSession | 所有音频帧发完后发送；本轮无 JSON payload |
| SessionFinished | 终止本次识别阶段；此前收到的 interim 只供预览 |

响应的 request_id、task_id、service_name、message_type、status_code、status_message、result 分别位于字段 1—7；status_code 为 varint，其他为长度限定字段。请求除 frame_state 为 varint 外，上述字段均为长度限定字段。隔离工具未保存带凭据的原始发送包，保留的是编解码源码、非敏感应答投影及音频 SHA 关联。

结果在响应字段 7 的 JSON 中，包含 `results[*].text`、`is_interim`、`is_vad_finished` 等。本条样本只有一个最终 VAD 结果；**VAD 结束不等于整个录音会话结束**，本次还等到 SessionFinished 才提交下一阶段。不能把此单段脚本直接拿去合并长录音的多个 final。

### 2. SAMI 配置 token：另行证明可取得，不能与 ASR 配置 key 混称

本机 `SAMITokenManager` 反汇编可见 POST `https://ime.oceancloudapi.com/api/v1/user/get_config`，JSON body 为 `sami_app_key`，Content-Type 为 application/json。分发包中的应用常量在研究进程内读取，未输出其值；响应 `code=0`，含 `data.sami_token`，已存本轮 Keychain。

此 token 未用于成功的 ASR 重放。首次仅带 SAMI token、缺少应用／设备 query 的 WS 探测返回 `SessionFailed / 40200001 / session auth, userID or appID is empty`；这不能据以判定 SAMI token 自身无效，也不能据以把二者当成同一种凭据。

### 3. 独立文字整理：本轮得到匿名、无 Cookie 的有效 SSE 响应

本机地址 `0x100c8bc5c` 附近的构造代码引用 `/api/v2/ai/text_organization`；调用 `0x100bf1a38` 取得的全局 Swift 字符串为 `https://ime.doubao.com`。请求采用 JSON，Accept 为 text/event-stream；Apple 反汇编与本轮 REA 反编译交叉核对五个字段，实际请求如下：

```json
{
  "query": "待整理的转写文本",
  "scene": 6,
  "stream": true,
  "space_at_cn_en_nb": 0,
  "space_at_newline": 0
}
```

本轮实际 POST 的完整 URL 为 `https://ime.doubao.com/api/v2/ai/text_organization`。空 body 返回 HTTP 200／业务 code 400，并提示 scene 仅支持文字整理。按上述 schema 请求，得到 scene.delta、scene.completed、done，且完成内容为可读 JSON。两项 spacing 字段本次成功请求使用整数；改成布尔值的探针只拿到 JSON 响应、未取得整理结果，其业务错误正文未被保留，不能补造错误原因。

本轮成功整理未发送账户 token、Cookie、SAMI token、设备 ID 或 Wave 加密握手。响应含 `X-Tt-E-B: 1`，但 urllib 读到的是可解析的明文 SSE JSON，因此不能仅凭此 header 宣称 payload 已加密。HTTPS 仍保护传输；本结果也不能推出其他模式永远无需认证或永远免费。

原客户端还包含 `WaveBDMSManager`、`encryptionValidated` 与加密失败路径。第三方 npm 发布物实现了 SAMI + Wave 握手 + **NER（命名实体识别）**，其 `/api/v3/context/ime/ner` 不等于文字整理。本次成功重放不依赖 NER，也未为复用协议安装根证书、截获用户会话或绕过挑战。

## 完整重放与质量结果

本地系统语音生成新测试音频，没有播放到扬声器或采集麦克风。音频长度 7,238 ms，WAV SHA-256 为 `cb7048dc76d9415a03a08f5e099b623c9de44e027255b70f273257a16c197ada`。经本机 libopus 编为 362 帧，全部音频编码载荷共 16,933 字节。

| 检查 | 本轮实际结果 |
| --- | --- |
| 新会话完整 ASR | TaskStarted、SessionStarted、最终文本、SessionFinished 均取得 |
| 凭据跨进程复用 | 新进程只读本轮 Keychain，不刷新 settings，再次完成完整 ASR |
| 中断再重放 | 发送 25 帧后主动关闭本次传输，本地 WAV 保留；随后新进程完整重放同一 SHA 成功。它是客户端取消／新会话重放实验，不是物理断网或服务端断点续传证明 |
| 独立整理正例 | 人工文字样本正确移除了旧时间和改口，并保留否定要求；见独立的 organization-controlled-text-result.json |
| ASR → 整理完整链 | 下一请求的 query 与真实 ASR 文本完全一致，取得 scene.completed 与 done |
| 质量采纳 | 未通过；本样本包含识别偏差与未充分清理的改口，不切换默认 |

完整链路的真实 ASR：

```text
嗯，明天上午 10 点开会，不对，改成下午 3 点之讨论接口，不要安排其他事项。
```

直接交给豆包整理的终稿：

```text
明天上午10点开会，不对，改成下午3点讨论接口，不要安排其他事项。
```

这里丢失了“只讨论”的明确范围，且保留旧时间与“不对”。与纯文字正例不同，不能把这条结果判为保真通过，也不能用协议成功代替质量验证。

首个 ASR 探针总时长 10,881 ms，包含配置、编码、按实时节奏上传与接收；接续整理请求 647 ms。它们不是安装版 F5→粘贴时间，不能直接与旧产品对照表比较或宣称提速比例。

主要证据：[full-chain-result.json](</Users/longbiao/Library/Logs/ChatType/doubao-research/20261114/full-chain-result.json>)、`asr-file-result.json`、`asr-cached-file-result.json`、`asr-cancel-result.json`、`organization-from-asr-result.json`。独立文字正例的初始文件曾被完整链探针覆盖，现从本任务原始工具回执恢复到 [organization-controlled-text-result.json](</Users/longbiao/Library/Logs/ChatType/doubao-research/20261114/organization-controlled-text-result.json>)，保留原回执关联；没有为补证重新请求服务。取消记录曾把总编码字节标为上传字节，已纠正为 encoded_audio_bytes_total；该次实际发送字节未计量，保留为未知，不能宣称已上传整段。

## 热词、上下文与来源限制

本机可见 ASRContext.HotwordContext 及 hotwordsInfo，说明客户端具有相关结构，但本轮未证明自定义词表可有效注入云端。VoxType 的[上下文结构说明](https://github.com/melody0709/VoxType/blob/1b0516b7fddf547cb8ba923e848c41ab1be96416/src/asr/doubao_ime_context.h#L5-L40)恢复了 `extra.context=base64(JSON)`，含 hotwords 与 chat；作者同处明确记录字段被接受但 A/B 未观察到转写改善，默认关闭。不能把它作为已验证功能交付。

公开来源固定为 VoxType `1b0516b7fddf547cb8ba923e848c41ab1be96416`、Python `267972f815f519fd7c6149f85a8b7cc99daf61a5`、npm `@ziuchen/doubaoime-asr@1.0.0`。前两仓未发现主项目许可证；npm 声明 MIT，但源码仓当前 404、tarball 未附完整 LICENSE。没有把这些实现复制进产品；隔离工具按字段事实自行实现最小消息编解码。npm 的固定[发布文件](https://unpkg.com/@ziuchen/doubaoime-asr@1.0.0/dist/ner-DnTAAr6a.mjs)仅用于只读交叉查证。

## 接入决定与剩余工作

可进入实验适配的设计细化：独立的 ASR 凭据提供器、Opus 编码、WS 会话、文字整理 SSE 客户端及审计关联均已有实际协议依据。SAMI／Wave／NER 不作为首版额外依赖，用户登录不能作为本轮已证明必需的前置步骤。

当前不把研究脚本交给最终用户。正式适配须自行封装并随应用打包 Opus，不能依赖本机 Homebrew；正式冻结状态机、配置快照与失败语义；长音频跨段累积和完整性、取消后的迟到结果、错误分类、词表有效性和原始意图保真须补验。没有识别到当前商业计费凭据或付款动作，不等于已确认使用许可、额度或长期免费。

真实麦克风／原客户端键盘对照本轮未执行：共享 GUI 已协调，Mac USB 树没有检测到 KVM 输入设备，已有资源最后确认在 Janus；没有用软件全局发键冒充 HID 验收，也未改输入法、快捷键、音量或原应用凭据。隔离后端重放不依赖该硬件步骤，因此已独立完成。

原 [接入方案](https://github.com/felixlark/chat-type/blob/5350f037b3782e875f0f23e8cb8421fddcdedcac/docs/doubao-backend-research-plan-2026-11-14.md)据这些事实更新。实验后端可行、质量采纳及安装版验收继续分开处理；当前没有修改／打包／安装 ChatType 产品。
