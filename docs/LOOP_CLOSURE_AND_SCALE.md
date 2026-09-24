# Loop closure and metric scale

**English** | [繁體中文](LOOP_CLOSURE_AND_SCALE.zh-TW.md)

The phone can use verified revisits of earlier views in pose refinement and export a dataset with an explicit metric scale. These are two distinct checks: pose alignment improves consistency; a measured reference checks dimensions. Neither guarantees survey accuracy or artifact-free 3DGS training.

## Revisit refinement

With LiDAR and refinement enabled, stopping a scan matches revisited views, runs the joint bundle adjustment, validates it, then refuses depth. **Optimize training data** in history uses the same pipeline and publishes a separate scan. Original RGB/depth files are preserved.

This is a custom implementation, not a port of COLMAP or Ceres. It requires saved LiDAR depth; camera-only scans retain their existing processing.

### Revisit tracks in the joint bundle adjustment

Revisits enter the joint bundle adjustment ([pose refinement](POSE_REFINEMENT.md)) as additional feature tracks. Reprojection, LiDAR depth and ARKit motion priors then reconcile both passes in one solve.

- **Candidates.** At most 512 distributed query frames and 64 pairs. A pair is more than 30 eligible frames, 8 seconds and 2 meters of travel apart. Camera centers must be within 1.0 m and viewing directions within about 37° (cosine above 0.8).
- **Pose-guided matching.** Up to 320 features of the earlier frame are projected into the later frame with the input poses.
  - Each 9×9 patch is warped through the local LiDAR plane, so perspective and distance changes between passes do not break the comparison.
  - A dense ZNCC search runs around the prediction. Its radius covers 6 cm of drift at the feature's depth (12–40 px at 960 px). A match needs ZNCC ≥ 0.8, and the best score away from the peak must stay below 0.9 of it.
  - The later frame's own LiDAR depth at the match gives its observation. The poses only limit where to search: a match must still be found in the image.
- **Outlier rejection.** A pair contributes only when at least 24 matches, 16 inliers and 60% of its matches agree with one rigid motion within 2.5 cm. This uses deterministic RANSAC, and the implied motion must stay within 15 cm and 5°. Only inliers are added. A revisit that is already consistent also counts, because it still constrains drift.
- **Tracks.** A match joins the existing track of the earlier observation when the tracker kept that observation; otherwise it starts a two-view track. As for all tracks, every fifth track ID is held out from the solve, so held-out revisit tracks measure the result without being optimized.
- **Fallback.** If the bundle adjustment with revisit tracks is rejected by its held-out gate or fails the photo-alignment check, the stage is solved again without them and checked again. Revisit tracks cannot cost a scan the correction it had without them.
- Images, depth and features are loaded for one pair at a time. Scale is never optimized.

Repeated texture, missing depth, drift beyond the search window, appearance changes, or insufficient overlap can prevent a revisit. Return to a previously seen area with a similar viewing direction and clear images. This bounded implementation deliberately does not recover arbitrary large tracking failures.

### Earlier rigid correction graph

`OfflinePoseRefinement.LoopMode` keeps the earlier loop stage for replays (`rigidGuided`, `rigidDescriptor`). After the bundle adjustment it fits one rigid alignment per verified pair from LiDAR points (at least 40 matches, a per-pair holdout, and an improvement required). It then distributes the corrections through a linearized graph anchored at the first frame. The graph limits corrections to 15 cm and 5° and rejects abrupt changes in relative motion.

- With descriptor matching of independently detected features, the three replay scans verified no revisit: the best pairs had 35, 9 and 15 matches.
- With guided matching, the graph verified 3, 2 and 1 pairs. Its LiDAR-only corrections still lowered the median wide-baseline photo gain from +0.020 to +0.006 (7F2187, now rejected), from +0.023 to +0.016 (9F8040), and from +0.001 to −0.021 (916C58). This matches earlier findings that depth-only pose corrections disagree with the photos by about 1 cm.

`pose-refinement.json` version 3 added `loopClosure` (rigid modes). Version 7 adds `loopMode` and `revisitFallback`. It also adds `loopTracks`: candidate and verified pairs, guided matches per pair, verified pair frame IDs, added observations, linked, new and held-out tracks, the held-out revisit distance before and after, and time. Older reports remain readable.

### Replay evidence

These are desktop replays of three iPhone 17 Pro scans with app defaults, including the local surface stage, which was rejected on all three as before. The input is each scan's saved review poses, and "without revisits" is `LOOP_MODE=off`. There is no ground truth.

| | 7F2187 (399 frames) | 9F8040 (569 frames) | 916C58 (377 frames) |
| --- | --- | --- | --- |
| Best-pair matches, descriptor → guided (0.8 m / 0.9 candidates) | 35 → 119 | 9 → 97 | 15 → 41 |
| Verified revisit pairs / candidates | 7 / 13 | 4 / 9 | 2 / 12 |
| Revisit observations added | 639 | 561 | 109 |
| Held-out revisit tracks: distance between the two LiDAR observations | 15.3 → 9.7 mm | 29.2 → 17.3 mm | — (fallback) |
| Photo check, paired against without revisits: adjacent / wide | ±0.0000 / +0.0010 | ±0.0000 / +0.0001 | identical output |
| Revisit photo pairs (> 15 s apart, track frames ±3 excluded): better / worse by > 0.02 | 22 / 1 of 28 | 8 / 1 of 12 | identical output |
| Mac replay time, with vs without revisits | 8.4 vs 7.0 s | 13.2 vs 11.7 s | 6.8 vs 5.1 s |

- On 916C58 the solve with revisit tracks failed the held-out gate. The fallback output is byte-identical to the run without revisits; there, the photo check keeps the input poses in both cases.
- The app's photo check scores pairs mostly under 1 s apart (adjacent) or 1.5 s apart at 0.25–0.8 m (wide), so it cannot see drift between passes. A separate desktop test therefore scores revisit pairs that did not create tracks.
- A dense LiDAR comparison of surfaces observed 15–80 s apart changed by only a few millimetres. On 9F8040, floors and ceilings seen more than 40 s apart still disagree by tens of millimetres. Four verified revisits constrain those passes only locally, so more drift remains than the revisit tracks can reach.

## Measure, calibrate, and independently verify
## Measure, calibrate, and independently verify

1. Open **Scan history → a scan → Scene scale and validation**.
2. Open **Precise point selection** for a full-screen cloud. Rotate with one finger and pan/zoom with two. A tap previews an orange candidate; use **Zoom to candidate**, then **Confirm start/end**. Cyan markers show confirmed endpoints. Edit either endpoint with the segmented control; empty-space taps clear only the candidate. **Done** applies both points; **Cancel** leaves the previous segment unchanged. Picking prioritizes proximity to the tapped pixel, with front-surface depth used only within a two-screen-point tie. Measurements use sampled preview points, so zoom in and select clear surfaces.
3. Measure that same segment with a tape or laser, enter its length in meters, and choose **Calibrate scale**. Both the selected segment and reference length must be at least 10 cm; factors outside 0.5–2 are rejected.
4. Select a different location or direction and choose **Validate distance**. A calibration alone remains unverified. A reference with a midpoint at least 0.5 m away or a sufficiently different direction is accepted as a separate check; using the calibration segment itself is rejected.
5. Review signed errors. Up to eight validation distances are supported. Every reference must be within `max(0.02 m, 1% of its known length)` for the reference checks to pass. This is an application check threshold, **not a claimed sensor or whole-scene accuracy**.

ARKit's nominal units already represent meters. Without a measured reference, the UI labels this scale unverified. You can validate nominal scale without recalibrating. A uniform scale factor cannot remove locally warped walls, pose drift, furniture layers, or wrong point selections. Check several locations/directions when dimensions matter.

References are saved in `scale-measurements.json` and tied to a SHA-256 fingerprint of the source point cloud. Changed geometry invalidates references; a resumed scan with frames beyond its saved preview cannot use the old cloud for metric export. Reprocess it first, then measure the new version. Recalibration clears previous validation references. Reset removes the calibration/validation evidence, restoring nominal scale.

## Metric export and coordinates

Use **Export metric 3DGS data** inside the measurement sheet. This creates a separate `scan_…-metric.zip`:

- Images, COLMAP `sparse/0`, point cloud, and processed pose data use the existing training selection/export path.
- Multiply every point and camera translation by the same factor. Camera rotations and intrinsics stay unchanged, preserving image projections.
- `scene-metrics.json` states meter units, the applied factor, source fingerprint, reference-check status/residuals, and row-major 4×4 source-to-metric / inverse transforms. `absoluteSceneAccuracyCertified` remains false.
- PLY and JSONL use the scaled ARKit world frame. COLMAP points and cameras additionally use the existing world-X 180-degree rotation; the manifest records this separately. See [coordinate conventions](COORDINATES.md).
- The copied `scale-measurements.json` contains reference endpoints in the **source** frame. The manifest identifies the source frame and applied conversion; do not apply the factor a second time to the exported cloud.
- Raw depth/confidence are omitted and depth references are removed from exported pose records, preventing accidental mixing of scaled geometry with unscaled sensor depth. Original photos/depth and the normal scan export remain unchanged.
- Export limits the cloud to 250,000 points. It checks cancellation and verifies source geometry/reference consistency before packaging. Changing references invalidates the previous metric ZIP; deleting the scan removes it too.

External trainers may normalize scene coordinates. Preserve and invert that trainer's normalization to recover metric dimensions in the trained result. A metric COLMAP input alone cannot guarantee that an external viewer retains meters. The sparse model still contains initialization points rather than full SfM feature tracks.

## Validation and limits

```sh
bash tools/test_metric_loop.sh
bash tools/test_training_quality.sh
bash tools/test_localization.sh
python3 tools/check_project.py
```

Synthetic tests cover rigid recovery, outliers, contradictory holdouts, cancellation, gauge anchoring, smooth graph corrections, bounded 1,000-frame candidate search, calibration/independent checks, projection-preserving export, readable COLMAP ZIPs, raw-file preservation, stale geometry, and deletion. Unsigned device and Simulator builds check integration; Simulator UI checks do not test LiDAR accuracy.

16 revisit-track checks render a textured wall on two passes. The return pass is 30 cm closer, yawed 15°, and its poses drift by up to 3 cm and 0.3°.
- Guided matching finds 111 matches, and their rigid inliers recover the injected drift within 1 cm.
- An unrelated view and drift beyond the search window yield no revisit.
- Tracks span both passes, link to existing tracks and get fresh IDs.
- Consistent revisits are kept, whereas the rigid-correction check would discard them.
- End to end, the default feature stage shrinks the held-out revisit distance from 22.3 to 1.9 mm, and `LoopMode.off` adds no tracks.

`tools/replay_pose_refinement.swift` accepts `LOOP_MODE=bundleTracks|rigidGuided|rigidDescriptor|off`, plus `LOOP_DIST`, `LOOP_FACING`, `LOOP_MIN_MATCHES`, `LOOP_MIN_INLIERS` and `LOOP_STRICT=1`, to reproduce the comparisons above. The replay evidence covers three scans from one device; it is not an iPhone timing benchmark. Real-device revisit acceptance, long-session memory and temperature, and independently measured room dimensions still require validation on representative captures.
