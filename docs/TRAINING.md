# External 3DGS training

**English** | [繁體中文](TRAINING.zh-TW.md)

The app prepares datasets on the phone; Gaussian training runs externally. Unzip the exported scan and use `images/ + sparse/0`. The sparse model contains selected image poses, per-image PINHOLE calibration, and initialization points. It does not contain complete SfM observations or tracks.

## LichtFeld Studio / MrNeRF

Open the extracted COLMAP dataset with [LichtFeld Studio](https://github.com/MrNeRF/LichtFeld-Studio). Follow that project's build/install guide and your installed version's help for CLI options. Record the trainer version and settings when comparing scans; this repository does not pin a trainer release.

Use `sparse/0/images.bin` as the training-image list. The images directory preserves all captured originals, including photos excluded by selection. A workflow that independently enumerates that directory must also apply `training-selection.json`'s selected IDs.

`points3D.bin` is the initialization point cloud, not a trained Gaussian model. Mobile output is currently capped at 250,000 points. New scans do not include `gaussians.ply`; that is a potential training result, not a missing input file.

## Other trainers

The optional converter can write COLMAP and Nerfstudio layouts:

```sh
python tools/arkit2gs.py /path/to/scan -o /path/to/dataset --format both
```

Check conversion options and selected-frame handling for your input rather than assuming a re-converted dataset is identical to the app export. Follow the installed trainer's documentation for dataset import, image scaling, evaluation views, initialization, and camera optimization.

[Nerfstudio Splatfacto](https://docs.nerf.studio/nerfology/methods/splat.html) documents its training and export workflow. Other potential consumers include the [original 3DGS implementation](https://github.com/graphdeco-inria/gaussian-splatting) and [gsplat](https://github.com/nerfstudio-project/gsplat). Supported loaders, hardware requirements, and flags depend on their versions; no cross-trainer PSNR gain or runtime is guaranteed here.

## Pose refinement and missing tracks

The app uses corrected anchors and, when validation passes, LiDAR-guided local BA. Failed validation retains prior poses. Refusion uses the matching pose set; changing cameras independently from the initialization cloud can create inconsistency.

Empty image observations and point tracks are valid for this exported seed model, but a bundle adjuster cannot reconstruct missing correspondences by itself. A desktop refinement pipeline would need feature extraction, matching, consistent camera/image IDs, triangulation, and validation before BA. See COLMAP's [known-camera-pose reconstruction discussion](https://colmap.github.io/faq.html#reconstruct-sparse-dense-model-from-known-camera-poses). Pose changes require corresponding cloud realignment or refusion. The phone pipeline does not require running desktop COLMAP.

## Optional depth supervision

Saved LiDAR depth is float32 in meters, with dimensions recorded in scan metadata/frames. Never assume all files are 256×192. Conversion to millimeter PNG or another trainer-specific format needs valid-depth masking, unit scaling, image/depth resolution and orientation handling, and the trainer's expected camera convention. Merely adding a `depth_file_path` does not enable a depth loss in every trainer.

## Diagnosing blur and double edges

1. Run `tools/validate_dataset.py` on the scan; inspect pose jumps, intervals, and calibration consistency.
2. Compare the original and optimized copy with identical trainer settings, image scaling, and held-out views.
3. Inspect photos at useful resolution. Motion estimates are risks, while low texture can prevent reliable sharpness measurement. Capture clearer overlapping views if actual details are weak.
4. Check double edges and local surface thickness. Additional points and lower optimization residuals do not prove absolute accuracy.
5. Keep coordinate frames consistent: COLMAP cameras/points receive the configured paired world rotation; raw JSONL and PLY previews retain ARKit coordinates. See [coordinates](COORDINATES.md).
6. Inspect incomplete coverage, reflections, moving objects, exposure changes, and long-range drift before attributing every artifact to trainer settings.

New exports use `capture-meta.json`. If an old package is misdetected because it contains `meta.json`, re-export with the updated app or rename the extracted capture metadata. Existing archives do not update automatically. No claim is made that selection or local refinement will remove all 3DGS ghosts without retraining and comparison.
