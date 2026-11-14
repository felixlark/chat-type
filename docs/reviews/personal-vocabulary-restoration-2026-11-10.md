# 个人词库恢复：EGM审查与实测状态

目标：../personal-vocabulary-restoration-2026-11-10.md。2026-11-10。

初审fresh-context egm_personal_vocabulary实读readiness persona/standard和直接依赖，提出2 Major（姓名检索算法参数、600/240预算接线）与1 Nit（文件清单/检查点）。主writer补齐Foundation转拼音、窗口/音节距离/同字数/两字姓名cue、确定排序与12候选截断；明确原hintTerms→相关姓名→剩余词项的ASR顺序、polish hintTerms参数；补齐路径与检查点。

fresh-context egm_personal_vocabulary_recheck实读更新合同及标准，剩余Blocker/Major/Nit均0。两名reviewer均只读，不访问memory、个人配置/通讯录，不运行GUI或网络，不改代码。

260项单元/进程内集成测试、policy、landing通过；签名包检查通过。实际安装0.5.1(109)后，Text Replacement公开API读取210项，按短词合同导入161项，原用户项保留。原联系人来源仍保留；Contacts首次导入系统AccessDenied，实读签名发现缺Hardened Runtime地址簿声明，已修复打包脚本并加入缺失声明回归检查。补签后的canonical包检查再次通过；正式安装版已触发系统授权请求，等待用户通过系统弹窗。官方CU明确禁止控制UserNotificationCenter，本轮由用户本人完成该系统步骤。

三个姓名的正确字形仍等待用户确认，尚未写入未经确认的身份纠正；中文近音召回只作为候选提示。真人F5质量与系统Contacts导入数量按实际后续结果登记，EGM与单测结果不替代这些验收。


后续实际回执：系统授权已从安装版成功回执确认生效（操作者未作文本回执），CU看到Imported Contacts，新增apple-contacts-names5195项；当前17503 terms /171 corrections。补齐user correction目标优先提示后，261项与最终包检查通过，重新安装同一109候选。合成3次9个人名位置均返回词库候选，真人F5及姓名正确字形仍待用户反馈；该范围按实际结果保留开放。


验收闭合：用户确认三名正确字形及通讯录系统允许；12:27真人F5最终3个人名均正确、pasted。CU已在安装版History实读同一最终句。原ASR仍为同音错字，最终由恢复的词库提示和既有整段polish还原。ASR1171ms/polish3004ms/总processing5705ms，261项与签名包检查通过。当前普通运行保留，其他姓名与真人持续预览反馈覆盖按主文明确范围保留。
