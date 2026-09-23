# Pose refinement and photo-alignment validation

**English** | [繁體中文](POSE_REFINEMENT.zh-TW.md)

After capture, the phone refines ARKit camera poses for the exported 3DGS dataset. Refinement is applied only when the photos themselves confirm it. Poses that fail validation are left unchanged. These sampled checks reduce the risk of a regression; they do not guarantee absolute accuracy or better results from every 3DGS trainer.

## Pipeline

1. **ARKit anchors.** Each keyframe places an `ARAnchor`; stopping reads back the anchors that ARKit's map optimization moved. In one 569-frame replay this corrected poses by a median 38 mm (maximum 108 mm), and revisit surface offsets fell from about 45 mm to 11 mm. This stage is unchanged.
2. **Feature stage.** Saved photos are matched against recent frames and four route anchors. A joint bundle adjustment with ARKit motion priors and verified loop closure follows (see below).
3. **Feature photo check.** Validate the feature stage immediately, before computing anything from its candidate poses. Rejection preserves the input and skips the local stage.
4. **Local pilot** (only with experimental surface reconstruction). Try at most 48 intermediate frames spread across the full route, using the same fixed anchors and depth point-to-plane solve as the full [surface alignment](SURFACE_RECONSTRUCTION.md). If no correction is reliable, or the pilot fails the photo check (including insufficient overlap), keep the accepted feature poses. The pilot never becomes a partially corrected output trajectory.
5. **Full local stage and final photo check.** Run the complete local pass only after the pilot passes; it must then pass a separate photo check. A pilot already covering every eligible frame is reused. TSDF reconstruction still runs if the local pose stage is skipped or rejected. Fusion, preview and COLMAP export use the same final poses.

## Photo-alignment check

Held-out feature tracks share the matcher and LiDAR depth used by the solver, so they cannot see errors that the solver itself introduces. In replays of the previous pipeline, bundle adjustment passed its holdout (5.78 → 5.42 px), yet photos of adjacent frames lined up worse. `PhotometricPoseValidator` therefore measures whether image texture agrees between overlapping frames. Its NCC score is a proxy for photo alignment, not the complete loss used by a 3DGS trainer.

- **Pairs.** Pairs are chosen from the poses that would be replaced. There are up to 40 adjacent pairs (less than 1 s apart) and up to 40 wide pairs (0.25–0.8 m apart, similar viewing direction, at least 1.5 s apart). Only pairs involving a frame the candidate moved are scored; a pair of two unmoved frames scores the same under both pose sets and would dilute the result.
- **Samples.** From the source frame, LiDAR pixels are taken that are within 4 m, high confidence, and not on a depth edge; only the most textured 30% are kept. Each sample is projected into the target frame's 960 px grayscale photo and must agree with the target depth within max(3 cm, 1.5%). Both pose sets use the same samples, and the score is normalized cross-correlation (NCC).
- **Projection retention.** Count all input-valid textured samples before testing the candidate. At least 95% must remain valid overall, and at most 15% of evaluated pairs may retain less than 90% or fall below 400 common samples. Border/occlusion changes may affect a few pairs, so one low-retention pair alone does not reject a scene. A completely lost pair remains a negative observation rather than silently disappearing.
- **Decision for the first stage.** Per-pair NCC changes receive a `0.1 × lost fraction` penalty. A pair with fewer than 400 common samples gets a negative effective change of at least 0.02. The median effective adjacent change may drop by at most 0.002, no more than 15% of scored adjacent pairs may have raw NCC drops above 0.02, and the median effective wide-baseline gain must be at least +0.003. At least 8 adequately sampled pairs of each kind are required. Raw NCC and penalized changes are reported separately.
- **Stage order.** The feature stage is checked against the input poses. The local surface stage is then checked against the accepted feature stage, and it only needs to avoid harm (wide change at least −0.002). If the feature stage is rejected, the local stage built on it is discarded as well.

`pose-refinement.json` version 5 introduced `photometric` (per-stage pair counts, median NCC before and after, median changes, adjacent pairs worse, time) and `appliedStage`. The new statuses are `photometricValidationRejected` and `photometricValidationInsufficient`; both keep the original camera positions and show a localized notice. Version 6 adds `localSurfacePilot` and `localSurfaceSkippedReason`; photo reports add `baselineSamples`, `retainedSamples`, `minimumRetainedFraction`, `lowRetentionPairs`, `evaluatedPairs` and effective NCC deltas. Older reports remain readable. The pilot is a conservative shortcut: it can miss a useful local correction outside the sample; it preserves accepted input poses in that case.

## Bundle adjustment

- **Depth noise model.** A feature's LiDAR depth residual is divided by σ(d) = 5 mm + 2.2 mm × d², giving 7 mm at 1 m, 14 mm at 2 m, 25 mm at 3 m, and 40 mm at 4 m, with a Huber threshold at 2σ. The previous fx/d scaling treated depth as accurate to about 1.5 mm at 2 m. Replays measured frame-level LiDAR offsets of about 1 cm, which each frame absorbed along its view ray.
- **Joint solve with ARKit motion priors.** All usable frames are solved together in capture order.
  - Consecutive keyframes up to 0.5 s apart regularize changes to ARKit's relative motion with prior scales of 0.3 mm and 0.01° per step. These are solver weights, not hard error bounds or measured accuracy.
  - A weak pull (5 cm, 1°) toward the input poses fixes the global frame.
  - Each of 30 Gauss–Newton iterations re-derives landmarks from LiDAR and solves a block-tridiagonal system whose memory grows linearly with frame count, using Levenberg–Marquardt damping. Each step is limited to 5 cm and 0.02 rad.
  - Frames with few features move with their neighbours instead of staying behind. Gaps longer than 0.5 s, such as after lost tracking, break the prior chain.
- **Structure.** Landmarks remain the mean of LiDAR back-projections, which keeps them metric. Re-estimating landmarks from reprojection is available as `optimizeTracks`, but it is off. With a looser prior it absorbed a synthetic along-ray shift (1.59 → 2.27 cm). With the final prior it reached 0.60 cm against 0.55 cm for LiDAR means, and it brought no gain on real scans.
- **Holdout gate.** The held-out track gate (−3%) and the 15 cm / 5° correction limit still apply before the photo-alignment check.
- `BundleAdjuster.Options.legacy` keeps the previous per-frame solver for comparisons.

## Replay evidence

The following table records the version 5 desktop replays of two iPhone 17 Pro scans, before adaptive pilots and projection-retention checks. NCC changes are medians against the scan's saved poses; there is no ground truth.

| | 7F2187 (399 frames, close range) | 9F8040 (569 frames, room) |
| --- | --- | --- |
| Previous pipeline: adjacent / wide NCC change | −0.0194 (20 of 40 worse) / +0.0118 | −0.0315 (27 of 40 worse) / −0.0030 |
| Previous pipeline: photo check | rejected | rejected |
| New pipeline: adjacent / wide NCC change | +0.0073 (4 of 40 worse) / +0.0206 | +0.0021 (0 of 40 worse) / +0.0231 |
| New feature-stage held-out tracks | 5.78 → 4.36 px | 5.98 → 5.20 px |
| Local surface stage vs. feature stage | rejected: adjacent −0.067 (20 of 20 worse) | rejected: adjacent −0.043 (29 of 40 worse) |
| Mac replay time, previous → new | 7.8 → 10.6 s | 15.8 → 19.2 s |

- **Parameter sweeps** (30 iterations, feature stage only).
  - Priors of 1 mm / 0.05° (plus 1% of each step), 0.5 mm / 0.02°, 0.3 mm / 0.01°, and 0.1 mm / 0.003° gave wide gains of +0.016 / +0.019 / +0.021 / +0.014 (7F2187) and +0.015 / +0.019 / +0.023 / +0.019 (9F8040).
  - With the first prior, 6 iterations gave +0.012 / +0.014. With the chosen prior, 60 iterations did not improve on 30.
- **Options compared directly with the default output.** Full-resolution sub-pixel feature positions (Förstner refinement, 0.18 px worst error on synthetic corners), matching against eight recent frames and eight anchors, and optimized landmarks all changed wide-baseline NCC by less than ±0.003. Longer tracks also took 50–60% longer. All three remain off (`subpixelFeatures`, `recentMatchFrames`/`anchorFrames`, `optimizeTracks`).

## Tools and tests

```sh
bash tools/test_pose_refinement.sh   # BA (19), feature index/sub-pixel (7), photo check (12)
swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,TrainingFrameSelector,OfflinePoseRefinement,LocalSurfaceRefiner,LoopClosureRefiner,FeatureTracker,BundleAdjuster,PoseRefiner,PhotometricPoseValidator}.swift \
  tools/replay_pose_refinement.swift -o /tmp/replay_pose_refinement
/tmp/replay_pose_refinement refine SCAN OUT.jsonl [--no-surface] [--poses FILE]
/tmp/replay_pose_refinement compare SCAN INPUT.jsonl CANDIDATE.jsonl
```

The replay tool reads a scan without modifying it. The environment switches `BA_LEGACY`, `BA_JOINT`, `BA_TRACKS`, `BA_SUBPIXEL`, `BA_RECENT`, `BA_ANCHORS`, `BA_ITER`, `BA_PRIOR_T`, `BA_PRIOR_R_DEG`, `BA_PRIOR_FRACTION`, and `BA_HOLDOUT=0` reproduce the comparisons above.

- The BA tests keep the original per-frame cases under `.legacy`.
- They add ARKit-like smooth drift (0.80 cm / 0.43° → 0.22 cm / 0.00°, with adjacent motion error 1.4 → 0.5 mm, compared with 2.9 mm for the per-frame solver) and an along-ray shift.
- They also cover exact poses, junk matches, a noise-only holdout, a dense check of the block-tridiagonal solve, and correction round trips.
- Independent per-frame jumps of 3 cm contradict ARKit's local accuracy; by design they are only partly corrected (2.94 → 2.46 cm).

## Limitations

- The evidence covers two scans. NCC between keyframes measures photometric consistency, not absolute accuracy.
- Intrinsics, lens distortion, and rolling shutter are not modeled.
- The check needs overlapping, textured views; short or featureless scans keep ARKit poses.
- iPhone timing and memory for the added iterations and checks have not been measured.
- The pilot may skip local refinement if its changes cannot be validated, while TSDF still reconstructs surfaces. Both a pilot and a full pass must pass checks before local poses are applied.

## Adaptive-stage replay (2026-09-23)

Against saved review poses in the same two scans, the final feature poses remain byte-identical to version 5. Feature photo checks retain 98.15% / 98.31% of baseline-valid samples and pass the retention-aware gate. The pilot attempts 48 frames in each scan (instead of a full 244 / 497 eligible intermediate frames); its 3 / 15 depth-accepted corrections fail the subsequent photo check and are not applied. Single-pass desktop pose times were 11.21 → 8.34 s and 20.28 → 13.83 s, including the pilot and validation. Cache state affects these numbers; they are not phone timings. Local pilots still retain at most three image/depth frames. Full-pass success, failure and cancellation retain the existing final photo gate and original-pose rollback.
