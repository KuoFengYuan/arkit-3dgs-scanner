# Fusion memory control for large scans

**English** | [繁體中文](LARGE_SCAN_MEMORY.zh-TW.md)

## Reported failures and overlapping allocations

Two successful device logs recorded 403 frames / 519,789 cells / 74.41 seconds and 257 frames / 425,007 cells / 47.44 seconds; larger scans reportedly crashed during fusion. Without the failed run's crash or jetsam report, no single cause can be established.

Two avoidable overlaps were found: live CPU preview cells remained fully allocated during offline fusion, and floor-plan generation raised the output target to two million points before another downsampling dictionary was built. Earlier logs printed only the ordinary 250,000-point setting, explaining output above that displayed limit.

## Current working set

| Data | Bound or handling |
| --- | --- |
| RGB, depth, confidence | Written to disk continuously; decoded one frame at a time, without a new photo-count limit |
| Retained live cells | Reduced proportionally to at most 100,000 after GPU release and preview persistence |
| Anchors and remaining cells | Preserve local positions, colors, weights, and direction bits for resumed scanning |
| Offline grid | Estimated 96 MiB budget plus available-memory reductions; 128 bytes/cell is an estimate, not RSS |
| Insertion scratch | Serial mobile insertion without shard candidate copies; capacity checked every 1,024 points, allowing a small temporary overshoot |
| Reference-depth cache | LRU capped at eight entries and 2 MiB of depth/confidence arrays; cleared below 256 MiB available memory |
| Final cloud / floor-plan input | Mobile target clamped to `exportMaxPoints`, currently 250,000; no extra large downsampling dictionary |
| Features / pose metadata | Live tracker keeps four descriptor frames and at most 200,000 historical observations; pose/filename metadata still grows with frame count |

Live cells are removed and replaced tile by tile to avoid retaining a snapshot of the entire old dictionary. Voxel size and tile coordinates remain unchanged, but resumed preview initially has less detail. Full-resolution saved media remain available for final fusion.

The cache budget excludes the current frame, active reference views, JPEG decoding, and container overhead. An unusually large depth image may be used once without caching. Cache limits reduce repeated allocation/I/O; they do not guarantee a speedup or total process memory limit.

Serial insertion preserves weighted ordering and LiDAR priority. Without capacity reductions, regression output matches the desktop parallel-shard path bit for bit. Under pressure, different coarsening timing can change results. Desktop tools retain their higher-density/parallel options.

## Cancellation and fallbacks

Leaving or resetting sets a separate cancellation flag. Fusion checks it before each frame, after candidate generation, and before export, returning `cancelled` rather than a partial result. Generation checks reject stale progress, pose, and floor-plan callbacks. Cancellation does not instantly interrupt ImageIO or ARKit calls.

Below 96 MiB available memory, fusion returns `memoryPressure` and review uses a bounded live preview. Raw media remain intact. More photos primarily increase streaming time, but a larger spatial extent can still force grid coarsening. The limited final cloud may omit thin/short walls or need coarser floor-plan cells. These safeguards do not relax depth-consistency thresholds.

## Diagnostics

Refusion report v2 added:

- `effectiveOutputLimit`: actual output cap for this run.
- `depthCacheHits`, `depthCacheLoads`, `depthCachePeakBytes`, `depthCachePeakEntries`.
- `depthReadSeconds`, `unprojectSeconds`, `consistencySeconds`; the latter includes reference reads. Mesh timing remains in logs.
- `cancelled`, alongside `memoryPressure` and `completed` statuses.

Times are wall-clock durations. The first total-time segment includes stop/drain work, map and preview saving, and keyframe reads. Refusion includes any floor-plan work inside that stage. Final history persistence happens after the total is printed and is not included.

## Validation

```sh
swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,PointCloudFusion}.swift \
  tools/test_large_scan_memory.swift -o /tmp/fable-large-scan-test
/usr/bin/time -l /tmp/fable-large-scan-test
```

The fixture streams 1,000 JPEG/depth frames with 256×192 depth, checks cache/grid limits, mobile output clamping, plane location, cancellation, and media preservation. It reuses synthetic image/depth files with varying camera positions; it does not simulate 1,000 complex indoor photos or ARKit/RoomPlan memory.

A separate 520,000-cell surface spanning 20 m tests the 250,000-point output cap and spatial extent. Preview reduction checks cell counts, corrected coordinates, anchors, and resumed insertion. Historical validation passed 24 large-scan, 39 depth-consistency, and 26 stop-capacity checks plus device/Simulator builds.

Historical Mac maximum RSS was 107,839,488 bytes (about 103 MiB), including the 520,000-cell fixture but excluding ARKit, RoomPlan, SceneKit, and device GPU allocations. The 1,000-frame case deliberately uses a small grid budget to exercise coarsening. This is not an iPhone memory ceiling or a guarantee against crashes. The desktop parallel path still has a pre-existing Sendable warning; mobile uses serial insertion.
