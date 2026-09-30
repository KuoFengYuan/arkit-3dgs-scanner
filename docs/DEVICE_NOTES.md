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

### Shutter, ISO and detail on a large scan

F21171 is a room and a bathroom: 1,234 photos in 169 s, taken with the exposure and white-balance lock off. Auto exposure therefore ran under the 1/60 s cap:
- 732 of the 858 training photos used 1/60 s;
- ISO ran from 54 to 5,011 (338 training photos above 400, 98 above 1,600);
- PPISP compensates the brightness differences between photos during training.

To separate blur from noise, 20,418 pairs of photos of the same surface were compared with the sharpness measure of the training experiments (see [large scenes](ON_DEVICE_3DGS.md#large-scenes-with-blurred-photos)). A robust regression of each pair's detail difference gives:

| Term | Detail lost (ln of gradient energy) | 95% interval |
| --- | --- | --- |
| 1 px of exposure blur (estimate at 1,920 px) | 0.044 | 0.032–0.054 |
| 1 ISO stop | 0.26 | 0.14–0.38 |
| 1 ISO stop at or below ISO 400 (no denoising by the app) | 0.26 | 0.14–0.42 |
| 1 ISO stop above ISO 400 (the app denoises) | 0.28 | −0.08–0.52 |

- **A shorter shutter cap roughly breaks even on this scan.**
  - At the median exposure blur (14.9 px), 1/120 s instead of 1/60 s would recover about 0.32.
  - The doubled ISO would cost about 0.26, a net gain of only 0.06.
  - It would help only fast turns, or bright areas with ISO to spare. The cap stays at 1/60 s.
- **Turning more slowly is the lever with no cost.** The blur term scales with angular speed (median 23°/s here). Halving it recovers the full 0.32 without raising ISO.
- **The app's denoising above ISO 400 adds no measurable loss** at the 640 px scale of this measure: the ISO cost is the same below ISO 400, where no denoising runs. Finer detail at 1,920 px was not measured.
- **The exposure lock does not reduce blur.** It keeps brightness constant between photos. With a 6.5 EV difference between the room and the bathroom, it would over- or underexpose one of them.
- **The motion estimate agrees only loosely with measured sharpness** (rank correlation 0.28); see [dataset refinement](ON_DEVICE_TRAINING_QUALITY.md#large-scenes-motion-estimate-and-measured-sharpness).

Not yet tried; both need device captures:
- taking the steadiest frame within the shutter interval (ARKit delivers 60 frames per second, and the photo is currently the first frame that passes the gates);
- a shutter cap that follows the ISO in use.

## Camera controls and other details

The HUD offers exposure/white-balance lock plus advanced exposure compensation, shutter, ISO, white balance, and focus controls where the capture device supports them. Automatic focus remains available; export stores per-frame intrinsics rather than relying on a single locked calibration. Manual shutter/ISO choices can trade blur against brightness and noise. Locked exposure can under-/overexpose transitions between windows and dark areas.

Heavy pixel processing, matching, fusion, and geometry packing run away from UI coordination. Main-thread work still includes necessary buffer copies and scene application; changing a hot path requires timing it in the intended build mode. Debug/Release timing can differ substantially.

Camera-only mode saves colored validated sparse features and optionally runs fixed-pose image reconstruction; it is not merely an unfiltered gray raw-feature dump. White walls and insufficient baseline can yield no reliable geometry.

Files sharing is enabled for local scan access. Existing external copies are independent of app history deletion. Nothing is uploaded: refinement and 3DGS training run on the device ([on-device 3DGS training](ON_DEVICE_3DGS.md)).

The repository, Xcode project, scheme, and app identifier are all `arkit-3dgs-scanner`. An installation built under an earlier identifier appears as a separate app; export any scans you want to keep from it first.
