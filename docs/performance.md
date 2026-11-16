# Historical ChatType transcription performance

These are historical measurements for the configurations recorded below, not a performance claim for the current candidate. Current defaults and failure behavior are maintained in [PRODUCT](../PRODUCT.md).

## Build 144: reuse alignment vocabulary across recordings

The production pipeline now retains the same filtered alignment arrays for an unchanged dictionary. Previously every recording rebuilt those arrays, invalidating the normalizer's storage-identity cache. The independent alignment cache retains its source array to preserve Swift copy-on-write semantics; changing entries, using an older recording snapshot, or selecting corrections off continues to select the corresponding data. It does not remove entries or change matching behavior.

A release-mode offline probe of the original 18,796-entry dictionary and one fixed transcript alternated six measurements per side. Rebuilding the array took 94.033–105.276 ms; reusing the warmed array took 17.812–20.253 ms. All twelve outputs matched. The host was busy (10 logical CPUs, load average about 269); this demonstrates a local cache opportunity, not an installed-app end-to-end speedup. Existing production records for four different recordings showed 91–143 ms normalization and 1,248–1,559 ms total post-stop processing. The independent cloud recognition and polish stages remain separate costs.

## 2026-08-04 baseline

The local latency log contained 1,418 successful paste/clipboard runs across several ChatType versions and configurations:

| Stage | p50 | p95 |
| --- | ---: | ---: |
| Total processing | 3,817 ms | 18,853 ms |
| ChatGPT transcription | 2,718 ms | 8,320 ms |
| Local normalization | 39 ms | 1,405 ms |
| AI Polish | 0 ms | 9,228 ms |

The historical set mixes runs with and without AI Polish and dictionaries of different sizes. The three runs immediately after the dictionary reached 15,407 entries were more diagnostic:

- normalization: 642–797 ms
- transcription: 1,089–2,820 ms
- AI Polish: 1,635–4,086 ms
- total: 3,710–6,058 ms

The large dictionary was therefore a real local bottleneck, but not the only or largest end-to-end stage. The old normalizer rebuilt and scanned exact and fuzzy rules for the full dictionary, then repeated normalization after AI Polish. Network transcription and rewrite latency remained the larger and more variable component.

## Upgrade

- Build a reusable candidate index for the current terminology dictionary.
- Compile and evaluate exact/fuzzy rules only for entries that can match the current transcript.
- Keep all stored entries available; candidate selection changes execution cost, not dictionary semantics.
- Send AI Polish only glossary entries relevant to the normalized transcript.
- Replace the `gpt-5.5` polish default with latency-balanced `gpt-5.6-terra`, set reasoning effort to `none`, and shorten repeated prompt instructions.
- Measure the real rendered prompt instead of estimating from a fixed 1,800-character constant.

The regression gate warms a 15,001-entry index and requires a representative normalization pass to finish in under 100 ms on the supported development Mac.

The final installed Developer ID build was exercised five times with the same 2.06-second synthetic mixed Chinese/English recording and the live 15,407-entry dictionary:

| Stage | p50 | p95 |
| --- | ---: | ---: |
| ChatGPT transcription | 1,399 ms | 2,696 ms |
| Local normalization | 71 ms | 203 ms |
| AI Polish | 1,569 ms | 1,756 ms |
| Total processing | 2,826 ms | 4,128 ms |

All five runs succeeded. This fixture is suitable for repeatable installed-build comparison, but its totals should not be compared as if they were the same workload as the heterogeneous historical latency log.

## API research decision

The API research note recorded the file-transcription guide recommending [`gpt-transcribe`](https://developers.openai.com/api/docs/guides/speech-to-text) for completed recordings and recommends Realtime transcription for audio that is still arriving. `gpt-transcribe` supports prompt, keyword, and language hints for domain terminology and code-switching.

At the time of this historical upgrade, ChatType's default path used a ChatGPT account and the private ChatGPT transcription bridge, not an OpenAI Platform API key. Moving the default to `/v1/audio/transcriptions` or Realtime would introduce a new credential and transport architecture. This upgrade therefore keeps the no-key default path and improves its measured local and rewrite stages. The public `gpt-transcribe` route remains an explicit future product migration rather than a silent provider switch.
