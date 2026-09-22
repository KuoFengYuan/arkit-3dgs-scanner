# Device operation: heat, memory, and motion

**English** | [繁體中文](DEVICE_NOTES.zh-TW.md)

These notes describe current safeguards and practical tradeoffs. Thermal timing, peak memory, and geometric accuracy vary by device, scene, and build. Historical timings are not device guarantees.

## Heat

AR capture, camera images, LiDAR, rendering, and offline processing share the device budget. `QualityMonitor` reports serious thermal state; `CaptureController` stops capture at critical state and preserves data. Stopping does not mean a ZIP has already been exported.

Use moderate screen brightness, avoid unnecessary charging heat, and allow cooling between long captures. Use the configured video format as a starting point and measure higher-resolution modes before enabling them. High-resolution still capture is not implemented here and would need separate memory/thermal evaluation. Separate scan segments do not automatically share coordinates; combining them requires alignment.

The app disables environment texturing. LiDAR mode **does** enable supported mesh reconstruction; camera-only mode does not. Constant-material point rendering avoids unnecessary lighting work.

## Memory

Retaining ARFrames can starve ARKit's buffer pool, but it is not the only possible crash cause. Mesh, grids, decoding, RoomPlan, SceneKit, GPU resources, and output copies also contribute.

- Copy required image/depth/confidence data into owned buffers and store poses/intrinsics as values. Do not queue ARFrames.
- At most three photo writes are pending. Failed or busy copying does not consume a shutter viewpoint.
- Live grids have capacity limits and may coarsen; offline processing streams media and has separate grid, cache, and output budgets.
- Anchor-local tiles reduce duplication when anchors are corrected, but cannot guarantee that every drifting surface maps to the same voxel.
- Raw scene depth is preferred; temporal and multi-view checks reject unsupported geometry. Repeated correlated measurements do not guarantee increasing accuracy.
- Shared image contexts and per-frame autorelease pools limit intermediate lifetime.
- Stop releases GPU geometry and saves a bounded preview before heavier work; see [large-scan memory](LARGE_SCAN_MEMORY.md).

Disk size depends on JPEG content/quality, image dimensions, saved depth, and frame count. HUD storage is an estimate. Photo-count bounds are not memory bounds, and successful synthetic tests do not establish peak iPhone RSS.

## Exposure blur and rolling shutter

A camera image is exposed over time and may read different rows at different times. Fast rotation can create geometric distortion even with a short exposure. The recorded pose is one transform, so it cannot fully describe within-frame deformation.

The quality monitor estimates motion in pixels from focal length, rotation, translation, distance, exposure, and readout assumptions. Current configuration uses a 10 px warning estimate and a 24 px **exposure-blur** blocking threshold, with separate severe-motion and measured-sharpness gates. See [capture consistency](LIDAR_QUALITY_AND_PREVIEW.md) for the separation. Estimates are risk indicators, not measured blur.

Use better light to permit shorter exposure, move/turn more slowly, and include lateral baseline without abrupt rotation. Excessively strict risk thresholds can stop ordinary walking capture without proving improved geometry. Post-fusion RGB selection only presents an actionable recapture banner for weak measured detail; motion-only and unknown evidence remain optional information.

## Camera controls and other details

The HUD offers exposure/white-balance lock plus advanced exposure compensation, shutter, ISO, white balance, and focus controls where the capture device supports them. Automatic focus remains available; export stores per-frame intrinsics rather than relying on a single locked calibration. Manual shutter/ISO choices can trade blur against brightness and noise. Locked exposure can under-/overexpose transitions between windows and dark areas.

Heavy pixel processing, matching, fusion, and geometry packing run away from UI coordination. Main-thread work still includes necessary buffer copies and scene application; changing a hot path requires timing it in the intended build mode. Debug/Release timing can differ substantially.

Camera-only mode saves colored validated sparse features and optionally runs fixed-pose image reconstruction; it is not merely an unfiltered gray raw-feature dump. White walls and insufficient baseline can yield no reliable geometry.

Files sharing is enabled for local scan access. Existing external copies are independent of app history deletion. Cloud uploads and on-device Gaussian training are not part of the current workflow.
