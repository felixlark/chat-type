# Apple Contacts 本机只读盘点合同

用户要求检查词库规模与通讯录同名/重复，提出优化方法并用EGM设计评审。本轮只读取和设计；联系人、词库、重点词及模型保持。原两个人名的重点词追加尚未获批，未执行。

## 已知与待核

当前词库17674项：微信备注term9386、新apple-contacts-names 5195、旧macos-contacts 2698；其余为普通术语、自定义及Text Replacement。联系人、姓名、昵称/单位派生词分别统计。当前导入策略会拆分姓名与单位，并按字形去重；多个来源词项不直接折算成人数。

当前命令行的CNContactStore.authorizationStatus为0（notDetermined）。ChatType曾经本人允许Contacts并导入5195项；本次运行状态将由原应用身份现场读取。独立CLI不请求新权限。后续数据采集复用ChatType已有Contacts声明、签名和授权，guard仅在authorized时读取；其他状态返回真实权限缺口，保留未知，不扩权。

## 本轮只读诊断实现

主Agent单writer。scripts/doctor.sh已执行，exit0；已将正式干净110包备份到Application Support/ChatType/contacts-audit-20261110/clean-110/ChatType.app，并在本机保留配置基线。单一假设：来源与姓名/派生词的层级混淆，加上既有近音门槛，共同影响数量理解与召回；联系人本体重复仍待原生计数。

临时NativeContactsAudit.swift在main.swift最前分流，早于ChatTypeCLI、NSApplication/AppDelegate、AppCoordinator及ChatGPTAuthManager构造；CHATTYPE_CONTACTS_AUDIT=1时同步只读盘点、输出、exit。它通过ConfigStore.configURL的只读路径属性读取Data，并用独立RawConfiguration最小结构解码type/original/source；不调用ConfigStore.load/save，也不调用词库sanitizer。没有录音快捷键或认证管理器实例。

诊断打包严格离线：临时将package_app.sh的签名--timestamp改为--timestamp=none，明确使用与备份包一致的本机签名identity。原项目远程锁定依赖PermissionFlow在项目现有.build/checkouts中有本机副本，commit已核为3c5ae16337d3448e8561e00352a01b68f92fe974，与Package.resolved/Package.swift一致；将其checkout、repositories和workspace-state复制到本轮scratch。临时为check.sh和package_app.sh的build/test附加--skip-update --disable-automatic-resolution；缓存缺失/不匹配即停止构建，保持当前安装。依赖本身无进一步远程依赖，本轮不下载依赖。

本轮显式CHATTYPE_SCRATCH_PATH=/Users/longbiao/Library/Caches/chat-type/contacts-audit-20261110/swiftpm、CHATTYPE_DIST_PATH=/Users/longbiao/Library/Caches/chat-type/contacts-audit-20261110/dist；build/test的cache-path显式为/Users/longbiao/Library/Caches/chat-type/swiftpm-cache，package的build也补同一路径。安装前核对bundle ID、110版本、签名designated requirement及Contacts entitlement与备份身份相同。诊断install显式指向本轮dist，恢复install显式指向Application Support/ChatType/contacts-audit-20261110/clean-110；各自先确认源app存在，防止隐式打包或写入Local。

当前录音/处理结束后才更换包。通过LaunchServices在正式路径以CHATTYPE_CONTACTS_AUDIT=1运行一次。完成或失败均移除main临时分支与NativeContactsAudit.swift、恢复原package/check脚本；与改前本机源码字节快照比对。canonical install显式指向上述clean-110目录恢复干净110包。审计前后对比配置原始字节；若有差异暂停后续变更，保留最新用户文件并报告，避免自动覆盖。原110产物与恢复后的源码一致，复用其267项已通过检查。

“无云”约束覆盖通讯录审计和数据处理：诊断入口、编译打包和采集不调用HTTP/时间戳/云通讯录/AI服务，审计没有Keychain会话读取。系统既有账户后台同步设置保持。结束后退出审计，再恢复原正常ChatType运行；其原账户登录预热及后续语音仍属于既有已授权功能，新增采集的联系人原文始终仅在审计进程内，未写入词库或发往模型。该边界保留当前正常产品行为。

临时代码候选在本轮mktemp目录的NativeContactsAudit.swift；实际路径由主Agent交付给reviewer。只调用公开Contacts.framework：

- CNContactStore.authorizationStatus、enumerateContacts、containers和defaultContainerIdentifier。
- CNContactFetchRequest先只取identifier，分别unifyResults=false/true计数，再用最小姓名/昵称/type字段作统一卡片姓名统计；每个container用公开container predicate统计原始卡片。
- 全名、昵称、标识仅在进程内。输出匿名container序号/type、卡片数、同名字形组数量/组大小、派生词数与现有Apple来源词集合的交集/差集计数；空姓名单列，组织卡片单列。同名组属于候选，合并身份仍待判断。
- 只生成Application Support/ChatType/contacts-audit-20261110/native-contacts-summary.json聚合统计，输出一行JSON；姓名、标识、手机号、邮箱、地址、备注、照片均不输出。手机号等字段不读取。
- 分开记录两次枚举的identifier集合是否一致及起止时间；这是只读观测，正式写入前还需重读字段与来源。

诊断源码不调用CNSaveRequest/requestAccess/HTTP，不读系统私有数据库，不启动Contacts GUI，不使用Computer Use。模型评审仅接收源码和匿名统计。系统既有账户同步设置保持；本轮脚本不调用云端通讯录或AI服务。

## 词库规模对照

已用当前PersonalNameHints源码在本地独立-Onone临时进程，对完整词库、Apple来源子集、三个已确认姓名的子集做固定三类查询各5轮。只输出匿名T1/T2/T3召回布尔、候选数及中位查询耗时。严格term重复键与entry重复键均0；姓名候选10155个；本次失败查询完整词库41.1ms、3个人名子集1.1ms，两者均只召回T1。另两类查询分别显示原成功案例三名全召回，以及一处近音仍失败。规模影响本地检索量；此次漏召回的门槛在3人小池也复现。correction目标与term重叠有独立语义，保留。该对照未调用ASR/LLM，未修改词库。

本机Foundation音译核对：T2的ze/zhuo单音节编辑距离3超过当前上限2；T3的jing/jin和cai/chai两处音节不同，超过当前最多1音节差异门槛。该结果修正了早期将两者都归为两音节差异的描述。审查材料只含差异片段与匿名T编号，不含原姓名。

## 完成标准与恢复

交付真实native卡片数/统一卡片数/同名候选组/词项数的独立分母，以及旧Apple来源在当前原生投影中的命中/缺席数。若权限或API失败，列实际错误和未测覆盖；其余来源/代码/规模实验照常完成。统计不把同名组自动判为重复人。

临时诊断结束或失败均移除本任务临时代码、恢复原110安装包，保持其他dirty与用户数据；正常ChatType保留运行。恢复前同样等待录音/处理空闲。无需重置TCC或新增服务。

最终另交优化方案：原始联系人卡片、唯一姓名检索视图与派生词库分层；清理候选与真实写入分开。联系人合并/删除以及词库配置变更均在本轮设计范围之外。未来使用CNSaveRequest写入远程账户卡片可能触发系统已有同步；严格本地写入只适用于local container，云同步范围必须先有明确决定。

## 已完成回执

16:01:50–16:01:52正式路径原生采集完成，授权原始值3；9,215张原始卡片、8,927张统一卡片、65组同名候选涉及135张个人卡片。原始标识去重数与枚举数一致，姓名读取与首次统一标识集合一致。采集和正常重启后配置字节保持一致。临时入口、采集文件及离线打包脚本修改均恢复；正式二进制与备份干净110逐字节一致，本次正常运行回执PID为75055。

独立就绪初审提出配置写回、打包/恢复的联网范围、默认Local路径3项Major；已通过前置入口/独立最小解码、离线依赖与签名/明确恢复边界、显式路径修订。fresh-context复核0 Blocker / 0 Major，实际267项检查及签名包检查通过。真实联系人身份重复尚未核验，本轮联系人写入0。

完整统计、方法和后续设计见[通讯录优化方案](contacts-optimization-2026-11-10.md)。
