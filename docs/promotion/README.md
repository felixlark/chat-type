# ChatType Promotion Kit

This folder is the launch workspace for low-cost public promotion.

The public story must stay narrow and honest:

> ChatType is a native macOS dictation app for people who want ChatGPT-powered dictation without an API key. Connect ChatGPT through the default browser, press F5 to record, press F5 again to stop, then paste into the focused editable target when safe or keep the transcript in the clipboard.

Do not describe the default route as a stable public API. ChatType v1 depends on a ChatType-owned local ChatGPT session and an upstream private transcription path.

## Launch Order

1. Chinese social proof
   - Publish three Xiaohongshu notes from `zh-social-calendar.md`.
   - Publish one Jike post and one Bilibili short/demo cut.
   - Publish the Zhihu/Juejin long-form post after at least one short-form note is live.
2. Developer validation
   - Publish the V2EX `分享创造` post from `launch-copy.md`.
   - Collect 3-5 concrete install or workflow feedback items before Hacker News.
3. Global launch
   - Submit Show HN only when the release download, landing page, README, and known-risk notes are all ready.
   - Launch Product Hunt after demo video, screenshots, and FAQ are ready.
4. Directory submissions
   - Submit free or low-cost AI/tool directories first.
   - Defer paid listings such as TAAFT, Futurepedia, and Toolify until Chinese/V2EX response proves real interest.
5. Support path
   - GitHub Sponsors is the preferred open-source support path, but do not link it publicly until the account sponsor page is enabled.
   - Add Buy Me a Coffee, Afdian, or Open Collective only when those pages are actually created.

## Assets To Prepare

- Landing page: `https://longbiao.crowdsensing.cn/chat-type/`
- GitHub repo: `https://github.com/felixlark/chat-type`
- Release download: `https://github.com/felixlark/chat-type/releases/tag/v0.1.2`
- Xiaohongshu cover templates: `xiaohongshu-cover-cards.html`
- Xiaohongshu source covers:
  - `assets/xhs-cover-pain-point.svg`
  - `assets/xhs-cover-demo.svg`
  - `assets/xhs-cover-builder-story.svg`
- Xiaohongshu exported upload assets:
  - `exports/xhs-cover-pain-point.jpg`
  - `exports/xhs-cover-demo.jpg`
  - `exports/xhs-cover-builder-story.jpg`
- Platform copy and directory fields: `launch-copy.md`
- Seven-day Chinese schedule: `zh-social-calendar.md`
- Long-form article draft: `long-form-article.md`
- Operations tracker: `operations-log.md`

## Xiaohongshu Operations Runtime

The active Xiaohongshu operations path is now the official Chrome plugin plus Computer Use. The old `chrome-auth` / Chrome for Testing path is legacy diagnostics only.

Use this order:

1. Official Chrome plugin
   - Use it first for signed-in Xiaohongshu creator pages when the tool is available.
   - Read page text, public note-manager state, visible metrics, draft titles, and non-sensitive public comments.
   - It is the preferred path for low-risk DOM/page-state checks because it uses the current signed-in browser surface instead of a separate Chrome for Testing profile.
2. Computer Use
   - Use it when Chrome plugin is unavailable, the page needs visual confirmation, a file picker/upload is involved, a draft needs to be saved, or the Chrome plugin view and visible browser UI disagree.
   - Use it for any live acceptance proof involving navigation, clicking, saving drafts, verifying creator-manager rows, or confirming the result after a publish/draft action.
   - If Computer Use returns `Transport closed`, reset stale `SkyComputerUseService` / `SkyComputerUseClient` once, then retry. If it still fails, record `tool_unavailable` and stop the live run without inventing metrics.
   - Public publish, public replies, deletion, paid promotion, account-risk prompts, real-name prompts, phone binding, and security verification still stop the run and require a Chinese report.
3. Legacy `chrome-auth`
   - `scripts/check_xhs_creator_state.mjs` is no longer the first step of daily operations.
   - Use it only to diagnose old heartbeat failures or compare against prior records. Do not let `no_session`, `wrong_profile`, or `unknown` from this script block the new Chrome plugin / Computer Use path.

Do not copy cookies, write `.env` credentials, store passwords, tokens, QR codes, SMS codes, verification codes, or private-message raw text. Third-party Xiaohongshu API tools such as `xhs-mcp`, OpenClaw `xiaohongshu-publisher`, and `xhs-toolkit` remain research candidates only. Do not use cookie-based direct publishing, automated comments, deletion, or engagement actions without a separate safety review.

## Daily Operations Loop

Morning:

- Open the Xiaohongshu creator note manager through the official Chrome plugin when available; otherwise use Computer Use on the signed-in Chrome window.
- Classify the run as `creator_ready`, `login_required`, `risk_prompt`, `tool_unavailable`, `ui_blocked`, `account_view_mismatch`, or `review_unknown`.
- If the visible creator account, total note count, or note list does not match known ChatType operating history, record `account_view_mismatch`. Do not treat "no ChatType rows in the current account view" as 0 impressions or 0 interactions.
- Only record metrics when the creator note list is actually visible. Missing metrics must be recorded as blocked/unknown, never as zero.
- Capture visible metrics for each ChatType note: views, comments, likes, saves, shares, and visible review/publish state.
- Read only public comments or public feedback summaries. Do not write private account data.
- Pick one experiment direction: low exposure, CTA, install friction, audience fit, result review, publish-break repair, draft verification, or runtime migration.

Evening:

- Based on the morning observation, refine the next Xiaohongshu post or draft.
- Prefer identifiable drafts over vague draft counts: title, body keywords, asset names, or visible preview must prove it is a ChatType draft.
- For file uploads and draft-save verification, use Computer Use.
- If static cards still have no distribution, prioritize a real screen-recorded demo before more static copy.
- Public publish/reply/delete/paid actions must stop at the final confirmation/risk boundary and report in Chinese unless the current run has explicit fresh authorization.

## Acceptance Criteria

Each daily run is accepted only when one of these outcomes is recorded in `operations-log.md`:

| Outcome | Evidence required |
| --- | --- |
| Metrics collected | Visible creator-manager rows or equivalent Chrome plugin page state for ChatType notes, with views/comments/likes/saves/shares recorded |
| Comments reviewed | Public comment count and non-sensitive feedback summary, or explicit "no public comments visible" |
| Draft verified | Draft title/body/asset/preview proves it is a ChatType draft; draft count alone is not enough |
| Publish/review state verified | Visible published row, review/pending state, or stable public/creator URL/state |
| Blocked safely | Exact blocker category and reason, with no invented zero metrics |
| Account view mismatch | Visible creator account or note list does not match known ChatType operating history; ChatType metrics stay blocked/unknown |
| Runtime migrated | Chrome plugin or Computer Use path is named, and old `chrome-auth` state is not used as the sole blocker |

## Success Metrics

Track these manually for the first 14 days:

| Metric | Target |
| --- | --- |
| GitHub stars | 50+ |
| Real installs or trial feedback | 10+ |
| Issues or discussions | 3+ |
| Xiaohongshu impressions | 5,000+ total |
| Xiaohongshu saves/comments/DMs | 100+ total |
| Directory submissions | 3+ submitted or listed |
| Technical discussion | At least one useful V2EX/HN/Product Hunt thread |

## Rules

- Do not ask for upvotes on Hacker News or Product Hunt.
- Do not launch Show HN as a fundraiser or landing-page-only post.
- Do not hide the private desktop-backend dependency.
- Do not promise enterprise stability, notarization, or long-term API compatibility until those are true.
- Do not buy paid directory placement until the free/social channels produce signal.
