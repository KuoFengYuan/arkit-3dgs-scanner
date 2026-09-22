# Fusion memory control for large scans

**English** | [繁體中文](LARGE_SCAN_MEMORY.zh-TW.md)

## Confirmed iPhone 17 Pro completion crash (2026-09-22)

Two device reports (13:13 and 14:41) show `EXC_CRASH / SIGABRT`, with an Objective-C exception from `NSConcreteFileHandle.writeData` called by `RefusionEngine`. The 14:41 scan had processed all **422 frames**, reached `exportFraction: 1`, and recorded **5,931,808,088 available bytes** at minimum. This evidence identifies a failure writing the final diagnostic message, not a jetsam memory kill for those two runs.

The final `FileHandle.standardError.write` used a legacy API that can raise an Objective-C exception if the debugging output handle is unavailable. Swift `do/catch` does not catch that exception. Fusion now uses unified `Logger` output, so a missing stderr transport cannot prevent the completed report/result from being published. A subprocess regression supplies read-only stderr and checks successful completion/report persistence. The reports do not establish why the output handle became unavailable.

## Reported failures and overlapping allocations

Two successful device logs recorded 403 frames / 519,789 cells / 74.41 seconds and 257 frames / 425,007 cells / 47.44 seconds; larger scans reportedly crashed during fusion. Without the failed run's crash or jetsam report, no single cause can be established.

Two avoidable overlaps were found: live CPU preview cells remained fully allocated during offline fusion, and floor-plan generation raised the output target to two million points before another downsampling dictionary was built. Earlier logs printed only the ordinary 250,000-point setting, explaining output above that displayed limit.

## Current working set

| Data | Bound or handling |
| --- | --- |
| Capture resources at stop | Drain writes and features, clear Core Image encoding caches and live feature state before offline work; preserve the open writer for resume |
| Covered AR view | Stop its rendering during processing/review; retain the session for resumed scanning |
| Requested depth | Request the consumed `sceneDepth` stream; omit unused `smoothedSceneDepth` |
| RGB, depth, confidence | Written continuously; one geometry frame plus at most one prefetched depth-resolution RGB image, without a new photo-count limit |
| Retained live cells | Reduced proportionally to at most 100,000 after GPU release and preview persistence |
| Anchors and remaining cells | Preserve local positions, colors, weights, and direction bits for resumed scanning |
| Offline grid | Estimated 96 MiB budget plus available-memory reductions; 128 bytes/cell is an estimate, not RSS |
| Insertion scratch | Serial mobile insertion without shard candidate copies; capacity and interruption checked every 1,024 points, including during coarsening; a stopped mutable grid is discarded |
| Reference-depth cache | LRU capped at eight entries and 2 MiB of depth/confidence arrays and exact quad-validity masks; cleared below 384 MiB available memory |
| Final cloud / floor-plan input | Mobile target clamped to `exportMaxPoints`, currently 250,000; no extra large downsampling dictionary |
| Features / pose metadata | Live tracker keeps four descriptor frames and at most 200,000 historical observations; pose/filename metadata still grows with frame count |

Live cells are removed and replaced tile by tile to avoid retaining a snapshot of the entire old dictionary. Voxel size and tile coordinates remain unchanged, but resumed preview initially has less detail. Full-resolution saved media remain available for final fusion.

The cache budget excludes the current frame, active reference views, JPEG decoding, and container overhead. An unusually large depth image may be used once without caching. Cache limits reduce repeated allocation/I/O; they do not guarantee a speedup or total process memory limit.

Serial insertion preserves weighted ordering and LiDAR priority. Without capacity reductions, regression output matches the desktop parallel-shard path bit for bit. Under pressure, different coarsening timing can change results. Desktop tools retain their higher-density/parallel options.

## Cancellation and fallbacks

Leaving or resetting sets a separate cancellation flag. Fusion checks it before each frame, after candidate generation, and before export, returning `cancelled` rather than a partial result. Generation checks reject stale progress, pose, and floor-plan callbacks. Cancellation does not instantly interrupt ImageIO or ARKit calls.

Below 192 MiB available memory, or upon a system memory-pressure event, fusion returns `memoryPressure` and review uses a bounded live preview. Raw media remain intact. More photos primarily increase streaming time, but a larger spatial extent can still force grid coarsening. The limited final cloud may omit thin/short walls or need coarser floor-plan cells. These safeguards do not relax depth-consistency thresholds. A per-job iOS memory-pressure listener latches warning/critical events even if the available-memory estimate remains optimistic. Native LiDAR frames require at least 224 MiB available before decoding (192 MiB reserve plus 32 MiB workspace); larger declared depth dimensions require more. Check depth-file size before loading it. Insertion and coarsening check pressure within a frame instead of waiting for the next one. More conservative fallback may occur earlier, preserving raw media and a preview rather than forcing a full-resolution result. System warnings are not guaranteed to arrive before every jetsam event.

See [experimental surface reconstruction](SURFACE_RECONSTRUCTION.md) for the additional 32 MiB resident TSDF block budget, 256 MiB temporary backing-data budget, exact-result prefetch and hybrid fallback.

## Diagnostics

Refusion report v5 adds `peakProcessFootprintBytes` (sampled process physical footprint on iOS), `memoryWarningCount`, `memoryStopReason`, and `requiredFrameHeadroomBytes`. The peak is sampled, not a guaranteed maximum; OS/GPU allocation changes between samples can still cause failure. Reasons distinguish system pressure, the reserved headroom, and frame-workspace preflight. Version 4 stage/export progress remains available to locate an interrupted job.

Refusion report v2 added:

- `effectiveOutputLimit`: actual output cap for this run.
- `depthCacheHits`, `depthCacheLoads`, `depthCachePeakBytes`, `depthCachePeakEntries`.
- `depthReadSeconds`, `unprojectSeconds`, `consistencySeconds`; the latter includes reference reads. Mesh timing remains in logs.
- `cancelled`, alongside `memoryPressure` and `completed` statuses.

Times are wall-clock durations. The first total-time segment includes stop/drain work, map and preview saving, and keyframe reads. Refusion includes any floor-plan work inside that stage. Final history persistence happens after the total is printed and is not included.

## Validation

```sh
bash tools/test_fusion_memory.sh
```

The suite also tests unwritable stderr, pressure during insertion/coarsening, early reserve/workspace checks, and a system warning with otherwise ample available memory. The fixture streams 1,000 JPEG/depth frames with 256×192 depth, checks cache/grid limits, mobile output clamping, plane location, cancellation, and media preservation. It reuses synthetic image/depth files with varying camera positions; it does not simulate 1,000 complex indoor photos or ARKit/RoomPlan memory.

A separate 520,000-cell surface spanning 20 m tests the 250,000-point output cap and spatial extent. Preview reduction checks cell counts, corrected coordinates, anchors, and resumed insertion. Historical validation passed 24 large-scan, 39 depth-consistency, and 26 stop-capacity checks plus device/Simulator builds.

Historical Mac maximum RSS was 107,839,488 bytes (about 103 MiB), including the 520,000-cell fixture but excluding ARKit, RoomPlan, SceneKit, and device GPU allocations. The 1,000-frame case deliberately uses a small grid budget to exercise coarsening. This is not an iPhone memory ceiling or a guarantee against crashes. The desktop parallel path still has a pre-existing Sendable warning; mobile uses serial insertion.
