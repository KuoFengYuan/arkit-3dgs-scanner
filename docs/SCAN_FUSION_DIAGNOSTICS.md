# Fusion speed and overlapping surfaces

**English** | [繁體中文](SCAN_FUSION_DIAGNOSTICS.zh-TW.md)

## Run the optimized app

The shared `arkit-3dgs-scanner` scheme now uses **Release for Run**, matching its existing Profile/Archive configuration. Select `arkit-3dgs-scanner-Debug` for source-level debugging with `-Onone`; tests and Analyze remain Debug. Release still uses the same bundle identifier and scan storage. Changing schemes does not require uninstalling the app. Custom signing settings belong to the local developer.

`capture-meta.json` and version 9 `refusion-progress.json` include an optional `debugAssertionsEnabled` field. Old reports decode without it. It is true for the standard unoptimized Swift build and false for the standard optimized build, including command-line replays. It reports assertion mode, not the exact Xcode configuration name; custom compiler assertion overrides can change it. It is not a device timing or thermal measurement.

Do not use an unoptimized Debug run as a production performance benchmark. Compare the same device, build configuration, scan, poses, reconstruction options and thermal state. TSDF storage times, surface processing, depth consistency, and total time are recorded separately.

## Conservative surface validation

Nearby depth frames can agree on a repeated shell without enough independent viewpoints to reject it. After successful experimental TSDF extraction, an additional route-wide check compares output points against at most 64 saved depth maps, **one map at a time**, using the same final camera poses as fusion.

- Reference camera centers must be at least 8 cm apart globally, with at least 0.25 s between selected timestamps. Repeated stationary captures cannot supply additional independent votes. Selection spans the route when the reference limit is reached.
- Only high-confidence bilinear depth neighborhoods within 3 m, passing the existing edge test and a 3 cm maximum local depth spread, vote. Frames without confidence data, rejected geometry, invalid poses or unsupported dimensions cannot vote.
- A point is removed only if at least three independent references place it clearly in measured free space, beyond **twice** the existing depth agreement tolerance, and fewer than two references support it. Two supporting views protect real thin surfaces even when other views disagree.
- Occluded, missing, far-range and out-of-frame observations do not vote against geometry. Points without enough evidence remain. No point is moved, no plane is fitted or flattened, and surviving XYZ/RGB values remain unchanged.
- If more than 10% of points would be removed, validation retains the complete input and reports `excessiveConflictFallback`. Missing reference data or interruption also leaves the input unchanged; the pipeline's existing cancellation/memory guard still determines whether a result is published.

The two `UInt8` counters cost 2 bytes per output point (about 0.48 MiB at 250,000 points). Compaction starts only after all votes pass; it does not allocate a second output cloud. The existing TSDF is released before validation. `surfaceValidation` records reference count, protected points, proposed/applied removals, workspace counters, status and elapsed time. Set `CaptureConfig.surfaceVisibilityValidation = false` for a controlled replay comparison. The voxel-only fallback remains unchanged.

This check targets **unsupported foreground ghost surfaces**. It cannot infer the true side of glass, resolve surfaces hidden behind an opaque wall, or fix a shared camera-pose/depth bias. Sparse reference sampling may miss valid support. Original photos/depth are preserved; inspect important thin/transparent structures before relying on dimensions. Local point-cloud thickness includes real structures and is not ground-truth dimensional accuracy.

## Reproducible verification

Run `bash tools/test_surface_reconstruction.sh` and `bash tools/test_fusion_memory.sh`, then build unsigned device and Simulator targets sequentially. The surface suite covers ghost rejection, protected nearby parallel surfaces, occlusions, uncertain depth, missing confidence, repeated camera positions, cancellation and excessive-conflict fallback. Replays must compare geometry/coverage as well as time; deleting points alone is not evidence of improved accuracy.

The TSDF integration cache also reuses the last resident block across successive points and avoids duplicate cell reads within half-voxel steps. This preserves arithmetic order, one vote per frame, LRU timestamps, resolution and allocation budgets. Its effect can be isolated using `SurfaceTSDF(cacheBlockLookups: false)` in tests.

## Local replay evidence (2026-09-23)

Read-only M1 Pro replays used the saved final poses and depth maps, the same 2 cm TSDF, and a fixed 6 GiB headroom injection to exercise the bounded mobile path. No scan or image is committed to the repository.

| Scan | Points before → after | Local thickness median before → after | Missing evaluated patches | Occupied 10 cm cell retention |
| --- | ---: | ---: | ---: | ---: |
| 377 frames (reported overlapping walls) | 74,810 → 72,464 | 3.676 → 3.527 cm | 0 / 2,626 | 98.59% |
| 399 frames | 105,576 → 104,202 | 5.328 → 4.991 cm | 0 / 2,523 | 99.17% |
| 569 frames | 250,000 → 247,021 | 1.678 → 1.529 cm | 0 / 2,878 | 99.37% |

Thickness is the P10–P90 normal-depth band in fixed 20 cm-radius PCA patches. Patches include furniture and real layers; these figures **are not wall measurement errors**. Zero missing evaluated patches does not prove every thin structure is preserved. Surviving XYZ/RGB values are exact subsets of the baseline, and two separate final processes produced byte-identical output on the 377-frame scan. Pose files and source images/depth were not modified.

On that 377-frame scan, the previous code took **134.92 s with `-Onone` versus about 5.03 s with `-O`** on the same Mac; sorted XYZ/RGB were identical. The phone's supplied report recorded 99.44 s but did not identify its build mode, so Debug is a supported diagnosis to check, not a proven fact about that installation. Two final optimized replays including visibility validation took 5.09 / 4.87 s; two previous optimized runs took 5.03 / 5.03 s. TSDF CPU time fell from about 2.71 to 2.41 s, while the new check added about 0.15 s. Overall optimized time is effectively unchanged with the extra validation; the main expected practical speed gain is choosing an optimized app build. Desktop measurements do not predict phone timing, thermal limits, or crash immunity.
