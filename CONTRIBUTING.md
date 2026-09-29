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
bash tools/test_metric_loop.sh
bash tools/test_fusion_memory.sh
xcodebuild -project arkit-3dgs-scanner.xcodeproj -scheme arkit-3dgs-scanner \
  -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project arkit-3dgs-scanner.xcodeproj -scheme arkit-3dgs-scanner \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Run device and Simulator builds sequentially to avoid sharing a locked build database. Choose further regressions for the affected subsystem; do not claim sensor accuracy from compiler or synthetic tests. Swift command-line tools calling localized code must include `Capture/Localization.swift` in their sources. Resources fall back to Chinese source text if a standalone binary has no app bundle.

Documentation is English first with a matching `.zh-TW.md` page. App UI defaults to Traditional Chinese with an English setting. See [localization conventions](docs/LOCALIZATION.md). Keep raw scan samples, private images, credentials, and generated build output out of commits.

## Code layout

```text
arkit-3dgs-scanner/Capture/    AR session, keyframes, fusion, pose refinement, image selection, export
arkit-3dgs-scanner/History/    Scan storage, playback, refinement, and deletion
arkit-3dgs-scanner/Training/   On-device 3DGS: Metal kernels, trainer, memory plan, checkpoints, export, viewer and UI
tools/                         Dataset conversion, analysis, and regression tests
docs/                          Architecture, coordinate conventions, quality, and performance
```

The `arkit-3dgs-scanner` scheme runs an optimized Release build; use `arkit-3dgs-scanner-Debug` only for source-level debugging, because Debug fusion and training are much slower (see [fusion diagnostics](docs/SCAN_FUSION_DIAGNOSTICS.md)). `Training/` is a new Swift and Metal implementation; the earlier msplat C++ engine, its bridge, and its build settings are not used. Capture and dataset preparation do not depend on the trainer.

## Optional Python tools

```sh
python3 -m venv .venv
.venv/bin/pip install -r tools/requirements.txt
.venv/bin/python tools/test_math.py
.venv/bin/python tools/validate_dataset.py /path/to/scan
.venv/bin/python tools/arkit2gs.py /path/to/scan -o /path/to/dataset --format both
```

## License

Contributions are accepted under the project's [Apache License 2.0](LICENSE). Keep [NOTICE](NOTICE) intact, and give new 3DGS source files the same `SPDX-License-Identifier` header.

## PR and merge

Commit subjects should describe the change in English with `feat:`, `fix:`, `enhance:`, or `docs:`. PRs explain the problem, resulting behavior, verification, and limitations; use English first and add a Traditional Chinese summary. When using `gh`, put multiline descriptions in a file and pass `--body-file`. Leave AI tool attribution out of commits and PRs ("Generated with Claude Code" lines, AI `Co-Authored-By` trailers).

Push the task branch, create the PR, check required statuses/reviews, and merge the exact verified head (normally squash). If main changes in a way that affects the patch, update the branch and rerun relevant checks. Do not use `--admin`, disable rules, or directly push main.

After confirmed merge, return to main, pull with `--ff-only`, remove the task branch on origin and locally, and fetch/prune. Verify the merged PR before force-deleting a squash-merged local branch. Finish with the PR link, merge commit, changes, test results, and branch cleanup status.
