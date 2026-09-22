# ARKit 3DGS Scanner

**Turn iPhone scans into datasets for 3D Gaussian Splatting.**

**English** | [繁體中文](README.zh-TW.md)

Capture photos, camera poses, and point clouds with ARKit. Refine the data on your iPhone, review the scene and capture route, then export a COLMAP dataset for an external 3DGS trainer.

- **Optional LiDAR:** fuse sensor depth or capture with RGB and verified sparse features.
- **On-device data refinement:** image selection, validated camera pose refinement, and multi-view depth fusion.
- **Review before export:** inspect point clouds, replay the capture route in first person, and continue an active scan to fill gaps.
- **Visible processing:** a bilingual, dark fusion progress page with real stages, elapsed time, and a lightweight particle animation.
- **COLMAP export:** calibrated images, camera poses, and initialization points in `images/ + sparse/0`.

The app handles capture and dataset preparation. **On-device Gaussian Splatting training has been removed.** Training runs in an external tool; scanning, refinement, and preview stay on the phone.

## Workflow

```text
Scan → Refine → Review point cloud → Export COLMAP ZIP → External 3DGS training
                  └─ Continue scanning to fill gaps

Scan history → Photo / point-cloud / route preview → Refine a copy, export, or delete
```

See [fusion progress, first-person review, and export safeguards](docs/FUSION_REVIEW.md).

## Features

| Feature | What it does |
| --- | --- |
| Automatic keyframes | Selects frames using camera movement, rotation, and capture quality; stores per-frame intrinsics and poses |
| LiDAR fusion | Filters depth edges and inconsistent observations, then refines supported samples across viewpoints |
| Camera-only capture | Saves RGB and verified sparse points; optionally reconstructs additional geometry from multiple images |
| Pose refinement | LiDAR-assisted local adjustment and bounded revisit correction; changes require held-out validation |
| Metric scale | Pick point-cloud distances, calibrate against a known length, independently verify, and export scaled cameras/points |
| Image selection | Prefers sharper, nonredundant views while retaining all original photos and reliable depth |
| Synchronized playback | Photos follow their corresponding 3D camera position and direction; adjustable playback FPS |
| Scan history | Preview, refine into a separate version, export, and delete individual, selected, or all scans |
| Floor plans | Captures or estimates scene structure when supported and sufficient data is available |

## Quick start

**Requirements:** Xcode 26+, iOS 17+, and an ARKit-capable iPhone or iPad. LiDAR depth and RoomPlan require compatible hardware. The Simulator supports UI and data-flow checks, not real AR scanning.

```sh
git clone https://github.com/KuoFengYuan/arkit-3dgs-scanner.git
cd arkit-3dgs-scanner
open arkit-3dgs-scanner.xcodeproj
```

1. Select the `arkit-3dgs-scanner` scheme, your signing team, and a physical device in Xcode.
2. Build and run. Allow camera access and wait for tracking to become ready.
3. Choose LiDAR and refinement options before starting. Move around the scene so surfaces are visible from multiple positions.
4. Stop the scan, wait for processing, and inspect the point cloud. Continue the active scan if more coverage is needed.
5. Select **Export 3DGS dataset** to share the dataset ZIP. Unzip it on your computer and load it into a trainer that accepts COLMAP datasets.

The interface supports Traditional Chinese (default) and English; switch languages on the home screen. Documentation is English first with a Traditional Chinese version of every page. The repository, Xcode project, and scheme are named `arkit-3dgs-scanner`. The app identifier remains `itri.fable` to preserve existing installations and scan data.

## Capture modes

| Mode | Saved data and processing |
| --- | --- |
| LiDAR enabled | RGB, camera poses, depth and confidence; optional mesh support, RoomPlan, and LiDAR-assisted pose refinement |
| LiDAR disabled | RGB, camera poses, verified sparse features, and optional image-based reconstruction; no saved LiDAR depth |

The toggle controls depth features requested and used by this app. It is not a sensor power switch and does not guarantee that ARKit itself avoids LiDAR internally. Camera-only reconstruction depends on texture, sharpness, and parallax.

## Fusion quality and memory

Depth fusion selects up to four reference views, prioritizing separated camera positions. Samples need supporting observations; accepted depth corrections use a median along the original camera ray with a **2 cm maximum shift**. Visibility and consistency are checked again after correction. Mesh supplementation must also pass the support gate.

On one 569-frame scan, the median local surface thickness decreased from **8.94 cm to 7.01 cm**. This measures consistency at fixed local patches, including possible furniture and real layered structures. It is **not an absolute dimensional accuracy measurement** or a guarantee of artifact-free 3DGS results. See the [method, comparison, and limitations](docs/LIDAR_SURFACE_CONSENSUS.md).

Processing streams frames instead of retaining all decoded images and depth maps. The reference-depth cache is capped at eight entries / 2 MiB; the fusion grid and exported point cloud have separate memory limits. The current mobile output cap is 250,000 points. These are processing safeguards, not a guarantee against every out-of-memory condition. See [large-scan memory handling](docs/LARGE_SCAN_MEMORY.md).

Pose refinement combines guided local optimization with bounded revisit matching and a sparse rigid-correction graph. It is not COLMAP/Ceres or a complete global SfM pipeline. Failed validation keeps the existing poses. Image selection and depth fusion are separate, so a photo excluded from training can still contribute reliable depth.

Motion estimates alone no longer trigger a post-fusion recapture warning. Weak measured detail still receives a frame-specific review message; motion-only and unknown evidence remain in collapsed capture-quality information. This changes reporting, not the original photos or depth eligibility.

## History and playback

Stopped scans are saved automatically for later review, even before export.

- Replay captured photos with a synchronized 3D camera marker and route. Playback supports 0.5, 1, 2, 5, 10, 15, and 30 fps. These are saved keyframes, not a real-time video recording.
- Preview photos are oriented for viewing; original JPEG pixels and calibration remain unchanged.
- **Optimize training data** refines a copy of the scan on the phone. It prepares training data; it does not train Gaussians.
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

Additional floor-plan, world-map, reconstruction, and performance files depend on the enabled features. New scans do not generate `gaussians.ply`; existing models in older scans remain part of those scans for sharing and deletion.

**Coordinates:** COLMAP cameras and `points3D.bin` are rotated together by 180° around world X by default. PLY previews and JSONL poses retain ARKit world coordinates. Do not mix these coordinate frames without conversion. See [coordinate conventions](docs/COORDINATES.md).

The exported sparse model provides calibrated cameras and seed points, without complete SfM feature observations or tracks. Running bundle adjustment alone cannot create those missing observations. An empty point set can be exported, but an external trainer may require additional initialization.

## Development

Follow [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md). Changes go through a task branch and PR; merge only after required checks/reviews, then remove the task branch locally and remotely.

```sh
python3 tools/check_project.py
bash tools/test_localization.sh
bash tools/test_training_quality.sh
bash tools/test_metric_loop.sh
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
tools/          Dataset conversion, analysis, and regression tests
docs/           Architecture, coordinate conventions, quality, and performance
```

The former `Training/` module, msplat C++ / Metal engine, Swift bridge, and dedicated build settings have been removed. Capture and dataset preparation do not depend on that engine.

Optional Python tools:

```sh
python3 -m venv .venv
.venv/bin/pip install -r tools/requirements.txt
.venv/bin/python tools/test_math.py
.venv/bin/python tools/validate_dataset.py /path/to/scan
.venv/bin/python tools/arkit2gs.py /path/to/scan -o /path/to/dataset --format both
```

Swift regression tools cover capture writes, geometry, bounded depth caching, large scans, history export, and playback. Device builds and synthetic tests do not replace real-device checks for tracking quality, temperature, or long-session memory use.

## Documentation

- [Capture architecture](docs/CAPTURE_ARCHITECTURE.md)
- [Loop closure and metric scale](docs/LOOP_CLOSURE_AND_SCALE.md)
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
