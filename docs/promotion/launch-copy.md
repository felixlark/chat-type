# ChatType Launch Copy

Use this as source material. Adapt each post to the platform instead of copying the same text everywhere.

## Core Positioning

One-liner:

> ChatType lets ChatGPT users on macOS press F5, speak, and paste the transcript into the current input box when safe.

Short description:

> ChatType is a native macOS menu bar dictation app for people who already use ChatGPT. The default path connects ChatGPT through the default browser and stores its own local session, so the normal workflow does not require a separate API key or local model download. It records with a single F5 trigger, transcribes, then pastes only when a focused editable target is detected. If paste is not safe, the result stays in the clipboard for manual Cmd+V.

Risk boundary:

> ChatType v1 depends on a ChatType-owned local ChatGPT session and an upstream private transcription path. It is a personal productivity tool, not a stable enterprise API integration.

## Xiaohongshu Note 1: Pain Point

Title options:

- 给AI写需求别手打了
- 别再手打长需求了
- 我给 Codex 搓了个语音小开关

Body:

> 我最近被一个小事折磨到不行：
>
> 用 Codex / ChatGPT 写需求时，脑子里已经想好了，手还在慢慢打。长一点的中文 prompt，打到一半思路就散了。
>
> 所以我给自己搓了个很窄的小工具：ChatType。
>
> 它只做一件事：
> 把“说话”接进 Mac 上正在输入的地方。
>
> 我的日常用法：
>
> 1. 光标放到 Codex / ChatGPT / Notes
> 2. 按一下 F5 开始说
> 3. 再按 F5 停止
> 4. 能回填就直接进输入框
> 5. 不确定能不能安全粘贴，就只放剪贴板
>
> 我刻意没把它做成新的聊天 App，也不包装成全能 AI 平台。
> 它更像一个小开关：长句不想打的时候，按 F5 说完。
>
> 适合：Mac 用户 / 经常写中文长 prompt / 已经在用 ChatGPT / 能接受开源小工具还在早期
>
> 不适合：企业级稳定 API / 不想折腾 macOS 权限 / 需要手机端
>
> 现在先开源放出来，想看看有没有人也被这个痛点戳中。
>
> GitHub 搜：longbiaochen/chat-type

Tags:

`#AI工具 #Mac效率工具 #VibeCoding #Codex #ChatGPT #独立开发 #开源项目`

## Xiaohongshu Note 2: Demo

Title options:

- 15 秒演示：我说完，Codex 输入框里就有了
- Mac 上写 AI 需求，我现在直接按 F5 说
- 光标放这里，说话就先到这里

Body:

> 先别看功能表，直接看这个小流程：
>
> 我把光标放到 Codex 输入框。
>
> 按一下 F5，开始说需求。
>
> 再按一下 F5，结束。
>
> 能确认现在是输入框，就直接回填；不确定的时候，不乱粘贴，只把文字放到剪贴板，自己 Cmd+V。
>
> 我做 ChatType 不是为了再开一个 AI App。
> 它就是给 Mac 上已经在用 ChatGPT 的人，加一个很窄的语音开关。
>
> 适合：
> - 经常在 AI 工具里写中文长句
> - prompt 打到一半思路会断
> - 能接受开源小工具还在早期
>
> 不适合：
> - 需要手机端
> - 需要企业级稳定 API
> - 不想处理 macOS 麦克风/辅助功能权限
>
> 想试的话，收藏后电脑搜：
> `longbiaochen/chat-type`

Tags:

`#Mac软件 #效率工具 #ChatGPT技巧 #Codex #语音转文字 #AI工作流`

## Xiaohongshu Note 3: Builder Story

Title options:

- 为什么我只给 ChatType 设计一个按键：F5
- 一个很窄的开源 Mac 工具：只解决说话到输入框
- 做 ChatType 时，我删掉了很多“看起来更完整”的功能

Body:

> ChatType 不是想做全能听写平台。
>
> 我给它设了几个很窄的边界：
>
> - 一个触发键：F5 开始，F5 停止
> - 默认不要求 API key
> - 默认不下载本地模型
> - 不在主路径里做第二轮 AI 清洗
> - 不确定能不能粘贴时，只放剪贴板
>
> 这些限制反而让它更像一个每天能用的小工具。
>
> 如果你也在 Mac 上用 ChatGPT/Codex 写需求、写邮件、写笔记，欢迎试一下，也欢迎直接提 issue。
>
> GitHub: https://github.com/felixlark/chat-type

Tags:

`#独立开发 #开源 #Mac效率 #产品设计 #AI工具 #ChatGPT`

## Jike

> 做了一个很窄的开源 Mac 工具：ChatType。
>
> 面向已经在用 ChatGPT 的 Mac 用户。先在 ChatType 里登录 ChatGPT，按 F5 录音，再按 F5 停止；检测到当前焦点是输入框就回填，否则留在剪贴板。
>
> 我不想把它包装成泛用 AI SaaS。它就是解决一个日常痛点：在 Codex、ChatGPT、Notes、Slack 里想说长段中文时，不想慢慢打。
>
> GitHub: https://github.com/felixlark/chat-type

## V2EX

Node: `分享创造`

Title:

> [开源] ChatType：给 macOS + ChatGPT 做的 F5 听写回填工具

Body:

> 大家好，我做了一个很窄的 macOS 菜单栏工具：ChatType。
>
> 它面向已经在用 ChatGPT 的 Mac 用户，目标是把 `F5 -> 说话 -> 回填` 这条链路做短。
>
> 当前行为：
>
> - F5 开始录音，F5 停止录音
> - 默认在 ChatType 内登录 ChatGPT，不要求单独 API key
> - 检测到当前焦点是可编辑目标时才粘贴
> - 如果不适合粘贴，就把最终文本留在剪贴板
> - v0.1.2 支持从 TypeWhisper 导入术语表，做本地确定性术语对齐
>
> 明确边界：
>
> - 依赖 ChatType 自己保存的本地 ChatGPT 会话
> - 不是稳定公开 API，也不是企业级集成
> - 目前是本地签名、未 notarize 的 macOS app
>
> GitHub: https://github.com/felixlark/chat-type
> Landing page: https://longbiao.crowdsensing.cn/chat-type/
>
> 想请大家帮忙试两个点：第一，F5 这个单键录音/停止是否顺手；第二，保守粘贴/剪贴板兜底是否比“总是粘贴”更符合预期。

## Zhihu / Juejin Long Form Outline

Title:

> 为什么我做了一个只服务 F5 的 Mac 听写工具

Structure:

1. Problem: long prompts and Chinese notes are slow to type in Codex/ChatGPT.
2. Constraint: ChatGPT login is already part of the user's workflow; avoid adding a second subscription, API key, or local model.
3. Product choice: one global trigger, no floating feature pile.
4. Safety choice: paste only into editable targets; clipboard fallback otherwise.
5. Technical boundary: private desktop transcription path, not a public API promise.
6. Current release: v0.5.x, terminology dictionary import, custom corrections, GitHub release.
7. Feedback request: F5 workflow, permission onboarding, paste behavior, terminology accuracy.

## Hacker News

Wait until the release page, landing page, README, install instructions, and demo are ready.

Title:

> Show HN: ChatType - F5 dictation for ChatGPT users on macOS

Maker comment:

> I built ChatType because I often write long Chinese prompts and notes in Codex/ChatGPT Desktop and wanted a shorter path than typing everything by hand.
>
> It is a native macOS menu bar app. Press F5 to start recording, press F5 again to stop, then it transcribes through ChatType's own ChatGPT session and pastes only when the focused target looks editable. Otherwise it leaves the transcript in the clipboard.
>
> The main caveat is important: this v1 depends on a ChatType-owned local ChatGPT session and an upstream private transcription path. I am not presenting it as a stable public API integration.
>
> I would especially like feedback on the interaction model: single F5 trigger, conservative paste behavior, and permission onboarding.

## Product Hunt

Tagline:

> F5 dictation for ChatGPT users on macOS

Description:

> ChatType is a native macOS menu bar app that turns F5 into a fast speak-to-paste workflow for people already using ChatGPT. It records, transcribes through its own ChatGPT session, pastes only when a focused editable target is detected, and keeps the result in the clipboard when paste is not safe.

Maker comment:

> I built ChatType for my own daily AI workflow on macOS. The problem was simple: long prompts and Chinese notes take too much attention to type, especially while using Codex or ChatGPT Desktop.
>
> ChatType keeps the path intentionally narrow: F5 starts recording, F5 stops, and the transcript goes into the current input box only when that is safe. If not, it stays in the clipboard.
>
> This is not a general-purpose SaaS launch. The v1 default path depends on a ChatType-owned local ChatGPT session, so I am keeping that limitation explicit and looking for feedback from users with the same setup.

## AI Directory Submission Fields

Name:

> ChatType

Website:

> https://longbiao.crowdsensing.cn/chat-type/

GitHub:

> https://github.com/felixlark/chat-type

Category:

> Productivity, Speech to Text, macOS, Developer Tools

Short description:

> Native macOS F5 dictation for ChatGPT users, with safe paste and clipboard fallback.

Long description:

> ChatType is an open-source macOS menu bar dictation app for people who already use ChatGPT. Press F5 to record, press F5 again to stop, then ChatType transcribes through its own ChatGPT session and pastes only when the focused target is editable. If paste is not safe, the transcript remains in the clipboard for manual Cmd+V. It also supports local terminology dictionary import and custom corrections for deterministic post-transcription term alignment.

Pricing:

> Free / Open source

Limitations:

> Requires macOS and ChatGPT browser OAuth connection for the default path. Advanced OpenAI-compatible recovery is available for users who configure their own endpoint and credentials.
