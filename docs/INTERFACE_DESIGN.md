# Interface design

**English** | [繁體中文](INTERFACE_DESIGN.zh-TW.md)

The app is dark and 3D-first. The camera feed or the point cloud fills the screen, and controls float above it on dark glass. Each screen has one prominent action, and secondary controls stay quieter. Controls appear only when they apply to the current step. This page describes the shared design system, the screens, and how to inspect them. The capture, processing, and export pipelines are unchanged.

## Design system

`arkit-3dgs-scanner/Design/DesignSystem.swift` holds the tokens and components. `Capture/UI/HUDStyle.swift` keeps the dark glass (`hudGlass`) and shadowed text (`hudText`) used over the camera.

| Token | Values |
| --- | --- |
| Spacing (`DS.Space`) | 4, 8, 12, 16, 20, 24, 32 pt |
| Corner radius (`DS.Radius`) | 12, 16, 22, 28 pt |
| Sizes (`DS.Size`) | 44 pt minimum touch target, 52 pt primary button, 78 pt shutter, 560 pt maximum panel width |
| Colors (`DS.Palette`) | Canvas, surfaces and strokes; text at 100 / 64 / 40% white; spatial-cyan accent (also the asset-catalog accent) with dark text on it; record red; success, warning, danger and info |

The app root applies the dark color scheme and the accent tint. Point-cloud viewports use the same canvas color, so the scene and the interface read as one surface.

| Component | Use and states |
| --- | --- |
| `DSPrimaryButtonStyle` | The main action of a screen. Pressed (scale and darken), pointer hover (lift), loading (spinner, stays accent), disabled (opaque gray, so content behind it never shows through) |
| `DSSecondaryButtonStyle` | Glass capsule for secondary actions. Pressed, hover and disabled states |
| `DSIconButtonStyle` | Round 44 pt glass button. `isSelected` tints toggles that are on; `foreground` colors destructive icons |
| `DSStatusPill` | Status and guidance capsule with a tone (neutral, accent, success, warning, danger, info) and an optional pulsing recording dot |
| `DSMetric` | Compact icon + value chip for frames, points and modes |
| `DSSegmentedPicker` | Floating segmented control with a sliding accent selection; `fillsWidth` gives equal-width segments whose labels shrink slightly instead of truncating |
| `DSActionCardLabel`, `DSActionIcon` | Tinted action card: round icon (or progress ring / spinner), title, one short detail, chevron. Scan actions (train, export/share, quality) use it on the review screen, the scan detail, and the saved model |
| `SystemShare` | Presents the system share sheet with the file itself, so share extensions (LINE, Teams, Mail) receive the ZIP; SwiftUI `ShareLink(item: URL)` offered only a file link that those extensions could not load |
| `DSProgressRing`, `DSToast` | Determinate progress; short success confirmation |
| `DSFlowLayout` | Wraps chips onto new rows instead of clipping them |
| `dsCard`, `dsFloatingPanel`, `dsCanvas` | Cards on the canvas, floating panels over scenes, and the app background |

Haptics use SwiftUI sensory feedback: start and stop of scanning, success when processing or export finishes, a warning when capture is blocked, and selection changes in the library.

## Screens

### Home

The home screen shows the capture mode (LiDAR or standard camera), a short introduction and a **Scan history** card with the number of saved scans. **Start scanning** floats at the bottom with a note that processing stays on the device; on devices without AR support it is disabled with an explanation.
- The toolbar has the language menu (globe, current language) and the scanning guide (**?**).
- Until the first scan is saved, the three steps are shown on the home screen.

### Scan history

The history opens only when the card is tapped.
- **Layout.** A grid of covers shows each scan's date, image and point counts. Badges mark LiDAR scans and scans with a share archive. There are two columns on iPhone and larger covers on iPad.
- **Select** turns the grid into a multi-select view with **Select all** and **Delete selected**, in a bar that appears only while selecting. Selecting everything and deleting it is the "delete all" case, and the confirmation says so.
- **Delete.** A long press on a cover offers **Delete**. Every deletion is still confirmed.
- **Empty history.** The page says there is no scan history yet and offers **Back to scanning**.

### Capture HUD

- **Top bar.** Close, a centered status pill, and live statistics while scanning (frames, points, estimated storage, and a LiDAR-off note in camera mode).
- **Guidance slot.** One prioritized hint at a time. Blocking warnings also draw the red frame and trigger a warning haptic.
- **Tool rail.** Point cloud, heat map and room structure toggles. It appears only while scanning, on the trailing edge (leading in landscape).
- **Shutter.**
  - While scanning with LiDAR, its ring shows view coverage: the share of the surface seen over at least 30° (red below 30%, orange below 60%, then green), with the percentage beside it.
  - **Scan settings** is a single button to the left of the shutter. The current mode (LiDAR or camera mode) is shown under it.
- **Contextual indicators.**
  - The motion meter appears only near the blur threshold.
  - The heat-map legend appears only in heat-map mode. It shows the viewing-angle span from 0° to 30°+ ([how it is measured](LIDAR_QUALITY_AND_PREVIEW.md#view-coverage-heat-map)).
  - The instruction hint appears only for the first few frames.
- **Landscape.** On compact-height layouts the shutter column sits on the trailing edge and the review panel at the bottom trailing corner, so the center of the scene stays clear.

### Processing

`FusionProcessingView` keeps its staged progress page: ring, percentage, stage checklist, elapsed time and frame count. It uses the same accent. See [fusion review](FUSION_REVIEW.md).

### Review after capture

The optimized point cloud fills the screen. The top bar has close, the status pill, a quality-details button (warning tint when there is a notice) and **Fit cloud**. A floating panel holds:
- metric chips: frames, points, the image-reconstruction result, and the floor plan when one exists;
- the **Train 3DGS** card, the same as in the scan detail;
- the **Export 3DGS dataset** card, which shows a spinner and the stage while exporting and becomes **Share scan** when done;
- **Resume scan** and a destructive discard button (after export: **New scan**).

A gesture hint shows for four seconds.

### Scan detail (history)

The point cloud or the photo route fills the screen.
- A full-width switcher chooses **3D point cloud** or **Captured images**; its segments share the width, so neither label truncates. Chips show images, points and capture mode. **Fit cloud** floats at the bottom trailing corner of the 3D view.
- The bottom panel stacks three cards with one layout: **Train 3DGS** (with progress, a saved model, or a resumable run), **Export 3DGS dataset** (then **Share scan**), and **Scan quality information** (warning tint when photos need a look, with the selected image count). Optimization progress, with its percentage and **Cancel**, appears in the same panel. A toast confirms when an export archive is ready.
- **More actions** still holds scene scale, optimization and deletion.
- Route playback uses glass overlays and an accent play button, and places the photo and cloud side by side on wide screens.

### 3DGS training

One screen per scan, opened from the training card.
- **Setup.** The scan's photo, softened, sits behind a card that says what will happen. Below it are three quality cards (Quick preview, Standard with a *Recommended* badge, High quality), each with a plain description and, after a run on this phone, its measured time. Then a memory check, the one reminder that matters (keep the app open, preferably on power), an **Advanced settings** button (a sheet with pose refinement, PPISP and anti-aliasing, and the preset's technical details), and **Start training**.
- **Training.** The live model fills the screen, with a short gesture hint. The bottom card shows a progress ring, the current stage in words, and the remaining time; below them are one quiet line of iteration, Gaussians, loss, PSNR and elapsed time, and Pause / Save progress / Stop. Notices appear at the top only for pauses, throttling or memory limits.
- **Resume.** A ring with the saved percentage, **Resume where you left off**, **Restart** and **Delete progress**.
- **Model.** The saved model in the orbit viewer, a summary, and a **Share 3DGS model** card.

### Floor plan, measurement and point picking

These keep their workflows and use the shared buttons, cards and canvas. Measurement groups selection, calibration/validation and metric export into three cards. The point picker's confirm button is the primary action.

## Inspecting the UI in the Simulator

Debug builds accept launch arguments that render UI states without an AR session or writing scan files. Release builds do not include them.

| Argument | Shows |
| --- | --- |
| `--preview-capture-controls` | Idle capture HUD |
| `--preview-scanning` | Busiest scanning HUD: warning, motion meter, heat map, coverage ring |
| `--preview-review` | Review panel over a synthetic room, with a notice and an image-reconstruction result |
| `--preview-fusion` | Processing page (see [fusion review](FUSION_REVIEW.md)) |
| `--preview-history` | Scan history |
| `--preview-scan-detail`, `--preview-scan-detail-photos`, `--preview-scan-detail-measure` | The newest saved scan's detail: 3D tab, photo tab, or the scene-scale sheet (needs a scan in the app's `Documents/scans`) |
| `--preview-training SCAN`, `--preview-training-start SCAN [--training-iterations N]`, `--preview-training-resume SCAN` | The 3DGS training screen of a saved scan (folder name): setup, a started quick run, or resume from its checkpoint |
| `--compact-height` | Adds a compact vertical size class to check the landscape arrangement |

Add `-app.language en` to check English.

```sh
xcrun simctl launch --terminate-running-process booted arkit-3dgs-scanner --preview-scanning -app.language en
xcrun simctl io booted screenshot scanning.png
```

## Validation and limits

- Checked on the iPhone 16 Pro, iPhone SE (3rd generation) and iPad Pro 11-inch Simulators, in both languages, with the preview states above and two saved scans.
- The Simulator has no camera or LiDAR, so live AR guidance, the camera feed under the HUD, device rotation, haptics, pointer hover and performance on a phone still need device checks.
- Landscape was checked with `--compact-height` rather than by rotating a device.
