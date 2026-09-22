# Repository working agreement

**English** | [繁體中文](AGENTS.zh-TW.md)

## Delivery workflow

The repository owner has requested this default workflow for authorized code changes: finish implementation and validation, commit, push a task branch, open a pull request targeting `main`, merge after required checks/reviews pass, delete the task branch remotely and locally, and return to an up-to-date `main`. A later explicit user instruction overrides this default. Do not stop after only proposing a PR when delivery is authorized.

1. Inspect working-tree changes and repository instructions. Preserve unrelated work. Fetch `origin`, and start from updated `main` when the worktree can be switched safely.
2. Use one of these **case-sensitive** branch prefixes with a lowercase hyphenated description:
   - `Feature/`: a new user capability, e.g. `Feature/scan-search`.
   - `Bugfix/`: a defect fix, e.g. `Bugfix/playback-orientation`.
   - `Enhance/`: improvements to existing behavior, performance, UX, docs, or maintenance, e.g. `Enhance/bilingual-ui-docs-workflow`.
   Do not use `codex/`, lowercase variants of the prefixes, or a long-lived extra branch for routine work.
3. Implement the complete requested scope and update both documentation languages. Check the final diff for unrelated changes, scan data, secrets, and build output.
4. Run checks appropriate to the change. For Swift app changes, build unsigned iPhone and Simulator targets sequentially. Run relevant regression tools; localization/documentation changes also run `python3 tools/check_project.py` and localization tests. State limits of synthetic/simulator evidence.
5. Commit with a concrete English subject (`feat:`, `fix:`, `enhance:`, or `docs:`), push the branch, and open a PR. Explain the final behavior, important tradeoffs, tests, and outstanding device verification in English first with a Traditional Chinese summary. Attach the PR to the current task when the app provides an attachment tool.
6. Inspect PR mergeability and required checks/reviews. Fix failures, rerun affected checks, and update the PR. Merge the verified head, normally with squash. Never directly push to `main`, use administrator bypass, disable protections, or bypass required reviews. If an external gate blocks merging, report the exact gate and leave the PR/branch intact.
7. After confirmed merge, delete **only this task's branch** from `origin` and locally, update `main` with fast-forward only, and prune stale tracking refs. A squash-merged local branch may need `git branch -D`, but only after verifying the PR's merged head and a clean worktree. Do not delete unrelated branches/worktrees or unmerged work.
8. Report the PR link, merge commit, major changes, validation, and final branch state. Never claim merge or cleanup before verifying them.

## Languages and compatibility

- Documentation: English primary (`README.md`, `docs/NAME.md`), complete Traditional Chinese counterpart (`README.zh-TW.md`, `docs/NAME.zh-TW.md`). Link both directions and link within the same language.
- App UI: Traditional Chinese by default, English selectable on the home screen; persist the preference. Use `L10n` and both `en.lproj` / `zh-Hant.lproj` resources for user text, interpolated messages, accessibility, errors, and progress. Keep machine-readable identifiers independent of language.
- Local project, scheme, and repository name: `arkit-3dgs-scanner`. Preserve bundle ID `itri.fable` for installation/data continuity.
- Write `capture-meta.json`; continue reading legacy `meta.json` and preserve metadata bytes during export migration.
- Preserve original scan images/depth. Motion estimates alone are not measured blur; keep warning policy distinct from depth-fusion eligibility.
- Do not reintroduce phone Gaussian training without a new request. The app prepares datasets for external training.

See [contribution workflow](CONTRIBUTING.md) and [localization](docs/LOCALIZATION.md) for commands and coverage.
