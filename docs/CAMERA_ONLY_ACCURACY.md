# ARKit and camera-only reconstruction quality

**English** | [繁體中文](CAMERA_ONLY_ACCURACY.zh-TW.md)

## Live capture safeguards

The earlier no-LiDAR path omitted translational blur when depth was absent and repeatedly inserted all raw features as gray voxel points. Repeated estimates could vote multiple times or leave unstable layers; rotation alone could trigger frames without useful baseline.

The current path adds four checks:

1. `PoseContinuityGate` checks each pose. Translation above `max(8 cm, 3 m/s × dt)`, rotation above `max(15°, 4 rad/s × dt)`, or a gap over 0.25 seconds requires 0.6 seconds of stable tracking again. It controls acceptance, not ARKit's internal pose estimator.
2. `CameraOnlyGeometry` projects with the ARKit/OpenGL -Z forward convention and rejects behind-camera, out-of-bounds, invalid-distance, and nonfinite features. At most 512 points are sampled on the main thread. With at least six central points, the near depth quartile estimates distance; otherwise 0.5 m is used for translational blur rather than assuming zero motion blur. This estimate does not produce a LiDAR distance warning.
3. RGB capture needs at least 12 visible sampled features across at least three cells of a 3×3 grid. Near-range translation is `min(5 cm, max(4 cm, depth × 0.05))`; rotation triggers still require 4 cm translation. The first valid frame establishes a baseline. Minimum interval is 0.10 seconds. LiDAR can use a 2 cm near-range floor; both modes keep quality and write-backpressure checks.
4. `SparseLandmarkFilter` observes IDs every 0.2 seconds. Acceptance needs three observations, position variation within `2 cm + distance × 1.5%`, at least 4 cm baseline and 1.5° parallax. Gaps over two seconds or position jumps restart the candidate. Tracking discontinuities change epochs. Each ID is fused once at its latest validated ARKit position rather than repeatedly weighting correlated estimates.

A background actor projects and colors sparse points from owned image buffers. Anchor-local tiles handle later coordinate corrections. Candidate IDs are capped at 20,000; accepted IDs at `maxPoints` (currently 600,000). At capacity, new IDs stop, but photos may continue. Expiry cleanup is throttled rather than scanning the full dictionary for each incoming ID.

## How to scan and interpret results

Disable LiDAR and move slowly sideways across textured surfaces. Avoid pure rotation, especially at close range. The HUD explains insufficient texture and baseline; RGB mode does not show LiDAR repeat-observation heatmaps or completion fractions.

White walls, reflections, short scans, and pure rotation may yield fewer points. If no points pass, photos remain viewable and the app asks for more lateral views. Thresholds in `CaptureConfig` are conservative starting values, not calibrated real-device accuracy guarantees.

Live sparse checks are not independent RGB triangulation and cannot remove all systematic ARKit feature errors. Accepted IDs are not continually replaced by later refined estimates; only tile-anchor correction applies. The separate reconstruction pass below also fixes ARKit poses and cannot remove systematic pose error.

## Image reconstruction after stopping

With LiDAR disabled, Image depth reconstruction defaults to enabled and can be disabled for a sparse-only comparison. The choice is fixed for the active scan, including resumed capture. After anchor-pose correction and blur review, `RGBReconstructionEngine` reads photos in the background. Only `.keep` frames participate; `.drop` and `.demote` are excluded.

Each batch retains three small images: one reference and two sources. Up to 24 references are uniformly selected; sources can come from the full eligible sequence. Cameras need 4 cm baseline, at most 30 cm source-to-reference distance, and roughly 20° maximum viewing-direction difference, preferring 12 cm baseline. This is conservative pose-neighborhood selection without global retrieval; no reliable overlap means no points for that reference.

Images are reduced to a 256-pixel long edge without upscaling, with scaled intrinsics and original sensor orientation. Dimension/calibration mismatch is rejected. Every five pixels, inverse-depth search spans 0.25–5 m, also constrained by point-cloud limits. Epipolar span determines 96–384 candidates followed by local refinement; excessively large searches are rejected rather than allocating a dense cost volume.

### Point acceptance

1. Reference/source 5×5 patches need brightness variance at least 0.0009 and reference texture in two directions. A single edge or stripe cannot sufficiently constrain a match.
2. Patches are projected through a frontoparallel reference plane and scored using ZNCC. Best NCC must reach 0.88, and cost separation from a competitor more than 1.5 pixels / 4% depth away must reach 0.06. Search endpoints and parallax below 1.5° are rejected.
3. Independently estimated depths from both sources must agree within 4%; the fused depth may shift projected source positions by at most 0.8 pixels.
4. Both sources must match back to the reference within 4% depth and 0.8 pixels. This rejects some occlusions, repeated textures, and inconsistent geometry.
5. Accepted points take reference-image color and confidence/distance weights for voxel fusion. Sparse points within one cell of RGB surfaces are omitted; other validated sparse coverage remains. Output respects `exportMaxPoints`.

Results feed `review.ply`, history, photo/path playback, COLMAP/PLY export, and training initialization. No artificial LiDAR depth files or depth-dependent BA are created. Deletion removes the entire scan, including the reconstruction report.

`capture-meta.json` includes optional `rgbReconstructionEnabled`; older metadata remain readable. `rgb-reconstruction.json` stores method, eligible frames, attempted/successful references, failures, observations, RGB/total point counts, reference IDs, sampling settings, and duration. Status can be `insufficientViews`, `insufficientBaseline`, `noReliableMatches`, or `reconstructed`. `decodedImages` counts decode operations, including repeated decodes of the same file.

### Limits

This is low-resolution, sampled, fixed-pose mobile MVS. It has no full SfM, global RGB BA, normal optimization, per-pixel depth maps, or hole-filling mesh. Beyond the 24 references, large scenes mainly retain sparse coverage. Reflections, white walls, motion, occlusion, perspective changes, and pose errors can still create gaps or false points. Frontoparallel patches reduce acceptance on steep surfaces. Device runtime, heat, and physical accuracy need measurement.

## Desktop replay against LiDAR

### Purpose

`tools/replay_camera_only.swift` measures camera-only mode on real LiDAR scans. It replays the camera-only pipeline and ignores the saved depth. The LiDAR data then provides the references. In camera-only mode, poses are ARKit poses plus keyframe-anchor readback; offline BA, loop closure and the photo check do not run because `baRounds` is 0 without LiDAR. Points come from fixed-pose MVS. `--candidate` accepts any pose file, so a future RGB-only bundle adjustment can be scored the same way.

1. **Simulated capture.** The baseline poses (default `review-poses.jsonl`, ARKit + anchors) are taken in timestamp order. A frame is kept when it is at least `cameraOnlyMinBaselineM` (4 cm) from the last kept frame and at least 0.10 s later. Depth fields are removed, and `BlurFilter.annotate` runs on the candidate poses, as the app does before MVS. `--all-frames` skips the subsampling.
2. **Poses** are compared with the reference on the simulated frames. The report gives raw (same world frame) position and rotation differences and the ATE after a best rigid alignment (Horn's quaternion method on camera centres). It also gives the Umeyama Sim(3) scale (above 1 means the candidate path is larger) and the relative pose error over 1 m and 5 m of reference path.
3. **Photo alignment** uses LiDAR depth, independent of the camera-only pipeline. `PhotometricPoseValidator` compares camera-only poses with the reference (and with the candidate) on the same depth-bearing frames.
4. **LiDAR reference cloud.** The default fusion filters run with the reference poses on all frames. Capacity is raised to 2,000,000 points and a 512 MB working set, so the phone limits of 250,000 points and 96 MB do not coarsen it.
5. **MVS** (`RGBReconstructionEngine`) runs twice on the depth-free frames. The run with reference poses isolates MVS quality; the run with candidate poses measures the end-to-end result. Both runs use the same blur verdicts.
   - Accuracy is the distance from each MVS point to the nearest LiDAR point, capped at 10 cm.
   - Completeness is the fraction of LiDAR points with an MVS point within 2, 5 and 10 cm.
   - Completeness is also reported for the LiDAR points "viewed" by the run's contributing reference frames. A point counts as viewed when it lies in the depth image, has a camera depth of 0.25–5 m, and agrees with that frame's LiDAR depth within max(3 cm, 3%). A low overall value with a high viewed value means too few reference views; low values in both mean too few points per view.

Reference poses come from the app's LiDAR BA and photo check through `replay_pose_refinement`; its build command is in [pose refinement](POSE_REFINEMENT.md).

```sh
/tmp/replay_pose_refinement refine SCAN /tmp/ref.jsonl --no-surface
swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,TrainingFrameSelector,PhotometricPoseValidator,RGBStereoMatcher,RGBReconstructionEngine}.swift \
  tools/camera_only_metrics.swift tools/replay_camera_only.swift -o /tmp/replay_camera_only
/tmp/replay_camera_only SCAN WORK_DIR --reference /tmp/ref.jsonl \
  [--baseline FILE] [--candidate FILE] [--all-frames] [--no-mvs] [--reference-voxel M]
```

The tool reads the scan without modifying it. `WORK_DIR` must not exist and must lie outside the scan. It receives `camera-only-replay.json` (report version 1, with timings), `reference.ply`, `mvs-reference-poses.ply`, `mvs-candidate-poses.ply` and `refusion-progress.json`. The work directory holds temporary hard links to the scan's images and depth, which are removed at the end. `--no-mvs` skips the reference cloud and MVS. `--reference-voxel` is a diagnostic that changes only the fusion voxel of the reference cloud.

### Measured on two iPhone 17 Pro scans

Default settings. The reference poses came from `replay_pose_refinement refine --no-surface`, whose photo check accepted them on both scans. The camera-only poses are `review-poses.jsonl` (ARKit + anchors; neither scan applied a BA correction there). All values are differences from the LiDAR reference, not errors against ground truth. MVS rows list the run with reference poses first and the run with camera-only poses second, separated by "vs" (or by "/" where each run has one value). Photo NCC values are medians before → after, with the median per-pair change in parentheses.

| | 7F2187 (close range, fast motion) | 9F8040 (room scale) |
| --- | --- | --- |
| Saved → simulated camera-only → MVS-eligible frames | 399 → 277 (46 s) → 194 (83 dropped by blur review) | 569 → 372 (113 s) → 261 (111 demoted) |
| Raw position difference median / P95 / max | 1.0 / 3.0 / 3.7 cm | 1.8 / 2.9 / 3.8 cm |
| Raw rotation difference median / P95 / max | 0.34 / 0.72 / 0.81° | 0.31 / 0.65 / 1.38° |
| Aligned ATE RMSE / median; aligned rotation median | 1.3 / 0.8 cm; 0.40° | 1.4 / 1.1 cm; 0.38° |
| Sim(3) scale (camera-only / reference) | 1.0002 | 1.0027 |
| RPE 1 m: translation median / P90; rotation median | 1.2 / 2.4 cm (1.25 / 2.40%); 0.38° | 1.4 / 2.2 cm (1.41 / 2.19%); 0.37° |
| RPE 5 m: translation median / P90; rotation median | 1.8 / 3.3 cm (0.35 / 0.66%); 0.42° | 2.7 / 4.5 cm (0.54 / 0.89%); 0.49° |
| Photo NCC, camera-only → reference poses: adjacent; wide | 0.964 → 0.978 (+0.006); 0.848 → 0.895 (+0.023) | 0.988 → 0.990 (+0.003); 0.885 → 0.923 (+0.021) |
| Photo gate status on these frames | accepted | rejected (15 of 80 pairs lost too many samples; limit 12) |
| LiDAR reference cloud; median point spacing | 162,014 points; 1.32 cm | 620,246 points; 1.36 cm |
| MVS points; contributing references of 24 | 1,129 / 995; 23 / 22 | 218 / 216; 21 / 22 |
| MVS accuracy median / P90 | 1.25 / 4.44 cm vs 2.56 / 7.49 cm | 2.48 / 7.20 cm vs 3.10 / ≥10 cm (cap) |
| MVS points within 2 cm; beyond 10 cm | 70.3%, 2.4% vs 40.8%, 4.8% | 44.0%, 4.6% vs 35.6%, 11.6% |
| Completeness at 2 / 5 / 10 cm, all LiDAR points | 1.7 / 11.6 / 26.8% vs 0.8 / 7.6 / 24.3% | 0.05 / 0.7 / 3.4% vs 0.04 / 0.6 / 2.9% |
| Completeness at 2 / 5 / 10 cm, viewed points only | 1.9 / 12.2 / 28.2% vs 0.9 / 8.2 / 26.0% | 0.05 / 0.7 / 3.4% vs 0.04 / 0.6 / 3.0% |
| LiDAR points viewed by the contributing references | 91.5% / 90.2% | 94.3% / 95.1% |
| Mac replay time (8 cores): total; fusion; photo; MVS per run | about 7 s; 2.4 s; 1.7 s; 0.9 s | about 12 s; 5.9 s; 1.8 s; 0.6 s |

**Poses.** Camera-only poses differ from the LiDAR reference by 1–2 cm (median), up to about 4 cm, and about 0.3° (median). The difference per metre travelled is 1.2–1.4 cm. Over 5 m it is only 1.8–2.7 cm, so on these 16–20 m paths the difference does not grow steadily with distance. Photo alignment improves under the reference poses on both scans, mostly for wide-baseline pairs. On 9F8040 the validator's sample-retention rule still marks the subset "rejected", although its medians improve. The full 569-frame refinement passed that check.

**Points.** MVS density is the larger gap. The run produced about 1,000 points at close range and about 200 at room scale, and completeness within 5 cm stays at about 12% of the LiDAR surface or less. The contributing references view over 90% of that surface, so the limit is points per reference view, not the number of reference views. With reference poses, MVS points lie closer to the LiDAR surface (median 1.25 vs 2.56 cm and 2.48 vs 3.10 cm). At close range more matches also pass (1,129 vs 995 points). The pose differences therefore cost accuracy, and at close range also density. Part of the accuracy gap comes from scoring against a cloud built with the reference poses.

**`--all-frames` (7F2187).** Using all 399 saved frames (280 eligible) instead of the simulated 277 hardly changes the pose differences (RPE 1 m 1.3 cm, ATE RMSE 1.3 cm). MVS with reference poses gains points: 1,601 instead of 1,129, with 5 cm completeness of 14.8% instead of 11.6%. With camera-only poses the result stays at 1,003 points and 7.4% (was 995 and 7.6%). The accuracy medians stay about the same (1.26 and 2.44 cm).

**Reference spacing.** The default 2 cm fusion voxel leaves a median LiDAR point spacing of 1.3 cm, which is not far below the accuracy values. With `--reference-voxel 0.01` the spacing is 0.73 cm (7F2187, 714,180 points) and 0.81 cm (9F8040, which reached the 2,000,000-point cap). The accuracy medians then fall to 0.87 vs 2.25 cm (7F2187) and 2.21 vs 3.04 cm (9F8040), and completeness changes by less than 2 percentage points. Accuracy differences at the 1 cm level are therefore partly set by the reference density, not only by MVS.

### Limitations

- These scans were tracked by ARKit with LiDAR enabled. Apple does not document whether visual-inertial odometry uses LiDAR, so a phone without LiDAR, or with LiDAR off, may drift more than these poses.
- The reference is the app's LiDAR pipeline (BA + photo check, then depth fusion), not ground truth.
  - The reference BA starts from, and is regularized toward, the same ARKit poses, so it can miss errors that it cannot observe.
  - MVS with reference poses is scored against a cloud built with the same poses, which favours it.
- Live sparse ARKit features are not saved, so only MVS points are scored. The app's review cloud also keeps validated sparse points outside RGB surfaces.
- Subsampling approximates the RGB shutter (`SmartShutter` with `cameraOnly`). It omits the depth-scaled 4–5 cm translation threshold, the 3° rotation trigger, and the feature and pose-continuity gates. It can only choose among frames that the LiDAR shutter saved. `estimatedBlurPx`, which drives the blur review, was computed with LiDAR depth, whereas the live camera-only path uses feature depth or 0.5 m.
- Accuracy uses point-to-point distances, which include the reference point spacing (see above). Completeness depends on the reference point density.
- Candidate clouds are scored in their own world frame without alignment, and poses are compared both raw and aligned. A candidate whose gauge moves (for example a free RGB-only BA) is charged for the move in the raw values and in the MVS scores.
- The results cover two scans from one device. Statistics from about 200 MVS points (9F8040) are coarse.

## Regression commands

```sh
swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,Utils,SmartShutter,DepthSampleFilter,RefusionEngine,SurfaceTSDF,CameraOnlyGeometry,SparseLandmarkFilter}.swift \
  tools/test_camera_only_accuracy.swift -o /tmp/fable-camera-only-test
/tmp/fable-camera-only-test

swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,RGBStereoMatcher,RGBReconstructionEngine}.swift \
  tools/test_rgb_reconstruction.swift -o /tmp/fable-rgb-test
/tmp/fable-rgb-test

bash tools/test_camera_only_replay.sh   # replay metrics (32 checks) and a replay tool build
```

The replay metric checks cover the following synthetic cases:
- Identical, rigidly moved (30° and 150°), 2% scaled and 1 cm/m drifting trajectories.
- The Jacobi eigen solver and the hash-grid search against brute force.
- A plane offset by 1 cm (accuracy, half-plane completeness at 2/5/10 cm, masking), far outliers and point spacing.
- The viewed mask: visible, occluded, tolerance, out of image, low confidence and too near.
- Shutter subsampling.

Historical validation passed 29 RGB reconstruction checks, 26 camera-only quality/shutter checks, 18 fusion checks, and unsigned device/Simulator Debug builds. A pre-existing parallel refusion Sendable warning remains.

RGB fixtures render a textured 1.5 m plane under varying camera translations/rotations and brightness. Cases include slopes, pure rotation, white walls, one-/two-direction periodic texture, third-view occlusion/inconsistency, JPEG resizing/orientation, voxel merge, sparse fill, budgets, missing files, calibration mismatch, malformed poses, blur, duplicate frames, and legacy metadata.

Synthetic thresholds are median depth error below 1.5 cm, P95 below 4 cm, and sloped-plane median residual below 2.5 cm. These ideal known-pose regression limits do not predict device accuracy. Sparse tests verify acceptance/rejection, epochs, capacity, and shutter behavior rather than physical measurement.

For a device A/B, fix light, settings, and path; compare lateral motion, rotation, white walls, backgrounding/relocalization, accepted frames, coverage, known dimensions, and thickness. More points are not necessarily more accurate.

## References

ARKit [rawFeaturePoints](https://developer.apple.com/documentation/arkit/arframe/rawfeaturepoints) are intermediate tracking features; [identifiers](https://developer.apple.com/documentation/arkit/arpointcloud/identifiers) associate observations independently of array order. See also COLMAP's [known-pose reconstruction discussion](https://colmap.github.io/faq.html#reconstruct-sparse-dense-model-from-known-camera-poses). This app's matcher is an independent implementation, not integrated COLMAP/PatchMatch.
