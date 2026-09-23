# Capture architecture and interaction flow

**English** | [繁體中文](CAPTURE_ARCHITECTURE.zh-TW.md)

## Responsibilities

| Component | Responsibility |
| --- | --- |
| `CaptureSessionConfiguration` | Central ARKit configuration; depth/mesh follow hardware and the LiDAR toggle; only a new session loads a world map; no unused plane detection |
| `CaptureSessionState` | Camera permission, initialization, tracking, interruption, failure; capture is allowed only when ready |
| `CaptureController` | MainActor coordination of capture, processing, review, and export; UI does not directly mutate phase |
| `FrameWriter` | Actor-based JPEG/depth/pose writes, propagated failures, successful-write counts |
| `PointCloudAccumulator` / `PointCloudFusion` | Background fusion, anchor-local tiles, final anchor correction, backpressure and throttling |
| `DepthSampleFilter` | Shared confidence, edges, and incidence-angle checks |
| `ScanLibrary` | Actor managing scan storage, snapshots, legacy preview reconstruction, export, and deletion |
| `ScanHistoryView` | Lists, mode badges, 3D/photo review, deletion confirmation |
| `ScanRoutePlaybackView` / `PlaybackCameraPose` | Synchronized photo/path playback, progress, following, full screen |
| `ExportManager` | Background COLMAP/ZIP creation; publish ZIP only after temporary output succeeds |
| `CaptureView` / `HUDOverlay` | Lifecycle, availability, permission recovery, phase-specific guidance |
| `AppLanguage` / `L10n` | Persisted app language and complete-sentence localization for UI, progress, and errors |

Camera state and dataset phase are distinct. `scanning + relocalizing` retains the scan but pauses frame acceptance. `review` is entered after required processing and session pausing, so resuming cannot be interrupted by an old stop operation.

## Invariants

1. Permission and stable tracking are required before a new dataset is created, including direct `startScan()` calls.
2. Backgrounding pauses AR and motion monitoring. Returning preserves world coordinates and waits for stable tracking. Temporary inactivity from system permission dialogs is not treated as backgrounding.
3. Stop rejects new frames, waits for writes/features/preview fusion, then reads data for processing.
4. RoomPlan stop and ARSession pause precede review. Final RoomPlan model generation may still finish in the background.
5. Failed writes do not increase saved counts. Capture stops while preserving prior files. Closed writers explicitly reject later writes.
6. COLMAP/PLY/pose/floor-plan/ZIP failures preserve data for retry and restore the prior UI phase. ZIP success closes the writer and enters done. Optional native RoomPlan USDZ export retains its own handling.
7. New scans reset old summaries, floor plans, and previews. Async callbacks check scan generation.
8. Removing the ARView tears down capture; opening a floor-plan view does not.

## User flow

The home screen explains Scan → Review/rescan → Export/share with scrolling content and a fixed start button. Advanced capture settings are collapsed. Permission denial offers Settings. Export requires usable photos; zero-point data may still export calibrated images. Invalid tracking cannot append a new coordinate system to an existing scan.

Capture, processing, and export prevent closing the screen directly. Leaving an unexported review explains where files remain and that the live session cannot be restored from history.

UI defaults to Traditional Chinese with a persistent English option on the home screen. Documentation defaults to English. [Localization](LOCALIZATION.md) describes resource and validation conventions.

## Pose and fusion quality

Stable tracking must persist for 0.6 seconds; lost tracking or long gaps restart the wait. Raw scene depth is preferred over temporal smoothing. Live/offline paths share four-way edge, confidence, incidence, and blur weighting.

Tiles look up existing cells using corrected anchor positions, reducing duplication across world-grid boundaries; final anchor correction also applies to tiles unseen in the last frame. Measured depth takes priority over mesh, including grid merges. Full rotation matrices keep pose increments rigid.

Refined scanning defaults on. LiDAR-assisted bundle adjustment solves all frames jointly with ARKit motion priors. It is applied only after held-out tracks and a photo-alignment check confirm it; see [pose refinement](POSE_REFINEMENT.md). It adds processing time. These safeguards do not establish absolute real-world accuracy.

## History and deletion

Stopping saves `review.ply`, `review-poses.jsonl`, and `scan-summary.json` beside raw media. History reads `Documents/scans/scan_*`, including older scans. Missing previews use bounded depth reconstruction; photos remain viewable without depth. History previews cap at 120,000 points and use thumbnails. Export builds COLMAP before creating a new ZIP.

Select supports individual selection, Select all, Delete selected, and Delete all. Confirmation includes the count. Processing disables controls and dismissal; cancel changes nothing.

Deletion removes selected scan directories and matching ZIPs, including images, depth, poses, COLMAP, point clouds, floor plans, and legacy models such as `gaussians.ply` / `floorplan.usdz`. Photos-library assets, copies shared to other apps, and unselected scans are unaffected.

All paths are validated before deletion. Duplicate selections run once. Delete all uses the confirmation snapshot, excluding later scans. Partial failures report counts and reload the list; failed deletions try to restore files for retry and retain remaining data if restoration fails.

## Synchronized playback

Photos and 3D paths stack in portrait and sit side by side in wider layouts. Controls provide play/pause, previous/next, progress, full screen, and reset. Photos preserve aspect ratio; point clouds remain interactive.

The green path and orange frustum use the same corrected poses as the history cloud, with camera-local -Z forward. Filename pairing prevents missing images from shifting later associations. Missing/invalid poses do not guess positions. A path can be shown without a point cloud.

Supported playback speeds are 0.5, 1, 2, 5, 10, 15, and 30 fps, default 2. These are saved keyframes played at a chosen interval, not original-time video; relative capture time exposes the real gaps. Playback stops at the end and pauses on tab changes, full-screen transitions, or backgrounding. Changing photos updates markers/camera without rebuilding the cloud.

Following defaults to an offset behind/above the recorded camera. Transitions take at most 0.25 seconds and at most 80% of the playback interval; scrubbing and previous/next seek directly. Missing valid poses leave the view unchanged. View full path pauses and resets the camera. Playing again after manual orbit resumes following. Standalone review does not enable following.

At 10 fps or above, photo preview long edges are limited to 960 pixels; pausing restores normal preview size. Original files remain unchanged. Actual FPS depends on device load.

`ScanPhoto` retains the displayed image while decoding its replacement, applies the new image without implicit animation, and rejects cancelled callbacks. Only the first load shows a spinner. Missing/corrupt images show a placeholder and allow playback to continue. Point-cloud position and timestamp use `displayedFrame`, not the still-loading target. Playback waits for decode success/failure before advancing, preventing repeated cancellation at high FPS. Resolution changes also retain the existing image.

## LiDAR toggle

Choose LiDAR depth scanning before capture. It cannot change mid-scan; toggling creates a new AR session and clears the previous-world-map choice.

- Enabled: depth/mesh, optional RoomPlan, fusion, and LiDAR-assisted refinement.
- Disabled: no requested sceneDepth/smoothedSceneDepth/mesh, no RoomPlan or saved depth; RGB, ARKit poses, validated sparse features, and optional [image reconstruction](CAMERA_ONLY_ACCURACY.md).
- `capture-meta.json` distinguishes `lidarAvailable` and `lidarEnabled`; legacy metadata remain readable.

The toggle controls features requested by this app, not sensor power or ARKit's internal tracking implementation. A strict hardware comparison requires a non-LiDAR device.

For A/B capture, fix scene, lighting, path, camera settings, and distance. Disable refinement for the initial mode comparison, then test refinement separately. Compare coverage, thickness, double edges, sharpness, and known dimensions; point counts alone are not accuracy.

## Validation

```sh
xcodebuild -project arkit-3dgs-scanner.xcodeproj -scheme arkit-3dgs-scanner -configuration Debug \
  -sdk iphoneos -derivedDataPath /tmp/fable-build CODE_SIGNING_ALLOWED=NO build

swiftc arkit-3dgs-scanner/Capture/TrainingFrameSelector.swift -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,FrameWriter,ExportManager}.swift \
  tools/test_capture_pipeline.swift -o /tmp/test_capture_pipeline
/tmp/test_capture_pipeline

swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/History/PlaybackCameraPose.swift tools/test_playback_camera.swift \
  -o /tmp/fable-follow-camera-test
/tmp/fable-follow-camera-test
```

Regression suites cover capture success/failure/retry, closed writes, ZIP atomic replacement, stable tracking, rigid rotations, depth checks, finite coordinates, measured-depth priority, anchor corrections, history compatibility and batch deletion, image/pose pairing, playback following/timing, BA holdout rejection, photo-alignment gating, and shard consistency. Historical counts: capture accuracy 18, history eight groups, playback four groups, following five groups, timing two groups, BA 19, photo alignment eight, and shards five.

Earlier Simulator checks covered home/history, empty state, mode badge, point cloud, photo stepping, delete confirmation, and ZIP. Some later interaction checks timed out; do not infer full UI coverage from compilation. Real-device checks remain necessary for permission recovery, backgrounding, tracking loss/recovery, rapid stop/resume, floor-plan return, LiDAR/no-LiDAR modes, orientations, larger text, VoiceOver, long-session memory, heat, and frame rate.

API references: [camera authorization](https://developer.apple.com/documentation/avfoundation/avcapturedevice/authorizationstatus(for:)), [ARSession interruption](https://developer.apple.com/documentation/arkit/arsessionobserver/sessionwasinterrupted(_:)), and [smoothed depth](https://developer.apple.com/documentation/arkit/arframe/smoothedscenedepth).
