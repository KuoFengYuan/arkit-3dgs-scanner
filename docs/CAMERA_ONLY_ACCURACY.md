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

## Regression commands

```sh
swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Models,BlurFilter,CaptureConfig,Utils,SmartShutter,DepthSampleFilter,CameraOnlyGeometry,SparseLandmarkFilter}.swift \
  tools/test_camera_only_accuracy.swift -o /tmp/fable-camera-only-test
/tmp/fable-camera-only-test

swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,RGBStereoMatcher,RGBReconstructionEngine}.swift \
  tools/test_rgb_reconstruction.swift -o /tmp/fable-rgb-test
/tmp/fable-rgb-test
```

Historical validation passed 29 RGB reconstruction checks, 26 camera-only quality/shutter checks, 18 fusion checks, and unsigned device/Simulator Debug builds. A pre-existing parallel refusion Sendable warning remains.

RGB fixtures render a textured 1.5 m plane under varying camera translations/rotations and brightness. Cases include slopes, pure rotation, white walls, one-/two-direction periodic texture, third-view occlusion/inconsistency, JPEG resizing/orientation, voxel merge, sparse fill, budgets, missing files, calibration mismatch, malformed poses, blur, duplicate frames, and legacy metadata.

Synthetic thresholds are median depth error below 1.5 cm, P95 below 4 cm, and sloped-plane median residual below 2.5 cm. These ideal known-pose regression limits do not predict device accuracy. Sparse tests verify acceptance/rejection, epochs, capacity, and shutter behavior rather than physical measurement.

For a device A/B, fix light, settings, and path; compare lateral motion, rotation, white walls, backgrounding/relocalization, accepted frames, coverage, known dimensions, and thickness. More points are not necessarily more accurate.

## References

ARKit [rawFeaturePoints](https://developer.apple.com/documentation/arkit/arframe/rawfeaturepoints) are intermediate tracking features; [identifiers](https://developer.apple.com/documentation/arkit/arpointcloud/identifiers) associate observations independently of array order. See also COLMAP's [known-pose reconstruction discussion](https://colmap.github.io/faq.html#reconstruct-sparse-dense-model-from-known-camera-poses). This app's matcher is an independent implementation, not integrated COLMAP/PatchMatch.
