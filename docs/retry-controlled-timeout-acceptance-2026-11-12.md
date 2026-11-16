# 真实 URLSession 超时与 HUD Retry 验收

> Historical evidence for the date/build recorded below. Current requirements: [PRODUCT](../PRODUCT.md).

用户要求补齐真实错误下的Retry。共享Mac owner已释放GUI/音频窗口，但要求整机网络、透明TUN、Tunnel、Sol及共同代理/DNS保持可用。当前124已有History重试，但仅显示最近10条，先前真实TLS失败不在可达列表；不能修改历史时间或直接伪造error浮层。

采用显式、仅当前进程有效的验收启动参数`--acceptance-transcription-timeout-once`。正常启动不创建该控制器、不改变既有pipelineFactory。带参数时通过现有pipelineFactory/dataLoader边界，为第一条且仅第一条发往固定`https://chatgpt.com/backend-api/transcribe`的实际POST请求设置1ms URLRequest.timeoutInterval，再调用真实URLSession.shared.data。后续请求完全沿原请求及默认超时。严格限定scheme/host/port/path/POST，其他地址不消耗标记。控制器以锁原子消耗一次；不合成错误、HTTP响应或结果，不改Keychain/持久配置/代理/网络/TCC，不打印请求头、正文、令牌或原声。

由真实URLSession产生的超时沿现有生产错误处理进入HUD可重试状态，原声、当轮配置和session检查仍由既有AppCoordinator负责。首请求是否已经到达服务端未知，不能声称没有上传；转写为读操作，显式手动Retry仍使用同一保存原声且最多一次挑战尝试。记录这是受控真实传输超时，不冒充自然发生的TLS/Cloudflare故障。

先完成纯单元检查：只作用于精确审计端点、一次性与并发消费、其余请求不受影响。安装版启动必须经LaunchServices。使用已获准六条之一的已保存原声，经History的真实Retry按钮触发首请求。操作前聚焦专用空白目标或无编辑焦点的ChatType窗口，防止将结果送进其他用户缓冲区。观察真实超时消息和HUD Retry，记录原声SHA及pending副本。点击HUD Retry一次，观察真实网络成功、最终稿只有一次提交，比较原声SHA/文件仍存在。检查当轮配置未漂移。

结束后通过正常安装路径无验收参数重启，确认正常进程、原默认、账户权限和配置校验值，保持运行。该过程只验Retry错误恢复，不将额外请求计入速度试验。若请求未实际超时、首次消息不支持Retry、签名/权限出现额外挑战或无法安全聚焦，保留证据诊断，不用演示/内部直接回调替代。正常启动分支保持既有行为与品牌。

## 实际结果：125 通过本次受控超时恢复

2026-11-12 13:41:56，安装版实际 URLSession 返回 -1001，错误浮层显示超时和 Retry。13:49:33 点击浮层 Retry，随后转写和润色各 HTTP 200，13:49:39 仅新增一条 clipboard 成功记录。原声校验值前后一致，系统剪贴板与最终稿校验值一致。正常超时只被第一个请求覆盖一次，Retry 没有再次触发验收故障。

已退出验收进程，经 LaunchServices 无参数重启正常安装版，PID 99958，账户 Ready、两项权限 Granted，配置未改变，键鼠释放且共享桌面/网络窗口交回。详细证据及适用范围见[本轮结果](incremental-polish-results-2026-11-12.md)。受控真实超时通过不等于自然 TLS、Cloudflare 或全部错误类型验收。
