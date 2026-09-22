# Fusion progress and first-person review

**English** | [繁體中文](FUSION_REVIEW.zh-TW.md)

After capture, a dedicated dark processing page replaces the camera HUD. Cyan particles and a progress ring illustrate reconstruction; the illustration uses a fixed 180 particles and never loads the scan into another renderer. Reduced Motion stops the animation, and background scenes pause it. The page scrolls on smaller screens and with larger text.

The page follows the app language preference: Traditional Chinese by default, English selectable on the home screen. Titles, work details, stages, elapsed time labels and accessibility descriptions are localized.

## Progress semantics

Five stages cover saving capture data, aligning camera views, checking image quality, fusing the cloud, and preparing results. Stage changes and progress come from the processing pipeline. The overall percentage uses stage weights, so it is **not a time estimate**. Elapsed time is shown instead of an invented countdown. Depth fusion reports processed/total frames, then changes its detail to filtering/saving. The animation does not advance progress. Capture automatically opens the result when processing and history saving finish.

## First-person playback

Photo/route playback places the viewer at the selected photo's camera position and looks along its recorded forward direction. Gravity keeps the horizon level; vertical views use the recorded camera up vector. There is no chase-camera offset. The orange camera frustum is hidden while following to avoid obstructing the scene. Following locks the camera even while paused. Use the overview control or turn off first person to orbit/pan freely; scrubbing or starting playback resumes synchronization with the displayed photo.

This is a point-cloud perspective preview, not a pixel-perfect overlay of the photograph. The original photos, intrinsics and COLMAP camera coordinates remain unchanged.

## Safer final export

Mobile fusion filters cells into an acceptance bitset (one bit per cell), then samples supported cells into the output budget while releasing each consumed voxel shard. Filtering before sampling prevents rejected outliers from wasting the output budget. It does not flatten geometry or change the depth-agreement thresholds.

Cancellation and available-memory checks also run during filtering and output conversion, every 4,096 cells and before allocation. An interrupted export returns no partial result; capture keeps its saved fallback. Nonfinite input weights are rejected before they can contaminate fused positions/colors.

`refusion-progress.json` version 4 records `boundedExport` before work starts, the final grid resolution before export, `exportFilter` / `exportPoints` stages, export fraction and export duration. Older reports could say `boundedExport: false` while stopped in export because that flag had not yet been persisted; this did not prove the phone used unbounded export.

Capture saves `fusion-input-poses.jsonl` before fusion. These poses are diagnostic/reprocessing input only; they must **not** be paired with a fallback cloud. Preview continues to use its matching `review-poses.jsonl`. The refusion analysis tool prefers the new fusion input when present. History marks incomplete fusion as a fallback preview and offers the existing **Refine training data** action. Refining a history copy writes its fusion report into the new version, leaving the source report unchanged.

## Verification and limits

Relevant tools are `test_playback_camera.swift`, `test_fusion_export.swift`, `test_lidar_consistency.swift`, `test_large_scan_memory.swift`, `test_stop_processing.swift`, `test_scan_library.swift`, `test_training_quality.sh`, and `test_localization.sh`. The memory fixture includes 1,000 depth frames. Unsigned iPhone and Simulator builds and both language layouts are checked.

For repeatable UI inspection, Debug builds accept `--preview-fusion` and show an explicitly synthetic 399-frame progress fixture. Release builds do not include this launch route.

Desktop replay and synthetic pressure tests cannot establish why an iPhone was terminated or guarantee crash-free processing. A device crash/Jetsam report and a repeat run are needed to confirm that failure. Compare recovered full fusion separately from a pre-fusion checkpoint. Local planar-patch thickness is an internal consistency metric that can include furniture and real layers; it is not absolute dimensional accuracy.
