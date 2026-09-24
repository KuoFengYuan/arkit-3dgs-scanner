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

## Range priority for far depth

Consensus compares a sample only with cameras near its own. In larger rooms those references see the same far surface from a similar range, so their range-dependent errors agree and pass together. Desktop replays of two iPhone 17 Pro scans compared every frame's pixels with planes fitted to depth measured within 3 m. Beyond about 2.5–3 m, per-frame median offsets reached 1–5 cm (walls measured farther, floors or ceilings closer), larger than the 2 cm voxel. Per-voxel weights cannot merge samples that land in different voxels: removing the weight cap, stronger range weights, a 70° incidence limit, or the experimental TSDF each changed median thickness by 5% or less.

Offline fusion therefore splits measured depth by camera-space range, `fusionNearRangeM` (default 3 m):

- Depth within the near range fuses as before. A scan without farther depth produces a bit-identical cloud.
- Farther depth passes the same consensus checks, then fuses into a separate key space at `fusionFarVoxelScale` times the fusion voxel (4 cm by default). Noisy far data can no longer fill the cell budget and coarsen near surfaces.
- With experimental `surfaceCoverageProtection = true` (disabled by default), range replacement runs after sampling, TSDF fallback and visibility validation. A far point is omitted only when the final measured near surface covers its projected footprint with a compatible normal, within `fusionFarExclusionM` (at most 15 cm). Missing coverage, edges, incompatible directions and independently supported parallel surfaces remain. See [coverage protection](SCAN_FUSION_DIAGNOSTICS.md#coverage-protection).
- ARKit mesh supplementation, live preview, and depth-consistency thresholds are unchanged. The experimental TSDF integrates near-range samples only; far fill reaches its output through the existing voxel fallback.
- `refusion-progress.json` introduced these fields in version 7 and keeps them in version 10: `nearRangeM`, `farExclusionM`, `farVoxelSizeM`, `farCells`, `farExcludedNearSurface`, and `farExportedPoints`. Older reports remain readable. `fusionNearRangeM = 0` restores single-range fusion.

The following numbers describe the original spherical exclusion implementation, before the optional version 10 coverage protection. They are historical evidence, not measurements of the current algorithm.

| Desktop replay with mobile memory limits | Previous fusion | Range priority |
| --- | ---: | ---: |
| 9F8040 (569 frames): grid voxel / peak cells | 4 cm, coarsened / 785,576 | 2 cm / 718,650 |
| 9F8040: median local P10–P90 thickness | 7.71 cm | 3.67 cm |
| 9F8040: 90th percentile of local thickness | 12.24 cm | 9.46 cm |
| 7F2187 (399 frames, close range): median thickness | 5.26 cm | 5.30 cm |

Both clouds were measured at the previous cloud's patch centers and normals, as above; the earlier table sampled the older preview's centers, so its 7.01 cm is not directly comparable with 7.71 cm here. On 9F8040, 72% of 2,700 comparable patches became thinner and 9 lost support. 81.8% of previously occupied 10 cm cells remain occupied and 97.4% of the top-down footprint remains; the lost footprint lies beside walls where only far depth existed, 4–12 cm from the near-range wall. Of 139,745 far cells, 125,159 were omitted next to near surfaces. The output reached the 250,000-point cap instead of 190,974 because the grid no longer coarsened. The capped output is sampled in dictionary order, which varies between processes; two runs gave 3.63–3.67 cm and 81.5–81.8% retention. The close-range scan changed within the metric's noise.

Surfaces seen only from far away keep their far-range error. The former spherical exclusion could remove far fill around the edges of near coverage; version 10 offers opt-in final-surface coverage checks. Real replays increased local thickness, so the former exclusion remains the default pending plane-ROI validation. A badly posed near view also takes priority over far data, so this step does not correct poses. Thickness includes furniture and real layers; it is not absolute dimensional accuracy.

## Historical runtime tradeoff (multi-view consensus)

One Mac Release comparison with mobile memory limits, including export preparation, took about 11.33 seconds for the old method and 12.02 seconds for the new one (about 6% longer). Consistency checking took about 2.07 → 3.00 seconds. Neither run repeated BA. These are Mac measurements, not iPhone performance; this is a quality improvement with additional computation.

## Reproduction and validation

- `test_lidar_consistency.swift`: 51 checks including convergence, 2 cm bound, camera-ray preservation, rotation, occlusion, confidence, references, mesh, and memory pressure.
- `test_large_scan_memory.swift`: 24 checks including 1,000 depth frames, bounded caching/output, and cancellation. Diverse references need not have more cache hits than loads; tests verify reuse and at most four reference loads per frame.
- `test_history_training_export.swift`: 14 checks for COLMAP export and legacy history.
- `test_range_priority.swift`: 13 checks for separate far key space, coarsening, near-surface exclusion, far-only fill, v7 report fields, the desktop export path, and bit-identical near-only scans. `tools/test_fusion_memory.sh` runs it with the other fusion suites.
- `test_surface_coverage.swift`: 27 checks covering opt-in defaults, compact normals, holes/edges, thin-structure protection across stages, output budgets and cancellation.
- Historical iPhone and Simulator Debug builds passed. Updated real-device performance still needs measurement.

The refusion tool creates a new directory and shares immutable media by hard links, falling back to copying across filesystems. `--legacy-depth` reproduces the earlier temporal-neighbor check and single-range fusion; `--no-range-priority` keeps the current consensus but disables the range split.

```sh
swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,ExportManager,TrainingFrameSelector}.swift \
  arkit-3dgs-scanner/History/ScanLibrary.swift tools/refuse_dataset.swift -o /tmp/refuse_dataset
/tmp/refuse_dataset SOURCE NEW_OUTPUT
/tmp/refuse_dataset SOURCE SINGLE_RANGE_OUTPUT --no-range-priority
/tmp/refuse_dataset SOURCE LEGACY_OUTPUT --legacy-depth
python tools/compare_surface_thickness.py LEGACY_OUTPUT/review.ply NEW_OUTPUT/review.ply REPORT_DIR
```

The Python comparison needs numpy, scipy, and matplotlib. Desktop tools are for reproducibility; phone fusion itself needs neither a desktop nor a network.
