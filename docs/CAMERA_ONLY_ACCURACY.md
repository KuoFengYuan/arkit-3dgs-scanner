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

`RGBReconstructionEngine` runs known-pose PatchMatch multi-view stereo (MVS). Earlier versions used a sampled two-source matcher with frontoparallel patches; see the comparison under [measured results](#measured-on-two-iphone-17-pro-scans).

### Views and sources

1. **Views.** Up to 48 frames (`rgbMaxReferenceFrames`) are chosen evenly along the eligible sequence. The capture shutter already spaces frames by motion. Each is decoded once at a 320-pixel long edge (`rgbMaxImageDimension`) without upscaling, with scaled intrinsics and the original sensor orientation. Dimension/calibration mismatches are rejected. Decoding runs in parallel.
2. **Sources.** Every view is both a reference and a source for the others. Its up to four sources (`rgbSourceViews`) are chosen by geometry, without image retrieval:
   - candidates must be at least 4 cm away and face within 45°;
   - they are scored on 36 sample points of the reference (a 4×3 pixel grid at 0.7, 1.4 and 2.8 m) that they see: the triangulation-angle weight rises from 1° to 5°, stays flat to 25°, and falls to 0 at 45°;
   - near-duplicate positions (within 2 cm of a chosen source) are skipped, so the sources span different baselines.

   A view with fewer than two sources produces no depth.

### Depth maps (PatchMatch)

For every second pixel (`rgbPixelStride`), a depth and a surface normal are estimated.
- **Texture gate.** A pixel needs a 5×5-sample patch (9×9 pixels, samples two pixels apart) with a brightness standard deviation of at least 0.012 (`rgbMinPatchStd`) and gradients in two directions. White walls and single stripes produce no depth.
- **Cost.** The patch is warped into each source through the hypothesised plane (a homography), so slanted floors and walls match. Each source is scored by bilateral-weighted zero-mean normalized cross-correlation (ZNCC); the weights keep a foreground edge from pulling in the background. The cost is the mean of the best half of the sources, so one occluded source does not veto a visible surface.
- **Search.** Hypotheses start random within 0.25–5 m, facing the camera within 75°. Four sweeps alternate direction. Each pixel tries its already-visited neighbours' planes (propagation), then coarse and fine depth steps, a normal perturbation, and both combined, with steps halving every sweep. Every view has its own random seed, and results do not depend on thread scheduling.
- **Photo acceptance.**
  - The aggregated cost must be at most 0.35 (`rgbMaxMatchCost`).
  - At least two sources must match individually with at least 1.5° of parallax.
  - Uniqueness: along the best source's epipolar line, within ±16 pixels of the match (excluding ±2 pixels), no other depth may score within 0.05 (`rgbUniquenessMargin`). This rejects repeated textures such as tiles and grilles, which otherwise produce layered ghost surfaces.

### Multi-view consistency and fusion

- **Neighbours.** A view's depth is kept only where at least two neighbouring depth maps (`rgbConsistentViews`) reach the same surface independently. The neighbours are the view's sources and the views that used it as a source.
- **Check.** The point is projected into the neighbour, and the neighbour's depth at that pixel is projected back. It must land within stride + 1 pixels and within 1% depth (`rgbConsistencyDepthRatio`).
- **Fusion.**
  - Accepted points are the average of the agreeing estimates. They take the reference color and are weighted by match quality, the number of agreeing views, and distance.
  - They are inserted view by view into the 2 cm voxel grid. Sparse points within one cell of RGB surfaces are omitted; other validated sparse coverage remains. Output respects `exportMaxPoints`.

### Output, reports and cost

Results feed `review.ply`, history, photo/path playback, COLMAP/PLY export and training initialization. No artificial LiDAR depth files or depth-dependent BA are created. Deletion removes the entire scan, including the reconstruction report.

`capture-meta.json` includes optional `rgbReconstructionEnabled`; older metadata remain readable. `rgb-reconstruction.json` (version 2, method `known-pose-patchmatch-mvs`) stores:
- eligible frames and decoded images;
- attempted and contributing references and their IDs;
- the pixel funnel: textured, photo-consistent, ambiguous (rejected by uniqueness) and multi-view-consistent pixels;
- observations, RGB and total point counts;
- all MVS settings and the duration.

Status can be `insufficientViews`, `insufficientBaseline`, `noReliableMatches` or `reconstructed`. Tearing down the capture screen cancels a running reconstruction, as it does LiDAR fusion.

Memory is bounded by the view budget. 48 views at 320×240 hold about 29 MB of RGBA and grayscale images and about 7 MB of depth and cost maps. Each worker thread also holds one 0.3 MB normal map while its view is being matched. On an 8-core Mac, one run takes 2–3 s on these scans.

### Limits

This is fixed-pose MVS at 320 pixels. It has no SfM or RGB bundle adjustment, so pose errors pass directly into the points (compare the reference-pose and camera-only-pose runs below). Views beyond the 48-view budget are not matched, so large scenes keep gaps. Low-texture surfaces (plain walls, ceilings), reflections, motion blur and occlusion leave holes. The uniqueness check removes some correct matches on fine regular texture. Phone runtime, heat and physical accuracy need device measurement.

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
| MVS points; contributing views of 48 | 19,076 / 14,474; 48 / 45 | 20,770 / 11,365; 45 / 46 |
| MVS accuracy median / P90 | 1.16 / 4.18 cm vs 1.95 / 8.78 cm | 1.34 / 5.27 cm vs 2.95 / 9.28 cm |
| MVS points within 2 cm; beyond 10 cm | 73.6%, 2.0% vs 50.9%, 7.7% | 65.0%, 1.6% vs 39.0%, 8.2% |
| Completeness at 2 / 5 / 10 cm, all LiDAR points | 15.0 / 36.9 / 56.6% vs 7.7 / 23.7 / 42.0% | 4.6 / 17.3 / 32.5% vs 1.6 / 10.1 / 25.8% |
| Completeness at 2 / 5 / 10 cm, viewed points only | 15.1 / 37.2 / 56.9% vs 7.8 / 24.2 / 42.7% | 4.7 / 17.5 / 32.8% vs 1.6 / 10.2 / 26.0% |
| LiDAR points viewed by the contributing views | 98.9% / 98.0% | 98.5% / 98.7% |
| Mac replay time (8 cores): total; fusion; photo; MVS per run | about 12 s; 2.7 s; 2.0 s; 2.9–3.0 s | about 16 s; 6.7 s; 2.0 s; 2.1 s |

**Poses.** Camera-only poses differ from the LiDAR reference by 1–2 cm (median), up to about 4 cm, and about 0.3° (median). The difference per metre travelled is 1.2–1.4 cm. Over 5 m it is only 1.8–2.7 cm, so on these 16–20 m paths the difference does not grow steadily with distance. Photo alignment improves under the reference poses on both scans, mostly for wide-baseline pairs. On 9F8040 the validator's sample-retention rule still marks the subset "rejected", although its medians improve. The full 569-frame refinement passed that check.

**Points.** The earlier sampled two-source matcher was the main gap: about 1,000 points at close range and about 200 at room scale, with at most 12% completeness within 5 cm, although its views saw over 90% of the surface. PatchMatch multiplies the points by 15–95 and raises 5 cm completeness about three times at close range and 15–25 times at room scale:

| Reference poses / camera-only poses | 7F2187 earlier | 7F2187 PatchMatch | 9F8040 earlier | 9F8040 PatchMatch |
| --- | --- | --- | --- | --- |
| Points | 1,129 / 995 | 19,076 / 14,474 | 218 / 216 | 20,770 / 11,365 |
| Accuracy median | 1.25 / 2.56 cm | 1.16 / 1.95 cm | 2.48 / 3.10 cm | 1.34 / 2.95 cm |
| Accuracy P90 | 4.44 / 7.49 cm | 4.18 / 8.78 cm | 7.20 / ≥10 cm | 5.27 / 9.28 cm |
| Points beyond 10 cm | 2.4 / 4.8% | 2.0 / 7.7% | 4.6 / 11.6% | 1.6 / 8.2% |
| Completeness within 5 cm | 11.6 / 7.6% | 36.9 / 23.7% | 0.7 / 0.6% | 17.3 / 10.1% |
| MVS time per run (Mac) | 0.9 s | 2.9–3.0 s | 0.6 s | 2.1 s |

- **Reference poses.** With them, which isolate MVS, all accuracy measures improve.
- **Camera-only poses.** Here the pose differences dominate. The median improves, but at close range the share beyond 10 cm rises from 4.8 to 7.7% as many more points come from surfaces where pose errors show. Part of that gap also comes from scoring against a cloud built with the reference poses.
- **Where the gap is now.** The contributing views see about 99% of the LiDAR surface, so the remaining gap is per view:
  - Low-texture surfaces fail the texture gate: 48% of 9F8040's grid pixels, against 31% at close range.
  - The multi-view check keeps 19–21% of photo-consistent pixels with reference poses, and 10–16% with camera-only poses.

### Choosing the defaults

Parameters were varied on both scans; the sweep command is under [regression commands](#regression-commands). Values are with reference poses, as 5 cm completeness / points beyond 10 cm / P90 accuracy.

| Variant (differences from the defaults) | 7F2187 | 9F8040 |
| --- | --- | --- |
| **Defaults** (48 views, texture 0.012, uniqueness 0.05) | 36.9% / 2.0% / 4.18 cm | 17.3% / 1.6% / 5.27 cm |
| Texture threshold 0.02 | 33.4% / 1.8% / 4.25 cm | 10.1% / 3.1% / 6.62 cm |
| No uniqueness check | 39.8% / 2.5% / 4.63 cm | 19.7% / 2.0% / 5.48 cm |
| 72 views | 43.9% / 2.2% / 4.31 cm | 23.3% / 2.5% / 5.50 cm |
| 96 views | 49.0% / 2.8% / 5.14 cm | 29.0% / 2.8% / 5.82 cm |

- **Why these defaults.**
  - Lowering the texture threshold helps both completeness and accuracy on the plain-walled room.
  - The uniqueness check gives up 3 percentage points of completeness for fewer outliers and no repeated-texture ghosts.
  - More views add completeness, but raise outliers and cost. With camera-only poses, 72 views raised the share beyond 10 cm on 7F2187 from 7.7 to 12.1%. 96 views take 2.3 times as long.
- **Rejected earlier variants** (texture 0.02, without the uniqueness check). None helped enough:
  - 1% → 2% depth tolerance: 9F8040 5 cm completeness 11.3 → 16.1%, but beyond 10 cm 3.6 → 5.2%.
  - One agreeing view instead of two: 21.9% and 7.4%.
  - Six sources: 13.0% and 4.9%.
  - A 448-pixel image: 12.2% and 3.8%, 1.6× slower.
  - Match cost 0.45: 11.6% and 3.8%.

**`--all-frames` (7F2187, earlier matcher).** Using all 399 saved frames (280 eligible) instead of the simulated 277 hardly changes the pose differences (RPE 1 m 1.3 cm, ATE RMSE 1.3 cm). MVS with reference poses gains points: 1,601 instead of 1,129, with 5 cm completeness of 14.8% instead of 11.6%. With camera-only poses the result stays at 1,003 points and 7.4% (was 995 and 7.6%). The accuracy medians stay about the same (1.26 and 2.44 cm).

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
- The results cover two scans from one device, and the MVS defaults were chosen on the same two scans.

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

# Diagnostic MVS sweep: environment overrides for the replay tool (recorded in the report)
MVS_STD=0.02 MVS_REFS=72 /tmp/replay_camera_only SCAN WORK_DIR --reference /tmp/ref.jsonl
```

`MVS_DIM`, `MVS_REFS`, `MVS_STRIDE`, `MVS_SOURCES`, `MVS_ITERS`, `MVS_STD`, `MVS_COST`, `MVS_VIEWS`, `MVS_RATIO` and `MVS_UNIQUE` override the corresponding `rgb*` settings for one replay.

The replay metric checks cover the following synthetic cases:
- Identical, rigidly moved (30° and 150°), 2% scaled and 1 cm/m drifting trajectories.
- The Jacobi eigen solver and the hash-grid search against brute force.
- A plane offset by 1 cm (accuracy, half-plane completeness at 2/5/10 cm, masking), far outliers and point spacing.
- The viewed mask: visible, occluded, tolerance, out of image, low confidence and too near.
- Shutter subsampling.

The RGB reconstruction test has 33 checks. A pre-existing parallel refusion Sendable warning remains.

RGB fixtures render a textured 1.5 m plane under varying camera translations/rotations and brightness. The cases are:
- slopes, pure rotation, white walls, and one- and two-direction periodic texture (rejected by the texture gate and the uniqueness check);
- third-view occlusion and inconsistent geometry;
- identical results across runs of the concurrent depth maps;
- source selection that skips opposite-facing and near-duplicate cameras and respects the source budget;
- the report's pixel funnel;
- JPEG resizing and orientation, voxel merge, sparse fill and view budgets;
- missing files, calibration mismatch, malformed poses, blur verdicts, duplicate frames and legacy metadata.

On the ideal plane PatchMatch reaches a median depth error of 1.7 mm, and 1.6 mm on the sloped plane.

Synthetic thresholds are median depth error below 1.5 cm, P95 below 4 cm, and sloped-plane median residual below 2.5 cm. These ideal known-pose regression limits do not predict device accuracy. Sparse tests verify acceptance/rejection, epochs, capacity, and shutter behavior rather than physical measurement.

For a device A/B, fix light, settings, and path; compare lateral motion, rotation, white walls, backgrounding/relocalization, accepted frames, coverage, known dimensions, and thickness. More points are not necessarily more accurate.

## References

ARKit [rawFeaturePoints](https://developer.apple.com/documentation/arkit/arframe/rawfeaturepoints) are intermediate tracking features; [identifiers](https://developer.apple.com/documentation/arkit/arpointcloud/identifiers) associate observations independently of array order. See also COLMAP's [known-pose reconstruction discussion](https://colmap.github.io/faq.html#reconstruct-sparse-dense-model-from-known-camera-poses). This app's matcher is an independent implementation, not integrated COLMAP/PatchMatch.
