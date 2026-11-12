# 个人词库恢复：通讯录、Text Replacement 与中文人名

2026-11-10。当前Mac，主Agent单writer。用户要求恢复电脑Text Replacement、通讯录人名及自定义人名识别；ASR账户与整段润色流程沿用0.5.1(108)。

## 实读事实与范围

当前通讯录实现只fetch CNContactNicknameKey，现有apple-contacts-nickname仅3项；旧macos-contacts仍有2698项。源码没有系统Text Replacement读取链路。现有用户纠正和联系人数据保留，但ASR提示600字符和润色240字符词表存在优先级/召回限制；中文同音错字未得到相关姓名提示。

用户给出三个疑似ASR写法，正确字形正在向用户核实；修复来源和通用召回继续进行，确认前不写死其身份映射。

## 实施合同

1. 通讯录通过既有CNContactStore授权读取formatted fullName和nickname；只取姓名相关字段，沿用当前Contacts Names入口。导入新apple-contacts-names来源，替换该来源及旧apple-contacts-nickname，保留用户项、旧macos-contacts、其他来源。无授权时保留现有词库并显示真实权限错误，新增授权由系统交互处理。
2. Text Replacement通过AppKit公开NSSpellChecker.userReplacementsDictionary读取，恢复独立导入入口。按macos-text-replacements来源导入精确correction：shortcut→短词；原用户项优先。同步范围固定为trim后2–32字符、单行，仅汉字/拉丁字母/空格/点/下划线/连字符及至多4位连续数字，且值含汉字或字母；过滤URL、邮箱、长段模板、冒号等非词项内容。若shortcut含password/token/secret等凭据标记则跳过。系统210项中存在长模板的事实已确认，本任务恢复姓名与短词识别，不展开整段模板。只记录导入数和跳过数，不输出条目明文。只替换自己的导入来源；空结果显示0项并保留用户项。沿用ConfigStore和统一导入持久化回路，导入后的设置草稿与coordinator状态一致。
3. 本地预览只为完整音频正式ASR挑选相关姓名提示：RecordedAudio携带previewText（本地上下文），ChatGPTTranscriber明确使用config.prioritizedHintTerms + relatedNames(previewText) + config.promptHintTerms（prioritizedHintTerms包含原hintTerms和source=user的2–4汉字canonical，覆盖correction目标），去重后送入原600字符builder；完整预览文本不进入网络请求。正式ASR结果再做同类检索，把prioritizedHintTerms + relatedNames(rawASR)作为既有TextPolishing.polish的hintTerms参数，terminologyEntries保持完整快照；TextPolishPromptBuilder.priorityTerms据此绕过匹配门槛并在240字符内优先保留。正式ASR文本、前后术语对齐和润色流程保持。
4. 姓名召回仅从个人来源的2–4个汉字canonical建立索引：联系人来源、user项、Text Replacement名字目标。拼音用Foundation applyingTransform(.toLatin)后去音调/小写/分音节；候选和query严格同字数。query按连续汉字run取2–4字窗口（整体run转换音节且音节数对齐，失败则跳过）；2字仅在前6字含联系/通知/找/叫/问/转告/给/发给/收件人等人名cue时做精确拼音召回。3–4字允许完整读音相同，或仅一个音节不同且Levenshtein距离1；距离2仅在其余字形至少n-1相同时进入候选，用于多音字/常见ASR近音。其余拒绝。按完整拼音和省略一个音节的键建索引，避免逐人扫描。候选累计去重，按音节编辑距离→字形差异→user优先→canonical字典序排序，确定截断12项；超过12项时仅保留排位前12，同音歧义不硬选。此检索只挑选提示词，不按拼音直接替换正文。明确错拼映射须由用户正确姓名确认后加入既有correction机制。
5. 索引按姓名内容缓存，在配置加载/导入后utility预热；冷启动fallback可建索引，避免每次对全通讯录做拼音转换。候选排序确定：拼音距离、字形差异、来源user优先、拼写；优先精确读音，同音歧义保留。普通Retry保留preview及原配置快照；History Retry用原ASR作本地提示上下文及当前词表；文件CLI无preview也可在polish阶段召回。
6. 数据仍在本机词库；网络目的地沿原ChatGPT/当前选定polish provider，仅现有预算内相关词项进入提示。手机号、地址、邮箱不从Contacts读取；不读系统私有数据库、不复制通讯录全表至日志，不新增供应商或权限范围。

## 写入与验收

直接路径：Sources/ChatType/TerminologyImporters.swift、AppCoordinator.swift、PreferencesWindowController.swift（两个导入与持久化），TerminologyPolicy.swift（新来源按现有联系人策略处理），PersonalNameHints.swift（新），AudioRecorder.swift、LocalSpeechRecorder.swift、ChatGPTTranscriber.swift、DictationPipeline.swift（上下文和提示）。测试为Tests/ChatTypeTests/TerminologyImporterTests.swift、PersonalNameHintTests.swift（新）、QualityRestoreTests.swift与ChatGPTTranscriberTests.swift。文档为本文及当前README来源说明。稳定检查点：来源导入和持久化→姓名索引/提示接线→Retry/最终检查/正式安装验收。已有图标/配色/浮窗位置保持。

覆盖：通讯录只有fullName无nickname；nickname保留；Text Replacement导入/去重/用户优先/刷新；三个真实写法用合成人名等价测试音近召回、歧义和普通文本负例；提示实际包含相关name、600/240预算和Retry上下文；缓存失效。canonical scripts/check.sh后签名安装，以官方CU导入系统来源并检索目标名；真实F5音频或History Retry核对原ASR/最终结果。未实际跑过的声音不作识别成功结论。保留安装前包及配置，失败恢复既有可用版，最终正常运行。

已有用户联系人库内容、dirty worktree和Keychain均保留。当前0.5.1(108)的质量缺口按原记录保留；本次只收敛个人词库缺口。


## EGM 首轮缺口处置

readiness指出算法阈值和预算接线两项Major，均已在合同中指定；补齐精确路径与检查点。可执行例：个人候选林卓玟，ASR林卓文应进入候选（多音字距离2+2字重合）；同音候选林卓文/林卓闻并列保留；戴锦钗与戴锦猜进入候选；陈龙彪与成龙标进入候选。普通“今天下午开会”对这批候选应返回空；2字候选金天在普通“今天开会”应返回空，在“联系金天”可进入。同字数差异不召回。超过预算的无关词表前仍应保留相关姓名。Text Replacement长模板和纯数字不进入词库。


## 实测发现与签名修复

首次安装109后官方CU点击Contacts Names，系统直接返回Access Denied。实读签名仅有audio-input，缺com.apple.security.personal-information.addressbook；Apple官方文档明确该项用于Hardened Runtime的Address Book能力。已补package_app.sh的签名声明与新的NSContactsUsageDescription，在check_packaged_app.sh加入缺失声明即失败的回归检查。声明让系统能够呈现授权请求；授权通过系统交互完成，应用仅取姓名/昵称字段。

Text Replacement在真实安装版通过公开AppKit读取210项，范围过滤后成功导入161项短词correction；长模板未写入词库。存量用户项和其他来源保留。首次排查输出曾带出无关长模板；后续全部限定计数和目标短姓名，未将模板落盘至仓库、报告或发送至模型。

EGM首轮2 Major/1 Nit已处置；fresh-context定向复核剩余0/0/0。260项单元/进程内集成、policy、landing及首包检查通过；签名声明修复后的包检查、系统授权与真人人名识别仍继续实测。


合成音频首轮3次：两个候选姓名各返回3/3，另一个自定义姓名仅1/3，其余误选近音联系人。已定位user correction目标原先未进入ASR/整段polish重点提示，补入prioritizedHintTerms并覆盖单元断言；不新增未经用户确认的姓名纠正。


## 最终候选与实际回执

- 当前候选0.5.1(109)，正式路径/Applications/ChatType.app，沿用Developer ID签名。最新261项单元/进程内集成、policy、landing和签名包检查全部通过；新增Contacts签名声明缺失即由包检查拒绝。源码、配置及运行端同批更新。
- 系统授权生效后，官方CU实读安装版显示Imported Contacts；姓名term从12311增至17503，新增来源apple-contacts-names有5195项（替换旧nickname3项）。旧macos-contacts2698项与用户词项保留。连同171条correction，当前总条目17674。
- 系统Text Replacement共210项，通过公开AppKit在安装版导入161项短词；当前共171条correction，长期模板和不符合词项范围的内容保留在系统。值未进入日志/报告；仅核计数、筛选范围及目标姓名。来源刷新及用户覆盖用测试验证。
- 自定义user纠正目标曾缺ASR优先提示，已用prioritizedHintTerms修复，涵盖中文自定义姓名canonical，并接入生产GUI、CLI、benchmark的原术语/整段polish。普通Retry保留previewText与原快照；History Retry使用旧ASR作为本地提示上下文、当前词表重新识别。
- 用户给出的三个写法制作Tingting合成音频，完整WAV走原ChatGPT账户ASR和gpt-5.6-terra整段polish。最新3次原始ASR仍出现成龙标/成荣彪、李卓文、戴锦猜，最终3次均返回词库候选陈龙彪、李卓玟、戴锦钗，9个姓名位置均一致。提示3/3实际发送；ASR949–1598ms、polish2912–3502ms。文件音频用于质量，不作实时F5尾延迟结论。姓名身份字形仍以用户确认为准，本次未新增未经确认的三个人名纠正映射。
- 等待用户真人F5测试，确认实时预览、最终姓名与粘贴；安装版正常运行。用户正确姓名确认卡仍待文本答复，通讯录授权已从实际导入回执确认完成。

原109未加user目标优先提示的首轮3次音频结果仍保留在本机日志，以最终候选结果分别标记。备份108签名包位于~/Library/Caches/chat-type/personal-vocabulary-restore/R108-installed/ChatType.app，原配置及导入后配置位于~/Library/Application Support/ChatType/personal-vocabulary-restore/；回滚不得覆盖后续用户新增资料。

公开接口依据：[NSSpellChecker.userReplacementsDictionary](https://developer.apple.com/documentation/appkit/nsspellchecker/userreplacementsdictionary)、[Contacts姓名字段](https://developer.apple.com/documentation/contacts/contact-keys)、[Contacts格式化](https://developer.apple.com/documentation/contacts/cncontactformatter)、[Hardened Runtime地址簿声明](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.addressbook)。


## 真人验收闭合（12:27–12:28）

用户文本确认正确姓名为“陈龙彪、李卓玟、戴锦钗”，确认已点击系统允许，并提交真人F5测试输出。安装版Recovery记录时间2026-11-10T04:27:25Z，录音8398ms；原ASR为“测试一下成龙标、李卓文、戴锦财这些人名的识别和润色的。”，最终为“测试一下陈龙彪、李卓玟、戴锦钗这些人名的识别和润色。”，outcome=pasted、errorMessage=nil。现有gpt-5.6-terra整段润色流程保留，相关人名词库提示恢复最终姓名；没有按拼音直接改正文。

该录音指标：完整WAV407220 bytes上传原ChatGPT账户，ASR1171ms、原模型polish3004ms、归一化202ms、注入88ms、总处理5705ms。该数字为此真人样本的processing计时；实时预览持续出字未收到本轮明确反馈，沿用原fastResults行为及已有预览回归，不扩写验收范围。

官方CU在正式路径Settings→History→AI polish结果实读同一最终句，程序正常保留运行。implemented、checked(261 tests+policy+landing)、packaged、installed、个人来源导入、真人姓名/粘贴live accepted、left running各有对应证据。当前验收覆盖上述三个人名与已列正负/歧义测试，其他姓名继续使用相关候选机制；不作全通讯录逐人识别通过结论。此轮不新增三条姓名强制纠正，保留同音歧义与现有用户项。
