# ARKit 3DGS Scanner

**Scan with an iPhone, then train 3D Gaussian Splatting on the phone or export a dataset.**

**English** | [繁體中文](README.zh-TW.md)

Capture photos, camera poses, and point clouds with ARKit. Refine the data on your iPhone, review the scene and capture route, then train a 3DGS model on the device or export a COLMAP dataset for an external trainer.

- **Optional LiDAR:** fuse sensor depth or capture with RGB and verified sparse features.
- **On-device data refinement:** image selection, validated camera pose refinement, and multi-view depth fusion.
- **Review before export:** inspect point clouds, replay the capture route in first person, and continue an active scan to fill gaps.
- **Visible processing:** a bilingual, dark fusion progress page with real stages, elapsed time, and a lightweight particle animation.
- **On-device 3DGS training:** an MRNF-based Metal trainer with this project's additions for accuracy (pose refinement, LiDAR depth seeds and loss, a growth ramp) and speed (exact tile spans, a one-pass SIMD reduction in the backward pass), anti-aliasing, and optional colour and capture-motion compensation, inside a fixed memory plan. It includes a live interactive preview and a saved-model viewer.
- **COLMAP export:** calibrated images, camera poses, and initialization points in `images/ + sparse/0`.

**Train 3DGS** runs the whole optimisation on the iPhone GPU, with no server. The loop renders, computes the loss, and updates the model and cameras. Training images can be 960, 1,440, or the photos' full 1,920 px. A run keeps going while you use the rest of the app, and on iOS 26 it can continue in the background. It pauses with a checkpoint when you switch apps without background time, when the device is too hot or low on battery, or when memory runs short, and resumes later from History. The COLMAP export for external trainers is unchanged. See [on-device 3DGS training](docs/ON_DEVICE_3DGS.md) for the method, memory safety, file formats, and what was verified where.

- **Experimental surface reconstruction:** bounded local RGB-D pose refinement and sparse TSDF surface points, with complete voxel-fusion fallback. TSDF pages full-precision blocks through one bounded scratch file with batched writes. Capped voxel export uses stable spatial-order sampling. Fusion also overlaps a single JPEG prefetch and reuses exact depth-validity checks without changing sampling or thresholds. See [behavior, benchmarks and limits](docs/SURFACE_RECONSTRUCTION.md).

## Workflow

```text
Scan → Refine → Review point cloud ─┬─ Train 3DGS on the iPhone → View / share the model
                  │                 └─ Export COLMAP ZIP → External 3DGS training
                  └─ Continue scanning to fill gaps

Scan history → Photo / point-cloud / route preview → Train 3DGS, refine a copy, export, or delete
```

See [fusion progress, first-person review, and export safeguards](docs/FUSION_REVIEW.md).

## Features

| Feature | What it does |
| --- | --- |
| Automatic keyframes | Selects frames using camera movement, rotation, and capture quality; stores per-frame intrinsics and poses |
| LiDAR fusion | Filters depth edges and inconsistent observations, then refines supported samples across viewpoints |
| Camera-only capture | Saves RGB and verified sparse points; optionally reconstructs additional geometry from multiple images |
| Pose refinement | Joint LiDAR-assisted adjustment with ARKit motion priors and pose-guided revisit tracks; changes require held-out tracks and a photo-alignment check |
| Metric scale | Pick point-cloud distances, calibrate against a known length, independently verify, and export scaled cameras/points |
| Image selection | Prefers sharper, nonredundant views while retaining all original photos and reliable depth |
| Synchronized playback | Photos follow their corresponding 3D camera position and direction; adjustable playback FPS |
| On-device 3DGS | Trains, previews, pauses and resumes a Gaussian model per scan at 960–1,920 px; finish early at any time, and enhance a saved model later; the saved model opens from History after restarts |
| Scan history | Preview, refine into a separate version, export, and delete individual, selected, or all scans |
| Floor plans | Captures or estimates scene structure when supported and sufficient data is available |

## Quick start

**Requirements:** Xcode 26+, iOS 17+, and an ARKit-capable iPhone or iPad. LiDAR depth and RoomPlan require compatible hardware. The Simulator supports UI and data-flow checks, not real AR scanning.

```sh
git clone https://github.com/KuoFengYuan/arkit-3dgs-scanner.git
cd arkit-3dgs-scanner
open arkit-3dgs-scanner.xcodeproj
```

1. Select the `arkit-3dgs-scanner` scheme, your signing team, and a physical device in Xcode. Run uses optimized Release; choose `arkit-3dgs-scanner-Debug` only for source-level debugging. See [fusion speed and overlapping surfaces](docs/SCAN_FUSION_DIAGNOSTICS.md).
2. Build and run. Allow camera access and wait for tracking to become ready.
3. Choose LiDAR and refinement options before starting. Move around the scene so surfaces are visible from multiple positions.
4. Stop the scan, wait for processing, and inspect the point cloud. Continue the active scan if more coverage is needed.
5. Select **Train 3DGS** to build a model on the phone, or **Export 3DGS dataset** to share the dataset ZIP. Unzip the dataset on your computer and load it into a trainer that accepts COLMAP datasets.

The interface supports Traditional Chinese (default) and English; switch languages on the home screen. Documentation is English first with a Traditional Chinese version of every page. The repository, Xcode project, scheme, and app identifier are all `arkit-3dgs-scanner`. Installations built under an earlier identifier appear as a separate app: re-export any scans you want to keep from the old app first.

## Train 3DGS on the iPhone

The app trains a 3D Gaussian Splatting model of a saved scan on the phone's GPU. Nothing is uploaded.

**Requirements:**
- An iPhone or iPad with an A14 chip or newer (Metal Apple GPU family 7).
- LiDAR scans train best, because their depth fills surfaces the fused point cloud missed. Camera-only scans train from their sparse points.
- Training keeps running while you use the rest of the app. Switching to another app pauses it, unless iOS grants background time (see [keep training in the background](#keep-training-in-the-background)). Train on power when you can.

### Start a run

1. Finish a scan, or open **Scan history** and pick a scan.
2. Tap the **Train 3DGS** card. It is on the review screen right after a capture and in the scan's detail.
3. Pick a quality:

   | Quality | Iterations | Gaussian cap | For |
   | --- | --- | --- | --- |
   | Quick preview | 4,000 | 300,000 | A fast first look |
   | Standard (recommended) | 10,000 | 600,000 | Most scans |
   | High quality | 20,000 | 1,000,000 | The most detail; takes the longest and uses more battery |

4. Pick a **training resolution**, the long edge of the training images:

   | Resolution | Long edge | Cost |
   | --- | --- | --- |
   | Low (default) | 960 px | Fastest, least memory |
   | Medium | 1,440 px | About 1.7× the time |
   | High (original) | 1,920 px, the photos' own size | About 2.6× the time and the most memory |

   After a run finishes on this phone, each quality shows how long it took there at the chosen resolution. The memory check below the choices lowers the Gaussian cap if the phone has less memory free.
5. Optional: open **Advanced settings** for camera pose refinement, PPISP colour correction, and anti-aliasing. The defaults suit most scans. PPISP turns on by itself only when the capture's exposure changed.
6. Tap **Start training**.

### While it trains

- The model appears live and sharpens as it trains. Drag to orbit, use two fingers to pan, pinch to zoom, and double-tap to reset the view.
- The card shows the progress, the current stage, and the time left once the speed settles. The line below it shows the iteration, Gaussian count, loss, PSNR, and elapsed time.
- **Pause**, **Save progress**, or **Stop**. When stopping, keep the progress to resume later or delete this run.
- **Finish and save model** ends the run whenever the model looks good enough. The current state becomes the saved model, as if the run had completed, and you can keep training it later with **Enhance model**.
- You can leave the training screen. Training continues while you browse History or other scans, and the home screen's **Scan history** card shows its progress. Open the scan's **Train 3DGS** card to watch it again.
- The run pauses by itself, with its progress saved, when:
  - you switch to another app, unless it [continues in the background](#keep-training-in-the-background);
  - you start a new capture (it continues when the capture closes);
  - the phone is too hot;
  - the battery drops below 15% off power;
  - memory runs short.

  It continues when the app returns or the phone cools down. Otherwise, resume it later from the card.

### Keep training in the background

On iOS 26 or later, a run can keep training after you switch to another app. iOS shows its progress in a system notice, where it can also be stopped. This needs:

- a device where iOS offers background GPU time; and
- the **Background GPU Access** capability, which only paid Apple Developer teams can add:
  1. In Xcode, select the `arkit-3dgs-scanner` target, then **Signing & Capabilities**.
  2. Click **+ Capability** and add **Background GPU Access**.
  3. Build and install again.

The project already declares the task identifiers in `Config/Info.plist`. Without either requirement, or when iOS ends the background time, the run pauses with its progress saved and continues when you return. The training screen says which of the two applies.

### After it finishes

- The model stays with the scan, also after the app restarts. In **Scan history**, cards mark scans that have a model, a run in progress, or a run that can resume. Tap **View 3DGS model** to orbit the model.
- **Enhance model** loads the saved model and keeps training it: pick 4,000, 10,000, or 20,000 more iterations and a training resolution, for example a Low run first and then an enhancement at High (original). The camera refinements and colour model carry over. The current model stays until the enhancement completes; stopping it with *delete* leaves the saved model as it was.
- **Share 3DGS model** sends `scan_…-3dgs.zip`. It contains `gaussians.sog`, metadata, the refined camera poses, and `ppisp.json` when PPISP was used. SOG is a compressed 3DGS format, about 1/12 the size of a PLY (12 MB instead of 149 MB for 600,000 Gaussians) at about 0.2 dB lower PSNR. SuperSplat, PlayCanvas, and LichtFeld Studio open it directly; PlayCanvas `splat-transform` converts it to PLY. Models saved as PLY before SOG keep their PLY.
- In other 3DGS viewers, the model uses the COLMAP frame, so Y-up viewers show it upside down: rotate it 180° about X. Those viewers ignore `ppisp.json`.
- From the options menu at the top right:
  - **Retrain** keeps the current model until the new one completes.
  - **Delete 3DGS model** removes only the training results; the scan's photos, depth, and poses stay.

The model is based on MRNF, LichtFeld Studio's densification strategy, with this project's own methods on top. The trainer refines the camera poses, seeds empty surfaces from LiDAR depth, fills remaining holes while training, and uses the LiDAR depth as a geometry loss, so models hold their shape when orbiting away from the capture path. A faster backward pass pays for about 1.4× the iterations: on three replayed scans, held-out PSNR rose by 0.7–0.9 dB, and a Standard run took 10% less time on the Mac. See [on-device 3DGS training](docs/ON_DEVICE_3DGS.md) for the method, measured results, memory safety, and file formats, and the [training architecture](docs/ON_DEVICE_3DGS_ARCHITECTURE.md) for how the code is organised. Training speed, memory use, and heat on an iPhone have not been measured yet. Mac and Simulator results are not a substitute.

## Interface and controls

The interface is dark and 3D-first. The camera feed or point cloud fills the screen, and controls float above it: one prominent action per screen, with secondary controls shown only when relevant.
- **Home and history.** The home screen introduces the app and has a floating **Start scanning** button. **Scan history** opens from a card as a grid of covers, where **Select** enables multi-select deletion.
- **Capture HUD.**
  - One status pill and one prioritized guidance slot.
  - A tool rail that appears only while scanning.
  - A shutter whose ring shows LiDAR view coverage, the share of surfaces seen over at least 30°. The heat map colours the same angle span per surface ([view coverage](docs/LIDAR_QUALITY_AND_PREVIEW.md#view-coverage-heat-map)).
  - A single **Scan settings** button that also shows the current mode. Its scrollable sections cover capture mode, quality, camera, and coordinate system.
- **Review and history.** A floating panel holds the metrics and the scan's actions as matching cards: **Train 3DGS**, **Export 3DGS dataset** (then **Share scan**), and, in history, **Scan quality information**. Scan controls follow as secondary buttons. **More actions** in history holds scene-scale validation, optimization, and deletion. Sharing uses the system share sheet with the file itself, so apps such as LINE or Teams receive the ZIP.

Surface reconstruction explicitly includes pose refinement; disable reconstruction first to configure refinement independently. Deletion still requires confirmation and removes the complete selected scan. Touch targets are at least 44 points with spoken labels, and all controls are available in English and Traditional Chinese. See [interface design](docs/INTERFACE_DESIGN.md) for the design system, screen states, responsive layouts, and Simulator preview arguments.

## Capture modes

| Mode | Saved data and processing |
| --- | --- |
| LiDAR enabled | RGB, camera poses, depth and confidence; optional mesh support, RoomPlan, and LiDAR-assisted pose refinement |
| LiDAR disabled | RGB, camera poses, verified sparse features, and optional image-based reconstruction; no saved LiDAR depth |

The toggle controls depth features requested and used by this app. It is not a sensor power switch and does not guarantee that ARKit itself avoids LiDAR internally. Camera-only reconstruction depends on texture, sharpness, and parallax. When a camera-only scan stops, two steps run. First, image-only feature tracks and a bundle adjustment, with ARKit's frame-to-frame motion as a prior, refine the camera poses; held-out tracks decide whether the result applies. Then PatchMatch multi-view stereo estimates a depth map for up to 48 views and keeps only the depths that neighbouring views confirm. In desktop replays of two scans, this produced about 18,000–19,000 points and covered 14–29% of the LiDAR surface within 5 cm, against under 8% for the earlier image reconstruction. About 4% of the points lay more than 10 cm from the surface. See [camera-only reconstruction](docs/CAMERA_ONLY_ACCURACY.md).

## Fusion quality and memory

Depth fusion selects up to four reference views, prioritizing separated camera positions. Samples need supporting observations; accepted depth corrections use a median along the original camera ray with a **2 cm maximum shift**. Visibility and consistency are checked again after correction. Mesh supplementation must also pass the support gate.

On one 569-frame scan, the median local surface thickness decreased from **8.94 cm to 7.01 cm**. This measures consistency at fixed local patches, including possible furniture and real layered structures. It is **not an absolute dimensional accuracy measurement** or a guarantee of artifact-free 3DGS results. See the [method, comparison, and limitations](docs/LIDAR_SURFACE_CONSENSUS.md).

Depth beyond 3 m uses a separate 4 cm grid to keep noisy far data from coarsening near surfaces. **Experimental, disabled by default:** final-surface coverage checks preserve far fill at gaps/boundaries and protect local regions during visibility cleanup. Real replays recovered coverage but increased local thickness, so the default fusion behavior is retained. This is a completeness/ghost-suppression tradeoff, not a demonstrated dimensional-accuracy improvement. See [range priority](docs/LIDAR_SURFACE_CONSENSUS.md) and [coverage validation and replay measurements](docs/SCAN_FUSION_DIAGNOSTICS.md).

Processing streams frames instead of retaining all decoded images and depth maps. The reference-depth cache is capped at eight entries / 2 MiB; the fusion grid and exported point cloud have separate memory limits. The current mobile output cap is 250,000 points. These are processing safeguards, not a guarantee against every out-of-memory condition. See [large-scan memory handling](docs/LARGE_SCAN_MEMORY.md).

Pose refinement combines guided feature matching, a joint bundle adjustment that keeps ARKit's accurate frame-to-frame motion, and revisit tracks: pose-guided, plane-warped matches between passes that join the same solve (see [revisit refinement](docs/LOOP_CLOSURE_AND_SCALE.md#revisit-refinement)). It is not COLMAP/Ceres or a complete global SfM pipeline. Local surface pose refinement now uses a route-wide pilot before a full solve; rejected pilots preserve the accepted poses while TSDF still runs. Photo checks also measure lost projections. A photo-alignment check compares image texture between overlapping frames and applies a stage only if it improves wide-baseline alignment without harming adjacent frames. In desktop replays of two scans, the previous refinement failed this check; the new one raised median wide-baseline NCC by about 0.02, and the local surface stage was rejected. Failed validation keeps the existing poses. See [pose refinement](docs/POSE_REFINEMENT.md). Image selection and depth fusion are separate, so a photo excluded from training can still contribute reliable depth.

Motion estimates alone no longer trigger a post-fusion recapture warning. Weak measured detail still receives a frame-specific review message; motion-only and unknown evidence remain in collapsed capture-quality information. This changes reporting, not the original photos or depth eligibility.

Two iPhone 17 Pro completion crashes were traced to a failed stderr log write after fusion reached 100%; this now uses system logging. Processing also clears capture caches, stops the covered camera renderer, checks memory pressure within insertion/coarsening, and reserves 192 MiB plus per-frame workspace. Raw captures remain available on fallback. See [device evidence and memory controls](docs/LARGE_SCAN_MEMORY.md).

## History and playback

Stopped scans are saved automatically for later review, even before export.

- Replay captured photos with a synchronized 3D camera marker and route. Playback supports 0.5, 1, 2, 5, 10, 15, and 30 fps. These are saved keyframes, not a real-time video recording.
- Preview photos are oriented for viewing; original JPEG pixels and calibration remain unchanged.
- **Optimize training data** refines a copy of the scan on the phone. It prepares training data; it does not train Gaussians.
- **Train 3DGS** (or **View 3DGS model** / **Resume 3DGS training**) opens the scan's on-device training. Cards show training, a saved model, or a run that can resume; interrupted runs continue from their last checkpoint.
- **Scene scale and validation** measures point-cloud distances, accepts a known reference, and exports a separate metric COLMAP ZIP. Camera positions and points scale together; raw depth is omitted from that ZIP. Reference checks do not certify whole-scene accuracy. See [loop closure and metric scale](docs/LOOP_CLOSURE_AND_SCALE.md).
- Deletion removes the selected scan's photos, depth, poses, point clouds, models, and matching standard/metric ZIPs. Unselected scans and copies shared to other apps are unaffected.

An active scan can be resumed from its review screen. Opening a historical scan does not restore the original live AR session.

## Export format

Both live and history export generate the COLMAP model before packaging the ZIP. **Use `sparse/0/images.bin` as the selected training-image list**; `images/` retains every original photo.

```text
scan_…/
├── images/                    # Original sensor-oriented JPEGs
├── depth/                     # LiDAR depth and confidence, when captured
├── sparse/0/
│   ├── cameras.bin            # Per-frame calibration
│   ├── images.bin             # Selected images and world-to-camera poses
│   └── points3D.bin           # Initialization point cloud
├── points.ply                 # Point cloud in ARKit world coordinates
├── poses.jsonl                # Original capture poses
├── poses_refined.jsonl        # Selected, processed poses
├── capture-meta.json          # Device and capture mode
├── review.ply                 # Saved preview point cloud
├── review-poses.jsonl          # Preview and playback poses
├── scan-summary.json          # Frame and point counts
├── training-selection.json    # Image selection and recapture information
├── pose-refinement.json       # Pose validation report, when refinement runs
└── refusion-progress.json     # Fusion timing and resource report, when fusion runs
```

New captures use `capture-meta.json`. Legacy `meta.json` files remain readable and are renamed when exporting; if both names exist, the current file wins and the legacy content is retained under a separate capture-specific filename. This avoids exposing `meta.json` to trainer format detection.

Additional floor-plan, world-map, reconstruction, and performance files depend on the enabled features. On-device training writes to `gaussian-training/` inside the scan (checkpoint, state, and `model/gaussians.sog` with its sidecars; older models keep `gaussians.ply`). The dataset ZIP leaves that folder out; the model has its own ZIP. Existing models in older scans remain part of those scans for sharing and deletion.

**Coordinates:** COLMAP cameras and `points3D.bin` are rotated together by 180° around world X by default. PLY previews and JSONL poses retain ARKit world coordinates. Do not mix these coordinate frames without conversion. See [coordinate conventions](docs/COORDINATES.md).

The exported sparse model provides calibrated cameras and seed points, without complete SfM feature observations or tracks. Running bundle adjustment alone cannot create those missing observations. An empty point set can be exported, but an external trainer may require additional initialization.

## Development

Follow [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md). Changes go through a task branch and PR; merge only after required checks/reviews, then remove the task branch locally and remotely.

```sh
python3 tools/check_project.py
bash tools/test_localization.sh
bash tools/test_training_quality.sh
bash tools/test_gaussian_training.sh
bash tools/test_metric_loop.sh
bash tools/test_fusion_memory.sh
```

```sh
xcodebuild -project arkit-3dgs-scanner.xcodeproj -scheme arkit-3dgs-scanner \
  -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project arkit-3dgs-scanner.xcodeproj -scheme arkit-3dgs-scanner \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

```text
arkit-3dgs-scanner/Capture/    AR session, keyframes, fusion, pose refinement, image selection, export
arkit-3dgs-scanner/History/    Scan storage, playback, refinement, and deletion
arkit-3dgs-scanner/Training/   On-device 3DGS: Metal kernels, trainer, memory plan, checkpoints, export, viewer and UI
tools/          Dataset conversion, analysis, and regression tests
docs/           Architecture, coordinate conventions, quality, and performance
```

`Training/` is a new implementation in Swift and Metal. The earlier msplat C++ engine, its Swift bridge, and its build settings are not used. Capture and dataset preparation do not depend on the trainer.

Optional Python tools:

```sh
python3 -m venv .venv
.venv/bin/pip install -r tools/requirements.txt
.venv/bin/python tools/test_math.py
.venv/bin/python tools/validate_dataset.py /path/to/scan
.venv/bin/python tools/arkit2gs.py /path/to/scan -o /path/to/dataset --format both
```

Swift regression tools cover capture writes, geometry, bounded depth caching, large scans, history export, and playback. Device builds and synthetic tests do not replace real-device checks for tracking quality, temperature, or long-session memory use.

## License

Copyright 2026 Kuo Feng-Yuan ([KuoFengYuan](https://github.com/KuoFengYuan)). Licensed under the [Apache License 2.0](LICENSE).

**This is a personal research project.** It is not a product of, and is not endorsed by, any employer or organisation, and it does not represent their views. It is provided as is, without warranty.

- **Commercial use is allowed**, including the on-device 3DGS trainer, and so are modification and redistribution.
- **Credit the author.** Any copy or derivative work must keep [LICENSE](LICENSE) and [NOTICE](NOTICE) and credit Kuo Feng-Yuan (KuoFengYuan) as the original author.
- The 3DGS trainer is an independent Swift and Metal implementation. It contains no code from the original 3D Gaussian Splatting (Inria/MPII) or Mip-Splatting releases, which allow only non-commercial use, and no code from LichtFeld Studio (GPL-3.0). [NOTICE](NOTICE) lists the papers and projects it follows.
- Third-party patents may still cover some of the methods. This is not legal advice; check before commercial use.

## Documentation

- [Capture architecture](docs/CAPTURE_ARCHITECTURE.md)
- [Interface design](docs/INTERFACE_DESIGN.md)
- [Pose refinement and photo-alignment validation](docs/POSE_REFINEMENT.md)
- [Loop closure and metric scale](docs/LOOP_CLOSURE_AND_SCALE.md)
- [On-device 3DGS training](docs/ON_DEVICE_3DGS.md)
- [On-device 3DGS training architecture](docs/ON_DEVICE_3DGS_ARCHITECTURE.md)
- [On-device dataset refinement](docs/ON_DEVICE_TRAINING_QUALITY.md)
- [LiDAR surface consistency](docs/LIDAR_SURFACE_CONSENSUS.md)
- [Camera-only reconstruction](docs/CAMERA_ONLY_ACCURACY.md)
- [History export](docs/HISTORY_TRAINING_EXPORT.md)
- [External training notes](docs/TRAINING.md)
- [Capture throughput](docs/CAPTURE_THROUGHPUT.md)
- [Live preview and quality gates](docs/LIDAR_QUALITY_AND_PREVIEW.md)
- [Large-scan memory](docs/LARGE_SCAN_MEMORY.md)
- [Coordinate conventions](docs/COORDINATES.md)
- [Device operation](docs/DEVICE_NOTES.md)
- [Language support](docs/LOCALIZATION.md)

Every guide above has a Traditional Chinese counterpart linked at the top. See the [contribution workflow](CONTRIBUTING.md) for `Feature/`, `Bugfix/`, and `Enhance/` branches and the PR → merge → branch cleanup process. For reproducible issues, include the device, capture mode, build configuration, processing report, and a minimal scan sample when available.
