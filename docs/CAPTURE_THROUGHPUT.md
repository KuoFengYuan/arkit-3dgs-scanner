# Capture throughput and live-preview budgets

**English** | [繁體中文](CAPTURE_THROUGHPUT.zh-TW.md)

## Evidence and goal

A historical 45-photo scan lasting about 83.24 seconds had median/P90 photo intervals of 2.026/2.179 seconds, while quality checks rejected only 32 of 5,005 frames. Its 834 preview fusions averaged about 66.1 ms (maximum 409.8 ms); main-thread geometry application averaged about 0.15 ms. Relaxing quality thresholds alone would not address the sparse capture.

The writer previously held a `pendingWrites` slot until `FeatureTracker.add` finished, even after the photo had been saved. Optional matching could occupy all three write slots. This coupling was removed; the old report lacks enough timing detail to attribute an exact fraction of its two-second interval.

## Photo and optional feature work

`FrameWriter` serializes JPEG, depth, confidence, and JSONL writes, with at most three pending photo jobs. An autorelease pool releases encoding scratch per write. Only successful writes increase the saved count; queue, encoding, and I/O durations are recorded separately.

After writing, `LatestFrameProcessor.submit` returns without waiting for matching. The actor retains one running and one newest pending job; newer submissions replace the pending job. Utility-priority processing uses owned image-buffer copies, never retained ARFrames. ARKit, preview, encoders, and pools have additional buffers, so this is not an app-wide buffer-count bound.

Stopping awaits photo jobs, drains feature work, then reads BA observations. Resuming uses the drained queue. Closing/resetting drops pending work and rejects stale callbacks by scan generation; any already-running task only holds the old tracker.

The live `FeatureTracker` retains four recent descriptor frames. Evicted tracked features become compact observations without image patches. Historical observations can still form tracks spanning at least three frames for BA. History is capped at 200,000 observations plus the recent frames; oldest excess observations are discarded and counted. This does not delete photos or change raw poses. Under load, not every saved photo receives live BA observations; the offline pass can process saved frames later.

## Live depth sampling

`PreviewSamplingBudget` limits each update to 6,000 candidate positions. A 256×192 depth map starts at stride 3 rather than the previous stride 2 / 12,288 positions. Rotating x/y offsets cover all pixels at a fixed stride, but camera motion, filtering, and stride changes can still leave gaps.

Work exceeding 35 ms increases the next stride. Twelve consecutive updates below 17.5 ms reduce it by one. Feedback ranges from the configured minimum to 6, but unusually large maps can require a larger effective stride to enforce the candidate cap. Coarsening and other operations can exceed the budget; this is not a hard real-time guarantee.

Original RGB/depth resolution, consistency thresholds, voxel size, and offline sampling are unchanged. A memory-pressure fallback to live preview can inherit its sparser sampling. Camera-only sparse features do not use this depth budget.

## Diagnostic files

`capture-performance.json` is saved before refusion and included in scan exports:

| Field | Meaning |
| --- | --- |
| `photoCandidates` | Frames passing quality and viewpoint/time checks, including backpressure retries; not unique photos |
| `writerBackpressureFrames` | Eligible frames encountered while all write slots were occupied |
| `imageCopyFailures`, `savedPhotos`, `maximumPendingWrites` | Copy failures, saved count, peak concurrent pending writes |
| `writeQueueTotalMS`, `writeQueueMaxMS` | Waiting from task creation until writer processing |
| `jpegTotalMS`, `jpegMaxMS` | Preparation, optional denoising, JPEG encoding |
| `fileWriteTotalMS`, `fileWriteMaxMS` | Image/depth/confidence/pose I/O |
| `savedIntervalTotalS`, `savedIntervalMaxS` | Intervals between sorted capture timestamps, including pauses before resumed scanning |
| `configuredMinimumIntervalS`, `poseRefinementEnabled` | Capture settings |
| `featureWork` | Submitted, completed, replaced, peak retained jobs, total/maximum matching time |
| `retainedFeatureFrames`, `archivedFeatureObservations`, `discardedFeatureObservations` | Descriptor/history budget diagnostics |

Preview report v2 adds `extractionTotalMS`, `consistencyTotalMS`, `gridInsertTotalMS`, `maximumSampleStride`, and `overBudgetFrames`. These measure CPU work, not screen FPS. Older scans do not acquire these fields retroactively.

## Validation

```sh
swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/CaptureWorkScheduling.swift tools/test_capture_work_scheduling.swift \
  -o /tmp/fable-scheduling-test
/tmp/fable-scheduling-test

swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{FeatureTracker,BundleAdjuster,PoseRefiner}.swift \
  tools/{test_stubs_core,test_feature_retention}.swift -o /tmp/fable-feature-retention-test
/tmp/fable-feature-retention-test

swiftc arkit-3dgs-scanner/Capture/TrainingFrameSelector.swift -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,FrameWriter,ExportManager}.swift \
  tools/test_capture_pipeline.swift -o /tmp/fable-capture-pipeline-test
/tmp/fable-capture-pipeline-test
```

Scheduling tests block the first feature job while 99 later submissions return, retain only the newest pending job, and verify draining, resume/close isolation, sampling caps, offset rotation, and feedback hysteresis. Twelve synthetic textured images exercise descriptor eviction with retained tracks, pixel coordinates, depth, history limits, and reset. Writer tests cover timings plus success/failure/retry behavior.

Historical checks passed: 17 scheduling/sampling, five feature-retention, five capture/export, 39 depth-consistency, and spatial-index regression with 28,000 brute-force comparisons; iPhone/Simulator unsigned Debug builds also passed. The pre-existing parallel refusion Sendable warning remains.

For device comparisons, keep hardware, light, path, and build mode fixed. Record median/P90 capture intervals, backpressure, feature replacements, mean/max fusion time, and over-budget fraction; then compare physical surface thickness and known dimensions. Denser photos or more candidate points alone do not establish accuracy. Updated device performance remains to be measured.
