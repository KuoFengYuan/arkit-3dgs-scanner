# Contributing

**English** | [繁體中文](CONTRIBUTING.zh-TW.md)

Use the owner's [working agreement](AGENTS.md). Deliver changes through a PR to `main`; merge after required checks and reviews, then remove the task branch locally and remotely. Do not bypass repository protections. If a gate prevents completion, leave the PR open and report it.

## Branch names

| Prefix | Purpose | Example |
| --- | --- | --- |
| `Feature/` | New capability | `Feature/scan-search` |
| `Bugfix/` | Defect repair | `Bugfix/playback-orientation` |
| `Enhance/` | Existing behavior, performance, UI, docs, maintenance | `Enhance/bilingual-ui-docs-workflow` |

Prefixes are case-sensitive. Use a lowercase hyphenated description. Start from updated `main` after preserving unrelated local work; never delete unrelated branches.

## Validation

```sh
python3 tools/check_project.py
bash tools/test_localization.sh
bash tools/test_training_quality.sh
bash tools/test_gaussian_training.sh
xcodebuild -project arkit-3dgs-scanner.xcodeproj -scheme arkit-3dgs-scanner \
  -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project arkit-3dgs-scanner.xcodeproj -scheme arkit-3dgs-scanner \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Run device and Simulator builds sequentially to avoid sharing a locked build database. Choose further regressions for the affected subsystem; do not claim sensor accuracy from compiler or synthetic tests. Swift command-line tools calling localized code must include `Capture/Localization.swift` in their sources. Resources fall back to Chinese source text if a standalone binary has no app bundle.

Documentation is English first with a matching `.zh-TW.md` page. App UI defaults to Traditional Chinese with an English setting. See [localization conventions](docs/LOCALIZATION.md). Keep raw scan samples, private images, credentials, and generated build output out of commits.

## License

Contributions are accepted under the project's [Apache License 2.0](LICENSE). Keep [NOTICE](NOTICE) intact, and give new 3DGS source files the same `SPDX-License-Identifier` header.

## PR and merge

Commit subjects should describe the change in English with `feat:`, `fix:`, `enhance:`, or `docs:`. PRs explain the problem, resulting behavior, verification, and limitations; use English first and add a Traditional Chinese summary. When using `gh`, put multiline descriptions in a file and pass `--body-file`.

Push the task branch, create the PR, check required statuses/reviews, and merge the exact verified head (normally squash). If main changes in a way that affects the patch, update the branch and rerun relevant checks. Do not use `--admin`, disable rules, or directly push main.

After confirmed merge, return to main, pull with `--ff-only`, remove the task branch on origin and locally, and fetch/prune. Verify the merged PR before force-deleting a squash-merged local branch. Finish with the PR link, merge commit, changes, test results, and branch cleanup status.
