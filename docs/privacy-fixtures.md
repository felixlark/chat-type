# Public examples and synthetic fixtures

ChatType's published tests and generated speech examples use fictional people,
organizations and portable paths. They must not be copied from a user's contacts,
dictation history, terminology dictionary or local account.

The name-recall fixtures deliberately include several distinct cases:

| Case | Synthetic input | Expected vocabulary |
| --- | --- | --- |
| Homophones remain separate candidates | 顾清和 | 顾清禾、顾青禾 |
| Similar-sounding spelling | 陶新蓝 | 陶星澜 |
| Explicit user correction | 周远洲 | 周远舟 |
| Contact remark with an organization | 周明轩 云城示例组织部 部长 | 周明轩、云城示例组织部 |
| English contact label | Alex Example | Alex Example |

These examples are test data. They are not measurements from a real user's
recording or address book. Speech-generation scripts use the same fictional
names and do not read private dictionaries to choose names for the corpus.

Published historical reports retain their original timing and outcome summaries.
Personal names and local usernames are removed, with anonymous labels used where
an error relationship matters. An anonymized summary is not a new transcription
or a fresh verification of the historical result.

This content cleanup does not migrate application identifiers, Keychain services,
signing identity, permissions, saved history, terminology data or keyboard policy.
Those compatibility-sensitive identifiers need their own migration and acceptance
work before they can change safely.
