# On-device dataset refinement

**English** | [繁體中文](ON_DEVICE_TRAINING_QUALITY.zh-TW.md)

This document covers data preparation before training. The app can train 3DGS itself ([on-device 3DGS training](ON_DEVICE_3DGS.md)) or export the prepared data to an external trainer; both use the same selection, poses, and point cloud.

Photo selection, cross-frame matching, camera-pose validation, and depth refusion run on the iPhone without desktop COLMAP. Export remains `images/ + sparse/0` for compatible trainers.

## Usage

- **New scans:** leave Refined scanning enabled in LiDAR mode. Stopping runs image matching, pose validation, refusion, and training-image selection.
- **Existing scans:** open Scan history → a scan → Optimize training data. The completed optimized copy opens automatically; export it as a 3DGS dataset. Keep the original for comparisons with identical trainer settings.
- Cancel during history optimization, or leave the detail view to cancel. Incomplete copies are not published.
- Images and depth remain unchanged. Optimized copies use hard links where supported, otherwise file copies. Deleting either version leaves media referenced by the other version intact.

## RGB selection and quality messages

`TrainingFrameSelector` runs after geometry/RGB review. It does not change `blurVerdict` or depth-fusion inputs. This second selection stage has no 30% exclusion cap.

It decodes one sensor-oriented grayscale thumbnail at a time, at most 320 pixels on the long edge. It measures second differences relative to gradient energy and a 16×12 image signature. Only cameras within 4 cm (less at close range, see below), within 3° of full rotation, and with similar image signatures are treated as replaceable views; the view with stronger detail wins. Different viewpoints, baselines, content, and views lacking reliable sharpness measurements are retained. This conservative heuristic cannot detect every small occlusion; a textureless surface is not automatically blurry.

An estimated motion value above 10 px does **not** by itself exclude an image or trigger a recapture banner. Report v3 separates:

- **Weak measured detail:** retained views with valid positive detail evidence and capture sharpness, and a finite sharpness ratio below 0.5, receive a review/recapture message with frame IDs. This relative metric is not proof of optical blur.
- **Motion estimate only:** available in the collapsed Capture quality information section in history; it does not claim a photo is blurry or request recapture by itself.
- **Low texture / insufficient evidence:** informational, without a recapture banner.

Older reports without these categories show an informational suggestion to optimize again, rather than reclassifying all legacy recapture IDs as blurry. Raw media, selected-image geometry, and depth support remain intact. This changes the warning policy; it does not deblur photos. Better light, shorter exposure, slower movement and turning, and genuinely clearer overlapping views are still needed for better source images.

### Close-range scans (report v4)

The metric sizes of the blur review and of this selection were set on room scans, 1.3–2.2 m from the surfaces. On a tabletop scan at 0.37 m (94D4DD) they left only 244 of 479 photos for training:

- **Blur review neighbours:** the review compares a photo's sharpness with photos within 0.5 m and 30°. At 0.37 m every camera is within 0.8 m of every other, so the comparison included views of other surfaces, and texture differences read as blur.
- **Motion estimate:** the review demoted photos whose estimate passed 10 px. That estimate includes the 10 ms rolling readout, which skews rows but does not blur them. On this scan, 375 photos passed 10 px on the estimate, and 1 on exposure blur alone.
- **The 30% cap:** together, the review hit its cap of 30% (139 demoted, 4 dropped).
- **Redundancy:** the selection then marked 90 photos as redundant views 2 cm apart, which at 0.37 m is 3.4° of parallax.

Since report v4 (`TrainingFrameSelector.policyVersion`):

- **Working distance:** the scan's median confident LiDAR depth (`TrainingFrameSelector.workingDistance`).
  - Below 1.2 m, the 0.5 m neighbour radius and the 4 cm redundancy step shrink in proportion, down to 1/8.
  - Room-scale scans keep their values. FBDA13 (1.26 m) and 9F8040 (2.25 m) are unchanged, and 7F2187 (1.15 m) changes by 4%.
- **Image blur:** the training-image threshold uses exposure blur only, that is, the estimate scaled by exposure / (exposure + readout).
  - The geometry threshold for depth fusion (25 px) still uses the full estimate.
  - The HUD's live warning is unchanged.
- **Result on 94D4DD:** 34 photos demoted, 4 dropped, and 438 of 479 selected.
- **Older scans:** on-device training evaluates their verdicts and selection again with these rules, in memory. The result is cached in `gaussian-training/selection.json`.
  - The scan's own `training-selection.json` and `sparse/0` are unchanged and still match each other.
  - Optimize training data (above) writes a v4 report and export.
- **Effect on training:** measured in [close-range scans](ON_DEVICE_3DGS.md#close-range-scans).

`training-selection.json` records decisions, replacement frames, reasons, timestamps, and category IDs. All original photos remain in `images/`. **Use `sparse/0/images.bin` as the training-image list.** A trainer that rescans the entire images folder must also respect `selectedIDs`.

## Pose refinement after capture

`OfflinePoseRefinement` reads all non-dropped depth frames from disk, filling gaps left by the best-effort live worker. Features are extracted from 960-pixel thumbnails and mapped back to original pixels with original intrinsics. LiDAR supplies metric feature positions. Matching checks ZNCC, the second-best ratio, reverse matching, depth consistency, and per-frame track uniqueness.

This is **LiDAR-guided matching and local BA**, not global SfM or unrestricted loop closure. Four retained route references plus the latest four frames allow connections to earlier observations when visual overlap remains.

- One current grayscale image/depth and at most eight reference descriptor frames.
- At most 180,000 compact observations overall and 128 per frame, with allocation adjusted to scan length.
- Fewer than 40 observations per frame (over 4,500 eligible depth frames) explicitly reports insufficient budget and preserves poses.
- 20% of tracks are held out from BA. The median held-out reprojection residual must improve by at least 3%; the validated solution is applied without refitting on the holdout set.
- Any correction exceeding 15 cm or 5° rejects the entire solution. Clipping individual corrections would invalidate the holdout result.
- Cancellation, memory pressure, insufficient matches, or failed validation preserve original poses. `pose-refinement.json` records counts, status, residuals, and timings.

Successful poses are used to refusion LiDAR depth. New scans with applied BA do not mix in ARKit mesh that has not received the same correction. If memory pressure requires a live-preview fallback, image poses also revert to the anchor-corrected version. History optimization stages all files before publishing and omits old Gaussian models and floor plans that could disagree with new poses.

Camera-only scans can use photo selection; this pose-refinement pass requires saved LiDAR depth. It never reports success for work that did not run. The separate camera-only reconstruction pipeline remains available.

## Matching speed and timing

- Apple Accelerate computes corner tensors, convolution, and eigenvalues while preserving resolution, thresholds, NMS, and patch definitions.
- Reference spatial indices and inverse matrices are built once. Track sets replace linear searches; descriptors are written back after each frame to reduce array copy-on-write.
- Pose report v2 splits `decodeSeconds`, `featureExtractionSeconds`, `matchingSeconds`, and `bundleAdjustmentSeconds`, with separate failure reasons.
- Historical Mac Debug comparison: the 960×720 corner kernel took about 0.524 → 0.004 seconds, with maximum numerical difference 0.015625. This is a kernel measurement, not an iPhone end-to-end speedup.
- A 45-frame Mac comparison preserved 1,166 observations, 14 corrected frames, and held-out median 5.107 → 4.788 px. This does not measure 3DGS image quality.
- Compare on the same device, data, and build mode. An already-running phone process does not receive code updates automatically.

## Validation and limits

`tools/test_training_quality.swift` covers equivalent-view selection, parallax/content preservation, weak/motion-only/unknown evidence, legacy reports, immutable source files, sensor orientation, corrupt depth, cancellation, 1,000-frame processing, and optimized-copy publication/deletion. The 1,000-frame fixture repeats small synthetic images; it tests scheduling and capacity, not large-scene image quality or iPhone peak memory. BA tests separately exercise known pose perturbations and noise-only inputs.

Compare original and optimized exports with fixed trainer settings and held-out views, especially double edges and text. Improved reprojection residuals do not establish absolute centimeter accuracy; 3DGS quality requires retraining and visual evaluation.

Local refinement is followed by bounded revisit matching and validation of sparse rigid corrections. This is not full joint COLMAP/Ceres BA; rejected loops preserve local results. See [loop closure and metric scale](LOOP_CLOSURE_AND_SCALE.md).
