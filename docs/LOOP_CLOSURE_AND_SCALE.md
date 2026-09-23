# Loop closure and metric scale

**English** | [繁體中文](LOOP_CLOSURE_AND_SCALE.zh-TW.md)

The phone can verify revisited views after local pose refinement and export a dataset with an explicit metric scale. These are two distinct checks: pose alignment improves consistency; a measured reference checks dimensions. Neither guarantees survey accuracy or artifact-free 3DGS training.

## Revisit refinement

With LiDAR and refinement enabled, stopping a scan runs local refinement, revisit matching, validation, then depth refusion. **Optimize training data** in history uses the same pipeline and publishes a separate scan. Original RGB/depth files are preserved.

This is a custom implementation, not a port of COLMAP or Ceres. Bundle adjustment jointly updates cameras against LiDAR-derived landmarks with ARKit motion priors ([pose refinement](POSE_REFINEMENT.md)); the additional loop stage solves a linearized graph of small rigid corrections, not full joint camera/landmark BA or complete global SfM. It requires saved LiDAR depth. Camera-only scans retain their existing processing.

- Search at most 512 distributed query frames and 64 candidate pairs. Candidates are separated by more than 30 eligible frames, at least 8 seconds and 2 meters of travel, with camera centers within 0.8 meters and similar viewing directions.
- Load descriptors for only two frames at a time. Reciprocal appearance matches also require nearby depth-derived world positions; each pair has at most 256 matches.
- Fit rigid alignment with deterministic RANSAC. Reserve every fifth match for validation; these held-out matches do not enter that pair's fitting/refitting. This is a per-pair holdout, not a guarantee that landmarks are independent across different loop pairs.
- Anchor the first eligible frame and distribute the correction with a sparse graph whose memory grows with frames and edges. Scale is never a graph variable.
- Reject camera shifts above 15 cm, rotations above 5 degrees, abrupt changes to relative motion, or degraded held-out geometry/reprojection. Interpolate accepted corrections through excluded frames for continuous playback.
- Refuse depth with accepted poses. Do not reuse an uncorrected ARKit mesh alongside changed poses. Failed loop validation preserves the preceding local-refinement result. Cancellation does not publish a partially solved loop; memory pressure skips optional loop processing.

`pose-refinement.json` version 3 adds `loopClosure`: candidate/verified pair counts, maximum pair matches, descriptor-frame peak, status, elapsed time, correction magnitude, and held-out 3D/pixel residuals when final validation is reached. Geometrically verified pairs can still fail the graph's final checks; only `status: validated` means corrections were applied. Version 5 adds the photo-alignment result: loop corrections belong to the feature stage and are applied only if that stage passes the check (`appliedStage`).

Repeated texture, missing depth, large drift, changes in appearance, or insufficient overlap can prevent closure. Return to a previously seen area with similar viewing direction and clear images. This bounded implementation deliberately does not recover arbitrary large tracking failures.

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

A read-only desktop replay of the 399-frame `7F2187` scan found 11 candidate revisits and no verified loop. The preceding local-refinement result was retained. This is evidence that fallback works, **not evidence of improved accuracy on that scan or an iPhone timing benchmark**. Real-device loop acceptance, long-session memory/temperature, and independently measured room dimensions still require validation on representative captures.
