# Multi-view depth consensus for thick LiDAR surfaces

**English** | [繁體中文](LIDAR_SURFACE_CONSENSUS.zh-TW.md)

## Problem and implementation

Earlier refusion selected up to four nearby frames by time. Dense bursts often gave almost identical camera positions. Requiring more supporting than contradicting observations still retained depth biases inside the tolerance, allowing several voxel layers on one surface.

`DepthSampleFilter.swift`, `RefusionEngine.swift`, and `CaptureConfig.swift` now implement the same consensus for stopped scans and history optimization:

- Prefer similarly directed cameras 6–40 cm apart, at least 0.25 seconds apart, with a target baseline near 15 cm. Keep references about 6 cm apart where possible. Select at most four and fill shortages with temporal neighbors.
- With two or more references, require at least two supports and more supports than free-space contradictions. A short scan with one available reference may use one support. Invisible, occluded, or low-confidence observations are not supports.
- For accepted depth, take the median supported correction along the source camera ray, including the source's zero-correction vote. Bound every candidate correction to 2 cm. Preserve pixel/color correspondence; do not snap whole surfaces to planes.
- Reproject after correction. If support decreases or contradictions increase, retain the original position. Discontinuities, low confidence, and out-of-tolerance surfaces are excluded from averaging.
- Mesh supplementation passes the same minimum-support test. Mesh points are not shifted along rays.
- Reuse small scratch arrays. Stream frames and retain an LRU depth cache bounded to eight frames / 2 MiB. Current frames, references, grid, and application state require additional memory.
- Refusion report v3 includes optional `diverseReferences` and `rayConsensus` fields, preserving older report decoding.

`depthDiverseReferences` and `depthConsensusEnabled` default to enabled; `depthConsensusMaxShiftM` is 0.02 m. Live preview retains its cheaper temporal check. Full consensus runs after capture.

## Recorded 569-frame comparison

Dataset: `scan_20260921_113412_9F8040`. Both runs used saved poses, original depth, and mobile working-set limits without rerunning pose refinement. This dataset did not preserve ARKit mesh; synthetic tests cover mesh rejection.

| Metric | Existing preview | New fusion |
| --- | ---: | ---: |
| Points | 240,214 | 190,974 |
| Median local P10–P90 thickness | 8.94 cm | 7.01 cm |
| 90th percentile of local thickness | 13.00 cm | 11.66 cm |

Of 2,421 comparable patches, 93.7% became thinner; median thickness decreased about 21.6%. Two additional baseline patches lacked sufficient new points. Median local surface position shift was about 0.34 cm.

A control rerunning the old algorithm without mesh yielded 237,755 → 190,974 points and 8.88 → 6.85 cm median thickness across 2,448 comparable patches, about 22.9% lower. Both grids coarsened from 2 to 4 cm, so the improvement was not simply a larger voxel setting.

The measurement uses a fixed random seed, up to 3,000 baseline centers, 20 cm neighborhoods, and PCA to exclude line-like/nonplanar regions. Both clouds are measured at the **same centers and baseline normals**. Thickness can include furniture, occlusions, and real layered structures; it is not absolute dimensional accuracy.

About 84.6% of baseline occupied 10 cm volume cells remain occupied. This is volume-cell overlap, **not surface coverage**; thinning itself reduces occupancy. Neither point-count reduction nor this ratio proves that coverage is complete.

The original pose-refinement holdout residual worsened from 5.76 to 5.95 px, so that correction was not forced. Local depth consensus cannot fix all long-range pose drift or guarantee artifact-free 3DGS training.

## Runtime tradeoff

One Mac Release comparison with mobile memory limits, including export preparation, took about 11.33 seconds for the old method and 12.02 seconds for the new one (about 6% longer). Consistency checking took about 2.07 → 3.00 seconds. Neither run repeated BA. These are Mac measurements, not iPhone performance; this is a quality improvement with additional computation.

## Reproduction and validation

- `test_lidar_consistency.swift`: 51 checks including convergence, 2 cm bound, camera-ray preservation, rotation, occlusion, confidence, references, mesh, and memory pressure.
- `test_large_scan_memory.swift`: 24 checks including 1,000 depth frames, bounded caching/output, and cancellation. Diverse references need not have more cache hits than loads; tests verify reuse and at most four reference loads per frame.
- `test_history_training_export.swift`: 14 checks for COLMAP export and legacy history.
- Historical iPhone and Simulator Debug builds passed. Updated real-device performance still needs measurement.

The refusion tool creates a new directory and shares immutable media by hard links, falling back to copying across filesystems.

```sh
swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,ExportManager,TrainingFrameSelector}.swift \
  arkit-3dgs-scanner/History/ScanLibrary.swift tools/refuse_dataset.swift -o /tmp/refuse_dataset
/tmp/refuse_dataset SOURCE NEW_OUTPUT
/tmp/refuse_dataset SOURCE LEGACY_OUTPUT --legacy-depth
python tools/compare_surface_thickness.py LEGACY_OUTPUT/review.ply NEW_OUTPUT/review.ply REPORT_DIR
```

The Python comparison needs numpy, scipy, and matplotlib. Desktop tools are for reproducibility; phone fusion itself needs neither a desktop nor a network.
