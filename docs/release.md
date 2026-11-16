# Build, install and release

Current product behavior is defined by [PRODUCT](../PRODUCT.md). Diagnosis and installed-app acceptance belong to [operations](operations.md). Historical version checklists are not current defaults.

## Checks and one package

The source checks build the executable through Swift test, run Swift and Python tests, validate shell syntax, enforce operational policy and check the landing page. CI invokes this same command; it does not require developer signing credentials or operate the GUI.

```bash
./scripts/check.sh --source
```

Build one candidate and inspect that same package. `version.env` owns version/build metadata. Packaging uses the pinned Opus codec and a stable Apple signing identity; ad-hoc signing is restricted to explicit disposable debugging.

```bash
./scripts/package_app.sh
./scripts/check_packaged_app.sh --existing
./scripts/install_app.sh
open -g /Applications/ChatType.app
```

Alternatively, `./scripts/check.sh` combines source checks with one package/check pass. Do not run an extra package command after it unless the candidate changed. `script/build_and_run.sh` remains the existing local build/install/launch convenience entry; the installer stops the old process only when replacing the app.

## Installed acceptance

Run the smallest affected journey through official Computer Use at `/Applications/ChatType.app`, using background access where supported and preserving human windows and drafts. Never validate live permissions from `dist` or a raw executable. macOS GUI tests may not drive product windows.

Check candidate version, signing identity and enrolled local F5 policy; follow the applicable matrix in operations. Record checks, packaged, installed, live accepted and left running independently. Optional overlay demo captures are supporting visual evidence, not proof of microphone, Retry, login or paste behavior. Restore the normal installed runtime even after an acceptance failure; leave Settings visible when that journey can be safely exercised.

```bash
./scripts/visual_acceptance.sh
./scripts/doctor.sh
```

The visual script's `--install` option builds/installs its own candidate; use it only when that is the intended single release build. Final closeout leaves the normal installed app running.

## Public releases

When publishing a version, align version.env, both READMEs, CHANGELOG, release notes, GitHub Pages download links and the Homebrew cask with the exact package. Keep signing/notarization claims factual; local signature validity is not notarization. Current signing validation remains separate from any public distribution approval.

Public copy follows the current independent ASR/polish selection and private-backend disclosure. [Promotion](promotion/README.md) owns distribution material. External posting requires its own existing authorization and current platform skill; repository cleanup never sends a post. Retired `post_x.sh` was an instruction-printing placeholder, not a release mechanism.

If macOS blocks an otherwise verified authorized build, use the operating system's Open action and diagnose the actual Gatekeeper/signing result. Do not replace TCC or signing evidence with a blanket quarantine-removal instruction. Installed permission repair must retain the product's stable signing identity.

## Rollback

Retain the prior verified signed package and its candidate identity before replacement. Revert the affected cleanup commit, package/install the previous source candidate and repeat the changed installed journey. Do not delete configuration, vocabulary, credentials, recordings or recovery history. A future storage-format migration requires its own explicit backward-read and data recovery strategy.
