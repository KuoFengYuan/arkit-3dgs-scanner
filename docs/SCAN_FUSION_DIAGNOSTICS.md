# Fusion speed and overlapping surfaces

**English** | [繁體中文](SCAN_FUSION_DIAGNOSTICS.zh-TW.md)

## Run the optimized app

The shared `arkit-3dgs-scanner` scheme now uses **Release for Run**, matching its existing Profile/Archive configuration. Select `arkit-3dgs-scanner-Debug` for source-level debugging with `-Onone`; tests and Analyze remain Debug. Release still uses the same bundle identifier and scan storage. Changing schemes does not require uninstalling the app. Custom signing settings belong to the local developer.

`capture-meta.json` and version 9 and later `refusion-progress.json` include an optional `debugAssertionsEnabled` field. Old reports decode without it. It is true for the standard unoptimized Swift build and false for the standard optimized build, including command-line replays. It reports assertion mode, not the exact Xcode configuration name; custom compiler assertion overrides can change it. It is not a device timing or thermal measurement.

Do not use an unoptimized Debug run as a production performance benchmark. Compare the same device, build configuration, scan, poses, reconstruction options and thermal state. TSDF storage times, surface processing, depth consistency, and total time are recorded separately.

## Conservative surface validation

Nearby depth frames can agree on a repeated shell without enough independent viewpoints to reject it. After successful experimental TSDF extraction, an additional route-wide check compares output points against at most 64 saved depth maps, **one map at a time**, using the same final camera poses as fusion.

- Reference camera centers must be at least 8 cm apart globally, with at least 0.25 s between selected timestamps. Repeated stationary captures cannot supply additional independent votes. Selection spans the route when the reference limit is reached.
- Only high-confidence bilinear depth neighborhoods within 3 m, passing the existing edge test and a 3 cm maximum local depth spread, vote. Frames without confidence data, rejected geometry, invalid poses or unsupported dimensions cannot vote.
- A point is removed only if at least three independent references place it clearly in measured free space, beyond **twice** the existing depth agreement tolerance, and fewer than two references support it. Two supporting views protect real thin surfaces even when other views disagree.
- Occluded, missing, far-range and out-of-frame observations do not vote against geometry. Points without enough evidence remain. No point is moved or flattened; local plane estimates are used only to decide coverage, and surviving XYZ/RGB values remain unchanged.
- If more than 10% of points would be removed, validation retains the complete input and reports `excessiveConflictFallback`. Missing reference data or interruption also leaves the input unchanged; the pipeline's existing cancellation/memory guard still determines whether a result is published.

The default path retains two `UInt8` counters (2 bytes per point). Experimental `surfaceCoverageProtection` adds a third counter, using 3 bytes per validation point. In addition to the original support/contradiction votes, a point supported within **1 cm by two independent references** is protected from far-range replacement. Local protection uses two compact spatial indices; `counterBytes` and `coverageWorkspaceBytesEstimate` report the counters and estimated index workspace separately. Compaction begins only after all decisions succeed and does not copy a second output cloud. TSDF is released before validation. Cancellation preserves the input. Set `CaptureConfig.surfaceVisibilityValidation = false` for a controlled comparison. Voxel-only fusion does not run visibility validation; final range coverage runs only with the experimental option.

## Coverage protection

**Disabled by default.** Set `CaptureConfig.surfaceCoverageProtection = true` for controlled developer builds, or use `refuse_dataset SOURCE NEW_OUTPUT --surface --coverage-protection`. The implementation also runs entirely on the phone; the replay tool is for reproducibility. There is no automatic rollout or pose/scale adjustment. Version 10 records `coverageProtectionEnabled` so results cannot be confused with the default pipeline.

The former spherical exclusion tested all measured near grid cells before export. A near cell omitted by filtering or sampling could therefore erase far fill without supplying a replacement.

- Range replacement now uses **retained** near points, after TSDF and visibility checks. It requires compatible surface directions, a local two-dimensional neighborhood, and close samples around all four tangent quadrants of the projected far point. Holes, edges and perpendicular surfaces are not covered merely because a near point is within 15 cm.
- Surface directions come from local geometry, with compact original-depth normals available when export is sparse. Octahedral directions use two bytes; aligned `CloudPoint` stride grows from 20 to 24 bytes. Grid cells remain 48 bytes and TSDF cells 28 bytes because they use existing padding. Original XYZ/RGB, poses and file formats are unchanged.
- Visibility cleanup retains its global 10% fallback. It also protects thin lines and candidate clusters whose removal would empty over 60% of occupied subcells in a local 50 cm box, unless a compatible retained surface covers them. The occupancy mask uses 27 subcells per 10 cm bucket; duplicate crossings cannot inflate coverage. This is a conservative safeguard, not a proof that a retained cluster is correct.
- When TSDF reaches its output limit, duplicate far samples must not consume near-surface slots and then disappear during cleanup. The merge estimates far-only coverage, reserves at most half the output slots for it, and bounds near points first. It temporarily retains deferred far points for final validation; only far fill is thinned if the final cloud exceeds the cap. Replacement evidence therefore survives the last sampling step.
- Temporary merge output is bounded by twice the configured output cap, independent of frame count. At the default cap this is at most 500,000 points / 11.45 MiB of point storage, plus source arrays, indices, counters and application state. Three counters are at most 1.43 MiB. These are bounded allocations, not a measurement of total RSS or a crash guarantee. Existing cancellation/headroom checks remain active.

Version 10 reports optional `rangeCoverage` (candidates, covered removals, coverage protection, independent support, budget removals, estimated workspace and time), `surfaceValidation.locallyProtectedPoints`, and TSDF `farReservePoints` / `peakMergePoints`. Old reports still decode. A removed point is not automatically an error: inspect both coverage and thickness before judging quality.

This check targets **unsupported foreground ghost surfaces**. It cannot infer the true side of glass, resolve surfaces hidden behind an opaque wall, or fix a shared camera-pose/depth bias. Sparse reference sampling may miss valid support. Original photos/depth are preserved; inspect important thin/transparent structures before relying on dimensions. Local point-cloud thickness includes real structures and is not ground-truth dimensional accuracy.

## Reproducible verification

Run `bash tools/test_surface_reconstruction.sh` and `bash tools/test_fusion_memory.sh`, then build unsigned device and Simulator targets sequentially. The surface and coverage suites cover ghost rejection, protected parallel/perpendicular surfaces, holes, edges, sparse normals, thin structures, output-budget handling, occlusions, uncertain depth, missing confidence, repeated camera positions, cancellation and excessive-conflict fallback. Replays must compare geometry/coverage as well as time; deleting points alone is not evidence of improved accuracy.

The TSDF integration cache also reuses the last resident block across successive points and avoids duplicate cell reads within half-voxel steps. This preserves arithmetic order, one vote per frame, LRU timestamps, resolution and allocation budgets. Its effect can be isolated using `SurfaceTSDF(cacheBlockLookups: false)` in tests.

## Experimental replay outcome (2026-09-24)

Matched read-only replays compare the previous default with coverage protection enabled. Saved poses, original depth, 2 cm TSDF and the 250,000-point output cap are unchanged. These are Mac measurements without saved ARKit mesh, not phone or ground-truth accuracy results.

| Frames | Default → experiment points | Median local thickness (cm) | Missing evaluated patches | Retained default 10 cm cells |
| --- | ---: | ---: | ---: | ---: |
| 377 | 72,464 → 74,620 | 3.333 → 3.495 | 0 / 2,663 | 100% |
| 399 | 104,202 → 104,747 | 4.894 → 4.921 | 0 / 2,568 | 100% |
| 569 | 247,021 → 250,000 | 1.598 → 1.850 | 0 / 2,910 | 98.49% |

The larger cloud has more occupied cells (14,144 → 15,952), but both additions and removals occurred. Its 6 cm occupied-cell components decreased from 49 to 31 (57 to 28 with a half-cell offset); added noise can also connect components. This does **not** prove better surfaces. The thickness increase fails the no-quality-loss rollout gate: the experiment stays disabled. The default produced byte-identical PLY output to the previous release on all three scans. Two separate experimental processes were also byte-identical on the 377- and 569-frame scans.

The experiment tests a coverage/ghost tradeoff; it is not an accepted fix for measurement error. Confirm corresponding physical plane regions and reference distances before changing defaults. Do not use the historical tables below as evidence that this experiment improved thickness.

## Historical replay evidence (2026-09-23, before coverage protection)

Read-only M1 Pro replays used the saved final poses and depth maps, the same 2 cm TSDF, and a fixed 6 GiB headroom injection to exercise the bounded mobile path. No scan or image is committed to the repository.

| Scan | Points before → after | Local thickness median before → after | Missing evaluated patches | Occupied 10 cm cell retention |
| --- | ---: | ---: | ---: | ---: |
| 377 frames (reported overlapping walls) | 74,810 → 72,464 | 3.676 → 3.527 cm | 0 / 2,626 | 98.59% |
| 399 frames | 105,576 → 104,202 | 5.328 → 4.991 cm | 0 / 2,523 | 99.17% |
| 569 frames | 250,000 → 247,021 | 1.678 → 1.529 cm | 0 / 2,878 | 99.37% |

Thickness is the P10–P90 normal-depth band in fixed 20 cm-radius PCA patches. Patches include furniture and real layers; these figures **are not wall measurement errors**. Zero missing evaluated patches does not prove every thin structure is preserved. Surviving XYZ/RGB values are exact subsets of the baseline, and two separate final processes produced byte-identical output on the 377-frame scan. Pose files and source images/depth were not modified.

On that 377-frame scan, the previous code took **134.92 s with `-Onone` versus about 5.03 s with `-O`** on the same Mac; sorted XYZ/RGB were identical. The phone's supplied report recorded 99.44 s but did not identify its build mode, so Debug is a supported diagnosis to check, not a proven fact about that installation. Two final optimized replays including visibility validation took 5.09 / 4.87 s; two previous optimized runs took 5.03 / 5.03 s. TSDF CPU time fell from about 2.71 to 2.41 s, while the new check added about 0.15 s. Overall optimized time is effectively unchanged with the extra validation; the main expected practical speed gain is choosing an optimized app build. Desktop measurements do not predict phone timing, thermal limits, or crash immunity.


## Comparing new scans

Use the same saved fusion poses and options. `tools/compare_surface_thickness.py BEFORE.ply AFTER.ply REPORT_DIR` measures fixed local patches. `tools/compare_surface_coverage.py BEFORE.ply AFTER.ply OUTPUT.json` reports directed 3 cm neighbor distances and 6 cm occupied-cell components at two grid phases. Both tools read inputs without changing them and require numpy/scipy (the thickness plot also needs matplotlib). Added cells may be noise; grid connectivity is not mesh topology and cannot certify a hole-free surface.

For dimensional accuracy, record the two physical plane regions for each reference distance, their coordinate convention, units, reference measurement uncertainty, and an independent validation distance. Apply the same robust plane method to both outputs and report signed errors, plane inlier residuals and rejected fractions. Do not equate an axis label with gravity height or fit one global scale to mixed signed errors and call it validation. Pose refinement and non-LiDAR accuracy require corresponding saved images/observations; this coverage change does not adjust either poses or global scale.
