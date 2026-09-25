# Training-format export from scan history

**English** | [繁體中文](HISTORY_TRAINING_EXPORT.zh-TW.md)

Previously, stopping saved only the preview point cloud, playback poses, and summary. Live export created COLMAP files, but history only zipped the folder or shared an old archive, leaving some datasets without `sparse/0`.

Both export entry points now call `ExportManager.writeTrainingDataset`. History prefers review poses, then refined or original poses, and incorporates frames added by resumed capture. Geometry-eligible `.keep` frames are further filtered by the RGB selection report when present. At most 250,000 saved preview points are loaded; older scans without a point cloud use bounded preview reconstruction. Original photos and depth remain intact.

Outputs include `images/`, `sparse/0/cameras.bin`, `images.bin`, `points3D.bin`, `points.ply`, and `poses_refined.jsonl`. COLMAP poses and points receive the same coordinate conversion. `points.ply` keeps ARKit world coordinates; COLMAP trainers should initialize from `sparse/0/points3D.bin`.

Export validates IDs, pose dimensions and finite values, intrinsics, filenames, and image existence. No valid training frames is an explicit error. Failure preserves the previous ZIP. Entering history details clears the directly shareable cached URL so a complete training package is prepared again.

An empty cloud still produces a valid zero-point `points3D.bin` and empty PLY, replacing stale data. Some trainers need additional initialization. `gaussians.ply` is a trained model, not a required input format. On-device training keeps its checkpoint and model in `gaussian-training/`, which the dataset ZIP leaves out (it zips a hard-linked mirror without that folder, so no media is copied); the model has its own `scan_…-3dgs.zip`. Old scan models remain available for export or deletion.

Archives are shared through the system share sheet with the file itself. SwiftUI `ShareLink(item: URL)` handed apps a file link that only AirDrop and Files accepted; LINE and Teams failed. Very large archives can still exceed a receiving app's own size limit.

## Regression validation

```sh
swiftc arkit-3dgs-scanner/Capture/TrainingFrameSelector.swift -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,ExportManager}.swift \
  arkit-3dgs-scanner/History/ScanLibrary.swift tools/test_history_training_export.swift \
  -o /tmp/fable-history-export-test
/tmp/fable-history-export-test
```

The 14 export checks cover preview-only legacy scans, ZIP replacement, counts/calibration/poses/coordinates in all three binaries, quality selection, corrected-pose priority, preserved raw files, actual ZIP contents, missing images, malformed poses, failed export preserving an old archive, and empty clouds. History and capture/ZIP regressions provide additional coverage. Device builds do not replace sensor testing.

## Repairing a downloaded legacy scan

`tools/prepare_training_export.swift` follows the same history path, writes training files into the supplied scan directory, and creates a sibling ZIP. Copy the original directory first if an unchanged backup is needed.

```sh
swiftc arkit-3dgs-scanner/Capture/TrainingFrameSelector.swift -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,ExportManager}.swift \
  arkit-3dgs-scanner/History/ScanLibrary.swift tools/prepare_training_export.swift \
  -o /tmp/fable-prepare-training-export
/tmp/fable-prepare-training-export /path/to/scan_directory
```

## Capture metadata filename

New captures use `capture-meta.json` to avoid trainer detection of unrelated `meta.json` formats. Legacy metadata remains readable and is renamed before preparing or packaging exports, preserving its bytes and unknown fields. When both names exist, the new file takes priority and the old file is preserved as `capture-meta-legacy-UUID.json`.

Already-shared ZIPs do not change automatically. Export again with the updated app, or rename `meta.json` inside an extracted legacy scan. `tools/arkit2gs.py` reads both names.
