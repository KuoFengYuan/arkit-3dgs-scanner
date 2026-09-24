# LiDAR consistency, live preview, and capture gating

**English** | [繁體中文](LIDAR_QUALITY_AND_PREVIEW.zh-TW.md)

This work addresses thick/double surfaces, floating points, uneven preview updates, and photos pausing on small movements while point counts increased. A history screenshot alone cannot quantify geometry error. The checks below are implementation and synthetic evidence; the later real-scan comparison is documented in [surface consensus](LIDAR_SURFACE_CONSENSUS.md).

## Confirmed issues

- Different-depth samples in different voxels could form multiple layers even with low weights. Same-cell averaging cannot remove cross-cell ghosts.
- Mesh's old 10 cm color-visibility tolerance was not a geometry-accuracy threshold and could refill rejected layers.
- Preview only drained two dirty tiles after fusion using unordered Set traversal. Frequently changing tiles could starve others, and capture pauses stopped draining.
- Busy workers or failed image copies still advanced the last-fused timestamp, delaying retries.
- Photos checked sharpness separately from point insertion, while the HUD did not represent every rejection condition.
- Averaging magnitudes of per-frame position jitter created positive speed and inflated close-range blur estimates.
- Freezing sharpness baseline at 0.2 rad/s could keep comparing a newly viewed low-texture surface with a previous surface.
- Shutter state advanced before buffer copying succeeded, consuming a viewpoint after a failed copy.

## Depth consistency

`DepthConsistencyView` holds small depth/confidence arrays, intrinsics, and camera inverse matrices. It projects candidates into another view and bilinearly samples four confident, same-surface pixels. Discontinuities, low confidence, out-of-frame positions, and invalid values do not vote.

Tolerance is `0.015 m + measuredDepth × 0.005`, or 2.5 cm at 2 m. This parameter is not an accuracy claim.

| Observation | Vote |
| --- | --- |
| Point agrees with measured depth | Support |
| Point lies behind a visible foreground | Occluded; no contradiction |
| Point lies in front of the measured surface | Free-space contradiction |
| Invalid, out of bounds, low confidence, discontinuity | Unobserved |

Support must exceed contradictions. Live preview requires at least one support; current offline consensus requires two when at least two references exist, as described in [surface consensus](LIDAR_SURFACE_CONSENSUS.md).

Live preview uses the previous eligible raw-depth packet. The first establishes a reference; the next can add geometry. Epoch changes, repeated/reversed timestamps, or gaps over 0.5 seconds reset it. Offline fusion uses at most four references with corrected poses; current selection prefers spatially diverse views and falls back to temporal neighbors. Dropped, duplicate, near-time, missing, and corrupt sources are excluded. Mesh must pass color visibility and depth support.

Unsupported regions can become sparse. An empty offline result can retain a validated live fallback. Correlated sensor errors and systematic pose drift can still pass; support votes are not independent measurements.

## Preview scheduling

`DirtyTileQueue` is a deduplicated FIFO. Editing a pending tile does not move it ahead; an updated tile that changes again rejoins the tail.

Rendering and fusion are scheduled separately. Batches wait about 33 ms after the previous batch and request at most eight tiles / 24,000 points. An oversized tile is sent whole to avoid starvation, so the budget is not a strict deadline or a 30 FPS guarantee.

Only accepted packets advance fusion timing. The actor packs geometry; the main thread applies SceneKit nodes without implicit animations and avoids publishing unchanged counts. Stop, backgrounding, and dismissal cancel refresh work. Resume marks tiles dirty again. Pending anchors are acknowledged only after main-thread application so cancelled batches do not lose them.

## Shared motion/photo/point decisions

`CaptureQualityPolicy` centralizes tracking, texture, severe exposure blur, speed, and sharpness. Photos and new point packets share `allowCapture`. Already-accepted background work may briefly continue to appear after a quality pause.

`CaptureMotionEstimator` estimates velocity from about 80 ms net displacement, avoiding rectified per-frame jitter. Rotation uses quaternion differences; gyroscope data strengthen it only within 20 ms of the ARFrame timestamp.

Sharpness baseline decays with elapsed time and freezes only at severe motion. Exposure blur is separated from rolling-shutter risk:

```text
exposureBlurPixels = blurPixels × exposure / (exposure + readout)
```

The 24 px blocking threshold applies to exposure blur, while total estimated risk remains in guidance, metadata, and weights. Severe speed limits are 1.6 rad/s and 1.6 m/s; sharpness ratio 0.4 and tracking checks remain. More walking frames can be accepted, but higher-risk frames still need later verification. Brief focus waits do not immediately flash the strong red warning.

The HUD distinguishes recovering tracking, low texture, moving too fast, and waiting for sharpness. Eligible frames still need new viewpoints, minimum interval, and a write slot. `SmartShutter.isDue` is pure; `markCaptured` runs only after a photo copy is ready, permitting retry after copy failure.

## Preview diagnostics

`preview-performance.json` records candidate/accepted observations, fusion count and mean/max time, packed batches/tiles, maximum pending tiles, packing time, main-thread application time, and quality rejection counts. Observation counts are not unique points; work durations are not GPU display FPS. Compare on identical devices, paths, lighting, and build modes.

## View coverage heat map

The heat map (point-cloud tool rail, thermometer icon) and the percentage beside the shutter show how widely each surface has been seen. Triangulation and 3D Gaussian training need views from different positions. Looking at the same spot 20 times from one place adds nothing, and turning on the spot does not move the camera.

### How it is measured

- `TiledFusedGrid.ViewSpan` keeps, for every 10 cm view cell of a tile, the two viewing directions farthest apart so far. Directions run from the cell centre to the camera, so only camera movement adds angle, whether sideways, up or down.
- The span is the angle between those two directions, with no fixed direction bins.
- Colour goes from red (0°) through yellow to green at 30° or more. The legend shows the scale.
- 30° is about a 1.1 m sideways pass at 2 m.
- The percentage is the share of 1 cm preview voxels whose view cell has reached 30°. It is maintained incrementally and recounted after coarsening or trimming.

### Why the earlier rating was wrong

Each 1 cm voxel previously recorded which of 16 world direction bins it had been seen from (8 azimuth sectors × looking down or not) and turned green at three bins. That rating failed in three ways:
- **Too fine a cell.** Preview voxels are 1 cm, about the LiDAR noise, so observations of one surface were split across neighbouring voxels. Each voxel saw only a few directions.
- **Sector boundaries.** A 1° move across a sector line counted as a new direction, while a 40° move inside one sector did not.
- **Vertical movement barely counted.** Elevation had only two bins.

Replays of three LiDAR scans compare both ratings with the true span: the exact largest angle between any two camera directions from each 10 cm region. `tools/replay_view_diversity.swift` inserts every frame's depth, sampled every second pixel, into the preview grid.

| | 7F2187 | 9F8040 | 916C58 |
| --- | --- | --- | --- |
| Voxels with a true span ≥ 30° | 58.3% | 83.3% | 52.5% |
| Earlier rating: three bins or more | 5.8% | 1.8% | 4.2% |
| Earlier rating: one bin (red) although the true span is ≥ 30° | 35.9% | 70.8% | 33.2% |
| Current rating ≥ 30° | 57.7% | 83.3% | 51.8% |
| Current vs true span: median / P90 difference | 0.0° / 1.2° | 0.0° / 1.4° | 0.0° / 0.3° |

With the two-direction approximation, fewer than 1% of voxels fall in a different band (below 10°, 10–30°, 30° or more) than the true span.

### Limits

- The span is measured per 10 cm region. A crevice inside a region that some cameras could not see is rated like the rest of the region.
- The rating counts directions, not image quality: grazing or blurred views add angle too.
- 30° is a coverage guide, not an accuracy guarantee.
- The replay skips the live per-frame filters, and the thresholds were checked on these scans only.
- A related fix: points that rounded exactly onto a tile boundary used to start a new tile, and request a new anchor, on every frame. They now join the existing tile.

## Stop-time safeguards

Reports described crashes seconds after Stop, before visible fusion progress. Without crash/jetsam records, allocation risks are evidence, not a confirmed sole cause.

The stop sequence now:

1. Shows processing and drains accepted photo/fusion/render work.
2. Releases live SceneKit geometry and the image pool, retaining the accumulator for resume.
3. Samples at most 100,000 preview points directly from tiles and saves history without first copying/downsampling the full cloud. Final output atomically replaces it.
4. Copies at most 150,000 mesh vertices with a whole-scene sampling stride, capacity reservation, anchor-to-anchor yielding, buffer bounds, and finite-coordinate checks. ARKit's own mesh allocation is separate.
5. Saves the world map, finishes the RoomPlan segment, then pauses ARSession. Map serialization does not overlap model building/refusion. Below 128 MiB available memory, map saving is skipped with a notice while photos/preview remain.
6. Runs blur review, RoomPlan modeling, refusion, and required point-cloud floor-plan work sequentially. Successful RoomPlan no longer requests another two-million-point floor-plan source.

Each fusion frame uses an autorelease pool. Initial iOS grid budgeting reserves 64 MiB and uses at most a quarter of remaining memory, without the old 200,000-cell minimum. Coarsening repeats until within capacity. These application budgets do not bound system allocations.

## Pressure during fusion

The mobile grid estimates 128 bytes per cell within a default 96 MiB dictionary budget (up to 786,432 cells), separate from overall RSS. Available memory is rechecked before decoding, insertion, and export. Below 256 MiB, capacity is reduced using both current estimated grid cost and remaining space. Coarsening releases shards progressively; when points straddle the origin and coarsening cannot converge, bounded sampling stops ineffective doubling.

Below 96 MiB, processing returns `memoryPressure` before another decode/insertion/full output. Review uses at most 100,000 live points, skipping expensive floor-plan/output work. Raw images/depth and resumable accumulator remain. This is a fallback, not successful refined fusion, and cannot guarantee reacting before a sudden system allocation spike.

Mobile output uses one bounded proportional sample rather than a full point array plus another spatial dictionary. Consistency and isolation filters remain; fewer details or fewer points than the cap are possible. Desktop tools retain their quality-ranked path.

`refusion-progress.json` is atomically updated at start, every eight frames, before output, and at completion. Fields include status/stage, frame counts, `peakCells`, limits/reductions, available memory, output count, and final voxel size. `peakCells` is measured after per-frame insertion, not allocation peak/RSS. A report left at `running` locates the last completed stage but does not diagnose the crash alone.

## Denser viewpoints

Defaults changed from 10 cm / 6° / 0.15 seconds to 5 cm / 3° / 0.10 seconds. Near-range LiDAR translation uses `min(5 cm, max(2 cm, depth × 0.05))`; RGB uses a 4 cm floor and requires 4 cm baseline even for rotation triggers. Unknown depth uses 5 cm.

The minimum interval is not fixed capture FPS. Stationary views do not continuously save duplicates. Tracking, sharpness, severe blur, and three-write backpressure still apply. More photos increase storage and processing time without proving better geometry or angular coverage.

## Validation

```sh
swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,PointCloudFusion}.swift \
  tools/test_lidar_consistency.swift -o /tmp/fable-lidar-test
/tmp/fable-lidar-test

swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,Utils,SmartShutter,CaptureQualityPolicy}.swift \
  tools/test_capture_quality_policy.swift -o /tmp/fable-quality-test
/tmp/fable-quality-test

swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,PointCloudFusion}.swift \
  tools/test_stop_processing.swift -o /tmp/fable-stop-test
/tmp/fable-stop-test

swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,PointCloudFusion}.swift \
  tools/test_view_coverage.swift -o /tmp/fable-view-coverage
/tmp/fable-view-coverage          # 11 checks

swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,PointCloudFusion}.swift \
  tools/replay_view_diversity.swift -o /tmp/replay_view_diversity
/tmp/replay_view_diversity SCAN --stride 2
```

The 11 view-coverage checks cover:
- repeated views from one position staying at 0°;
- a 1.4 m sideways pass at 2 m reaching 30°;
- a small move across an old sector line not counting as multiple angles, while a 40° move inside one sector counts as 40°;
- vertical movement counting like sideways movement, and depth noise having no effect;
- heat-map colours;
- the incremental completeness matching a full recount, including after trimming and coarsening;
- points on tile boundaries joining the existing tile.

Historical validation comprised 173 checks: 26 stop-capacity, 39 depth/preview, 30 capture-policy, 18 fusion, 29 RGB reconstruction, 26 camera-only, and five shard checks; unsigned device/Simulator builds passed. The parallel desktop path retains a pre-existing Sendable warning.

Depth fixtures cover false layers, occlusion, consensus, edges/confidence, time/epoch reset, FIFO fairness, budgets, cancellation, and anchor acknowledgment. A five-frame 2 m plane with 1.9/2.1 m false layers and a 1.94 m mesh layer retained over 100 points all within 3 cm of the true plane. This is ideal synthetic evidence.

Motion tests include 2 mm jitter, 0.3 m/s translation, time-aligned gyro, focus recovery, failed-copy retry, 1.1 m/s walking, long exposure, and fast motion. Capacity tests cover low memory before frame three and before export, post-decode reductions, raw-media preservation, bounded samples, nonconverging coarsening, and index calculations for up to 20 million mesh vertices. That last test does not allocate 20 million real device vertices. Shutter tests cover baseline/angle/time, near-range overlap, stationary deduplication, and at least 11 views over a two-second 0.3 m/s path.

Real-device wall thickness, dimensions, floating points, UI FPS, and peak memory still need measurement. Apple documents [temporal smoothing](https://developer.apple.com/documentation/arkit/arframe/smoothedscenedepth); this pipeline prefers raw depth and validates it using known poses.
