# ARKit 3DGS Scanner

**Scan with an iPhone, then train 3D Gaussian Splatting on the phone or export a dataset.**

**English** | [繁體中文](README.zh-TW.md)

**A personal research project for noncommercial use. Commercial use is not permitted under the [PolyForm Noncommercial License 1.0.0](LICENSE).**

## Training highlights

> [!IMPORTANT]
> **Optimised model training: 1.39× faster on iPhone 17 Pro and up to 1.45× faster on Mac (M1 Pro)** in the F21171 benchmark below. The three-scan quality comparison also shows **+1.65 to +2.48 dB PSNR** over this project's initial MRNF-based trainer.

### Training speed: before and after

F21171, fixed **10,000 iterations**, 960 px, PPISP on, 600,000 Gaussian cap, 715 training photos and the same 143 held-out photos. The training method and settings are the same before and after this speed optimisation.

| Device | Before | After | Speed-up |
| --- | --- | --- | --- |
| Mac, M1 Pro (two runs each) | 374.2 / 386.7 s | **261.7 / 277.6 s** | **1.37–1.45×** |
| iPhone 17 Pro (both runs at `serious` thermal state) | 769.4 s | **553.1 s** | **1.39×** |

The Mac speed-up uses the mean of the two before runs; Xcode builds ran during the second after run. On the phone, the improvement is 1.19× against a separate before run that started cooler (658.0 s). The phone used an iOS 27.0 Release benchmark build that calls the trainer directly, without live previews. Other iPhones, High quality, full-resolution training and the normal training screen were not measured. See the [complete speed benchmark](docs/ON_DEVICE_3DGS.md#faster-training-steps-on-a-large-scan).

### PSNR: accumulated quality improvements

Scans captured with iPhone 17 Pro and evaluated on the Mac; **held-out photos, with test-time pose alignment; higher is better**. The MRNF base is this project's initial Swift/Metal implementation. The current results include accuracy improvements and longer presets, which use some of the saved time for more iterations.

| Scan | Initial MRNF base | With accuracy improvements, before speed work | Current trainer | Gain over initial base |
| --- | --- | --- | --- | --- |
| FBDA13 | 27.56 dB | 29.13 dB | **30.04 dB** | **+2.48 dB** |
| 7F2187 | 24.25 dB | 25.97 dB | **26.66 dB** | **+2.41 dB** |
| 9F8040 | 27.45 dB | 28.31 dB | **29.10 dB** | **+1.65 dB** |

These gains combine the training changes over time; they are not the effect of the latest speed optimisation alone. See [the method and comparison](docs/ON_DEVICE_3DGS.md#method) and [speed and longer presets](docs/ON_DEVICE_3DGS.md#speed-and-longer-presets).

### PSNR: latest speed optimisation at the same workload

The fixed 10,000-iteration F21171 benchmark above checks quality separately from speed. Mac values are means of two runs per version; phone values are one run per version at the same thermal state.

| Device / metric | Before | After | Change |
| --- | --- | --- | --- |
| Mac: aligned held-out PSNR | 23.861 dB | **23.859 dB** | −0.002 dB |
| Mac: colour-aligned PSNR at 1,920 px | 25.329 dB | **25.354 dB** | +0.025 dB |
| iPhone 17 Pro: aligned held-out PSNR | 23.946 dB | **23.907 dB** | −0.039 dB |

PSNR differences are within the baseline's measured rerun spread of up to 0.10 dB on the Mac. Colour alignment removes overall brightness and colour differences before scoring. The Mac's empty-pixel share rose by 0.4 percentage points on average; with two runs each, that difference is unresolved. [Full quality results and measurement protocol](docs/ON_DEVICE_3DGS.md#faster-training-steps-on-a-large-scan).

<a href="docs/media/demo.mp4"><img src="docs/media/demo.gif" width="320" alt="One scan from capture to a trained 3DGS model: scanning, fusion, training, and the finished model"></a>

*A 20-second loop at 8× speed. [Watch the 1-minute video](docs/media/demo.mp4) (2.7× speed): scan a desk, refine the data, and train a 3DGS model on the iPhone.*

This project explores capturing and reconstructing 3D scenes on an iPhone. Capture photos, camera poses, and point clouds with ARKit, refine them on the phone, then train a 3DGS model on the iPhone GPU or export a COLMAP dataset for a desktop trainer. Capture, refinement, and on-device training run locally; the app does not upload scans.

## Features

- **Capture with or without LiDAR.** Keyframes are chosen from movement and image quality. LiDAR depth is fused across views; camera-only scans keep verified sparse points and can add image-based depth. The app asks you to revisit covered ground in large spaces, to correct drift. See [capture](docs/CAPTURE_ARCHITECTURE.md) and [camera-only reconstruction](docs/CAMERA_ONLY_ACCURACY.md).
- **Refine on the phone.** Sharp-photo selection, camera pose refinement that applies only when a photo-alignment check improves, and multi-view depth fusion. See [pose refinement](docs/POSE_REFINEMENT.md) and [LiDAR surface consistency](docs/LIDAR_SURFACE_CONSENSUS.md).
- **Review before you train.** Inspect the point cloud, replay the capture route, continue the scan to fill gaps, and measure or calibrate metric scale. See [fusion review](docs/FUSION_REVIEW.md) and [metric scale](docs/LOOP_CLOSURE_AND_SCALE.md).
- **Train 3DGS on the iPhone.** A Metal trainer based on MRNF, with pose refinement, LiDAR depth seeds and loss, a live preview you can orbit, pause and resume, and a compact SOG model to share. See [on-device 3DGS training](docs/ON_DEVICE_3DGS.md).
- **Export a COLMAP dataset.** Original photos, `sparse/0`, depth, and poses in one ZIP. See [export](docs/HISTORY_TRAINING_EXPORT.md) and [external training](docs/TRAINING.md).
- **Scan history.** Every stopped scan is saved. You can preview, train, refine a copy, export, or delete it.
- **Traditional Chinese (default) and English**, switchable on the home screen.

```text
Scan → Refine → Review point cloud ─┬─ Train 3DGS on the iPhone → View / share the model
                  │                 └─ Export COLMAP ZIP → External 3DGS training
                  └─ Continue scanning to fill gaps
```

## Quick start

**Requirements:** Xcode 26+ and an iPhone or iPad with iOS 17+. On-device training needs an A14 chip or newer. LiDAR depth needs a LiDAR device. The Simulator can check the UI, not real AR scanning.

```sh
git clone https://github.com/KuoFengYuan/arkit-3dgs-scanner.git
open arkit-3dgs-scanner/arkit-3dgs-scanner.xcodeproj
```

1. In Xcode, select the `arkit-3dgs-scanner` scheme, your signing team, and a physical device, then Run.
2. Tap **Start scanning** and move around the scene so each surface is seen from several positions.
3. Stop, wait for processing, and check the point cloud. Continue scanning if something is missing.
4. Tap **Train 3DGS** to build a model on the phone, or **Export 3DGS dataset** to share a ZIP for a desktop trainer.

## Train 3DGS on the iPhone

| Quality | Iterations | Gaussian cap |
| --- | --- | --- |
| Quick preview | 4,000 | 300,000 |
| Standard (recommended) | 10,000 | 600,000 |
| High quality | 20,000 | 1,000,000 |

- **Resolution:** training images at 960 (default), 1,440, or the photos' full 1,920 px.
- **Iterations:** scans with many photos get more iterations. You can adjust the count before starting.
- **While it trains:** you can keep using the app. The run saves progress and pauses when the phone is too hot, the battery is low, memory runs short, or you switch apps. On iOS 26 it can continue in the background with the Background GPU Access capability.
- **Finish early** at any time, then **Enhance model** later to keep training it.
- **Share:** a `scan_…-3dgs.zip` with `gaussians.sog`, which SuperSplat, PlayCanvas, and LichtFeld Studio open directly.

Training speed, memory use and thermal state have been measured on iPhone 17 Pro in the benchmark above; other devices and the training screen with live previews still need measurement. Mac and Simulator results do not establish iPhone performance. See [on-device 3DGS training](docs/ON_DEVICE_3DGS.md) for usage, the method, measured results, and file formats.

## Development

Follow [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md): task branches (`Feature/`, `Bugfix/`, `Enhance/`), a PR to `main`, and branch cleanup after the merge. The contribution guide lists the checks, the code layout, and the optional Python tools.

The asset catalog includes a 1024 × 1024 app icon for archived iOS builds and TestFlight distribution.

```sh
python3 tools/check_project.py
bash tools/test_localization.sh
```

## Copyright and license

Copyright © 2026 Kuo Feng-Yuan ([KuoFengYuan](https://github.com/KuoFengYuan)). Licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE); all rights not granted by that licence are reserved.

**This is a personal research project.** It is not a product of, and is not endorsed by, any employer or organisation, and it does not represent their views. It is provided as is, without warranty.

- **Noncommercial use only under this licence**, including the on-device 3DGS trainer. Use, modification and redistribution are permitted for the purposes defined in [LICENSE](LICENSE), including noncommercial research and personal study. Commercial use is outside this grant.
- **Credit the author.** Redistribution must provide the licence terms or their URL and the `Required Notice:` attribution in [NOTICE](NOTICE). Keeping [LICENSE](LICENSE) and [NOTICE](NOTICE) with copies and derivative works supplies both.
- **What the copyright covers:** the source code, the documentation and the demo recording in `docs/media`, all the author's own work. Every source file starts with an `SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0` header.
- **App icon:** made with an AI image generator at the author's direction. Copyright may not protect such images in every jurisdiction; to the extent the author holds rights in it, it is licensed on the same terms.
- The 3DGS trainer is an independent Swift and Metal implementation. It contains no code from the original 3D Gaussian Splatting (Inria/MPII) or Mip-Splatting releases, which allow only non-commercial use, and no code from LichtFeld Studio (GPL-3.0). [NOTICE](NOTICE) lists the papers and projects it follows.
- **File formats:** the COLMAP export and the SOG model file follow the formats as COLMAP and PlayCanvas document them. No code from either project is included; the readers and writers are this project's own.
- **Third-party software:** the app uses only Apple's system frameworks. The Python tools need packages installed separately (`tools/requirements.txt`), each under its own licence; none is included in this repository.
- **Trademarks:** Apple, iPhone, ARKit and Metal are trademarks of Apple Inc. Other product and project names belong to their owners and are used only to describe compatibility; no endorsement is implied.
- Third-party patents may still cover some of the methods. This licence does not grant rights to third-party patents.

**Earlier releases:** material published under Apache 2.0 through commit `d5d8e31` keeps its original permissions, including commercial use. This change does not revoke those grants. See [licensing scope and history](docs/LICENSING.md) and the [historical Apache 2.0 text](licenses/Apache-2.0.txt).

The sources were compared with the reference implementations; see [provenance](docs/ON_DEVICE_3DGS.md#provenance-and-licences).

## Documentation

| Topic | Guides |
| --- | --- |
| Capture | [Capture architecture](docs/CAPTURE_ARCHITECTURE.md) · [Interface design](docs/INTERFACE_DESIGN.md) · [Live preview and quality gates](docs/LIDAR_QUALITY_AND_PREVIEW.md) · [Capture throughput](docs/CAPTURE_THROUGHPUT.md) · [Device operation](docs/DEVICE_NOTES.md) |
| Processing | [Fusion review](docs/FUSION_REVIEW.md) · [Pose refinement](docs/POSE_REFINEMENT.md) · [Loop closure and metric scale](docs/LOOP_CLOSURE_AND_SCALE.md) · [LiDAR surface consistency](docs/LIDAR_SURFACE_CONSENSUS.md) · [Camera-only reconstruction](docs/CAMERA_ONLY_ACCURACY.md) · [Surface reconstruction](docs/SURFACE_RECONSTRUCTION.md) · [Fusion diagnostics](docs/SCAN_FUSION_DIAGNOSTICS.md) · [Large-scan memory](docs/LARGE_SCAN_MEMORY.md) |
| 3DGS | [On-device training](docs/ON_DEVICE_3DGS.md) · [Training architecture](docs/ON_DEVICE_3DGS_ARCHITECTURE.md) · [Dataset refinement](docs/ON_DEVICE_TRAINING_QUALITY.md) · [External training](docs/TRAINING.md) |
| Data | [Export](docs/HISTORY_TRAINING_EXPORT.md) · [Coordinate conventions](docs/COORDINATES.md) · [Language support](docs/LOCALIZATION.md) |

Every guide has a Traditional Chinese version linked at its top. For a reproducible issue, include the device, capture mode, build configuration, processing report, and a small scan sample when you can.
