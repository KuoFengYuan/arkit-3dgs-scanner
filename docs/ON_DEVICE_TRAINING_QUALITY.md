# On-device dataset refinement

**English** | [繁體中文](ON_DEVICE_TRAINING_QUALITY.zh-TW.md)

Gaussian training has been removed from the app. This document covers preparation before export; actual 3DGS training runs in an external tool.

Photo selection, cross-frame matching, camera-pose validation, and depth refusion run on the iPhone without desktop COLMAP. Export remains `images/ + sparse/0` for compatible trainers.

## Usage

- **New scans:** leave Refined scanning enabled in LiDAR mode. Stopping runs image matching, pose validation, refusion, and training-image selection.
- **Existing scans:** open Scan history → a scan → Optimize training data. The completed optimized copy opens automatically; export it as a 3DGS dataset. Keep the original for comparisons with identical trainer settings.
- Cancel during history optimization, or leave the detail view to cancel. Incomplete copies are not published.
- Images and depth remain unchanged. Optimized copies use hard links where supported, otherwise file copies. Deleting either version leaves media referenced by the other version intact.

## RGB selection and quality messages

`TrainingFrameSelector` runs after geometry/RGB review. It does not change `blurVerdict` or depth-fusion inputs. This second selection stage has no 30% exclusion cap.

It decodes one sensor-oriented grayscale thumbnail at a time, at most 320 pixels on the long edge. It measures second differences relative to gradient energy and a 16×12 image signature. Only cameras within 4 cm, within 3° of full rotation, and with similar image signatures are treated as replaceable views; the view with stronger detail wins. Different viewpoints, baselines, content, and views lacking reliable sharpness measurements are retained. This conservative heuristic cannot detect every small occlusion; a textureless surface is not automatically blurry.

An estimated motion value above 10 px does **not** by itself exclude an image or trigger a recapture banner. Report v3 separates:

- **Weak measured detail:** retained views with valid positive detail evidence and capture sharpness, and a finite sharpness ratio below 0.5, receive a review/recapture message with frame IDs. This relative metric is not proof of optical blur.
- **Motion estimate only:** available in the collapsed Capture quality information section in history; it does not claim a photo is blurry or request recapture by itself.
- **Low texture / insufficient evidence:** informational, without a recapture banner.

Older reports without these categories show an informational suggestion to optimize again, rather than reclassifying all legacy recapture IDs as blurry. Raw media, selected-image geometry, and depth support remain intact. This changes the warning policy; it does not deblur photos. Better light, shorter exposure, slower movement and turning, and genuinely clearer overlapping views are still needed for better source images.

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
