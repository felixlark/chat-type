# ChatType 控制面板迭代

## 目标与在用事实

用户授权一轮整体控制面板实现、打磨、安装与真实验收，并要求把能力沉淀到 GSE。规范 checkout 已有大量未提交的 Stage A 转写和词库工作，全部作为现状保留；本任务串行写入。doctor：安装版 0.5.1(117)，/Applications/ChatType.app 正常签名、运行，ChatGPT 转写与润色近期 HTTP 200。现有录音可能正在使用，安装前核空闲。

问题：Account、Dictation、AI Polish、Paste、Advanced 分散；词库 17,503 条无搜索，编辑时重复全表筛选；macOS 输入快捷码被导为 correction；微信导入依赖已失效的旧解密缓存路径。已注册 wechat-decrypt:get_contacts 可用，元数据总数 13,122。

## 设计候选 v2

- 五页：Account、Dictation、Terminology（用户所称 Technology 按现有词库页理解并保留）、History、Settings。原生系统字体、现有颜色与品牌图标保持；压低标题和容器层级，去嵌套卡片，窗口可缩放。首次打开在 Account。
- Account 唯一拥有服务选择、凭据、转写兼容恢复设置和润色模型配置。保留已有 ChatGPT/GLM/Qwen 服务与两条转写路线；本轮不新增服务或域名、不发起计费测试。禁用润色时不强制要求其 Key。凭据继续 Keychain，UI 显示保存状态，连接状态与真正成功区分。
- Dictation 合并识别与润色行为。可点击的流程：录音/本机预览 → 完整音频转写 → 词条对齐 → 整段文本润色 → 文本修正 → 粘贴/剪贴板。每步展示输入、输出、服务、模型和隐私；ChatGPT 转写模型由服务端选择，明确未知；用户润色模型仅影响文本阶段。Apple SpeechAnalyzer 预览依现有 macOS 26 可用性，不把本机预览误说成最终文本。兼容路径跟随实际配置；润色 Off 和无可用凭据均诚实呈现。
- Terms：中英文标准拼写、人名、技术词，英文规范大小写与受支持别名对齐；中文保留精确词条和已有相关词/姓名提示，不全词库同音乱替换。Replacement：用户显式定义的文字修正规则（口误、固定专名和大小写），完整词匹配英文、连续字串匹配中文，最长优先、一次替换，替换输出不递归再匹配；仅在最终文本阶段执行一次；所有取得转写文本的正常、Off、失败、重复截断路径汇入同一最终文本出口，再执行 Replacement 与格式化。没有 ASR 自动学习或五笔快捷码转换。
- 移除 macOS Text Replacement 导入按钮及其运行绑定。配置加载时把 source=macos-text-replacements 的已有 correction 转为其目标文字 Terms，原快捷码与别名不参与匹配；保留源标记和创建信息，ConfigStore 在解码迁移及任何写回前对原字节创建不可覆盖的 0600 备份，备份失败则停止迁移且原文件保持；回滚先恢复旧应用再恢复原配置。
- 词库使用独立子视图隔离输入状态；搜索、来源筛选、原生列表分页，每页显示 50 行，所有条目通过搜索和翻页完整可达（无词库容量限制）；过滤结果仅在搜索/类型/数据变更时计算，不在每次输入编辑框时全表扫描。不增加数据容量限制。显式添加/编辑/删除，操作有状态反馈。异步导入接口只返回 TerminologyImportResult，完成时合并到最新词库草稿，保留期间的账户/词条编辑；词库子视图重置编辑下标。所有导入按钮共享父视图持久忙状态，切页再返回仍保持。导入与保存共享明确的“保存后生效”语义，避免导入静默保存其他未保存设置。
- 微信使用现有 wechat-decrypt 的公开 get_contacts 读工具入口，移除 ChatType 的 SQLite 缓存读取。打包只读 helper 调用已安装隔离 Python runtime + ~/Projects/wechat-decrypt/mcp_server.py，只调用 get_contacts；先有界元数据再取名称，筛掉系统账号/公众号/群，不取聊天、电话号码、密钥。ChatType 导入按钮异步执行，报告真正读取/导入结果与可操作错误，不要求新增隐私权限，不使用 FDA broker 绕过权限。缺运行依赖则如实提示。
- Settings：macOS SMAppService.mainApp 登录项开关（真实状态，失败回读，需系统批准时明确入口），粘贴/剪贴板、声音和权限。默认保留现有开关状态，验收启用/停用后按用户请求留下启用。登录项只启动 /Applications 正常菜单栏应用。
- UX 诚实：配置中/已保存、Key 已存/服务可用、草稿路线/在用路线分清；错误有修复动作。使用本机现有语料完成交互验收，不新增外发目的地或收费调用。

## 对照来源

- Magpie（yetone）：https://usemagpie.ai/docs/start 与 https://github.com/yetone/magpie，集中账户/模型、当前状态与清晰路由；参考原生安装版和官方图像，不复制品牌。
- Superwhisper（superultrainc）：https://superwhisper.com/docs/get-started/interface-vocabulary 区分词汇和替换。
- Wispr Flow：https://docs.wisprflow.ai/articles/8955301725-How-Do-I-Bulk-Import-Dictionary-Items-and-Snippets 区分词条、纠正和长片段。
- Apple：https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp 登录项官方控制面。

## 实施与验收

先独立评审设计，核实原始代码事实，主 Agent 单 writer 完成。单元覆盖：旧快捷码迁移、中文/英文修正/边界/无递归、17k 词库筛选编辑、微信输出解析/错误/缺依赖、流程随服务/模式变化、登录项状态处理（依赖注入）。沿现有 check.sh 全套检查，不让测试触发系统提示或 GUI 操作。构建路径 Library/Caches，打包 dist（不执行旧 ~/Local 默认），签名后安装。官方 Computer Use 比较前后，五页、搜索/编辑/导入、保存、登录项切换/回读、真实 F5 开停/ESC/关闭/重入、粘贴与剪贴板、正常菜单栏运行。日志只计数与状态，词库/凭据不进入报告。

## 恢复

保留原配置受限备份与既有证据，词库迁移可由原配置恢复，登录项可关闭。实现不动现有品牌和转写服务边界，不推送混有未知归属的全仓 dirty。
