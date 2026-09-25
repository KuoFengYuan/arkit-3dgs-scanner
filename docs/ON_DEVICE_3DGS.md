# On-device 3DGS training

**English** | [繁體中文](ON_DEVICE_3DGS.zh-TW.md)

**Train 3DGS** optimises a Gaussian Splatting model of a saved scan on the iPhone GPU (Metal). There is no server and no desktop step. Rendering, the loss, the gradients, and every update of the Gaussians, the colour model, and the cameras happen in the app. The COLMAP dataset export for external trainers ([external training](TRAINING.md)) is unchanged. For the code structure, threads, GPU pipeline and file formats, see the [training architecture](ON_DEVICE_3DGS_ARCHITECTURE.md).

## Using it

- **Where:** the **Train 3DGS** card in a scan's History detail, and the same card on the review screen right after a capture (it saves the scan first). Both open one screen for that scan.
- **Quality:** three choices with plain descriptions. Once a run has finished on this phone, each choice also shows how long it took there at the chosen resolution. Nothing is extrapolated from another device.

  | Choice | Iterations | Gaussian cap | SH degree |
  | --- | --- | --- | --- |
  | Quick preview | 4,000 | 300,000 | 2 |
  | Standard (recommended) | 10,000 | 600,000 | 3 |
  | High quality | 20,000 | 1,000,000 | 3 |

  The memory plan may lower the Gaussian cap (see [memory](#memory-safety)). The iteration counts were raised from 3,000 / 7,000 / 15,000 when the trainer became faster; see [speed](#speed-and-longer-presets).
- **Training resolution:** chosen separately from the quality. Photos are downscaled, never upscaled, and a saved run keeps its resolution when resumed.

  | Choice | Training image long edge | Relative time per iteration |
  | --- | --- | --- |
  | Low (default) | 960 px | 1× |
  | Medium | 1,440 px | about 1.7× |
  | High (original) | 1,920 px, the photos' own size | about 2.6× |

  The times are Mac GPU measurements on a trained 600,000-Gaussian model, made with the trainer before its faster backward pass; the phone's ratios are not measured.

  See [training resolution](#training-resolution-and-a-stricter-held-out-test) for what the extra pixels buy.
- **Advanced settings** (a sheet; the defaults suit most scans):
  - camera pose refinement;
  - PPISP colour correction (on by default only when the capture's exposure varied by at least 0.15 EV);
  - anti-aliasing (Mip filter).
- **While training:** the live model fills the screen. Drag to orbit, use two fingers to pan, pinch to zoom, and double-tap to reset. The bottom card shows:
  - a progress ring and the current stage (building shape and adding detail, sharpening details, final touches);
  - the remaining time, once the speed has settled;
  - one line with the iteration, Gaussian count, loss, PSNR, and elapsed time;
  - Pause / Resume, Save progress, and Stop (keep or delete the progress);
  - **Finish and save model**, which ends the run now and saves the current state as the model, exactly like a completed run (including from a pause);
  - app memory against the training plan;
  - whether switching to another app pauses the run or lets it continue.
- **Leaving the screen:** the run keeps training while you use the rest of the app, for example History or another scan's detail. The home screen's **Scan history** card shows *Training 3DGS · n%* (or *paused*), and the scan's **Train 3DGS** card opens the live view again.
- **In the background (iOS 26+):** when a run starts or resumes, the app asks iOS for a continued-processing task (`BGContinuedProcessingTask`) that requires the GPU. If iOS grants it, switching apps keeps training, without live previews, and iOS shows the progress in a system notice where the user can also stop it. This needs:
  - background GPU support on the device (`BGTaskScheduler.supportedResources` contains `.gpu`);
  - the **Background GPU Access** capability, which only paid Apple Developer teams can add: in Xcode, select the `arkit-3dgs-scanner` target, open **Signing & Capabilities**, click **+ Capability**, and add **Background GPU Access**. It adds the `com.apple.developer.background-tasks.continued-processing.gpu` entitlement.
  - `BGTaskSchedulerPermittedIdentifiers` in `Config/Info.plist`, which the project already declares (`$(PRODUCT_BUNDLE_IDENTIFIER).training.*`).

  Without any of them, the request fails quietly and the run pauses in the background as before. If iOS ends the time, or a GPU submission fails while in the background, the run pauses with a checkpoint instead of counting a failure. Resuming it by hand asks for background time again.
- **Automatic pauses:** the run saves a checkpoint and pauses when:
  - the app leaves the foreground without background time;
  - a new capture opens (training shares the GPU and memory with ARKit and fusion), and it continues when the capture closes;
  - the device is critically hot (it resumes once cooled to *fair*);
  - the battery is below 15% and unplugged;
  - memory pressure is critical.

  A *serious* thermal state or Low Power Mode slows the loop instead of pausing it.
- **Afterwards:** the model is saved and opens in an interactive viewer from History, including after restarts. History cards show a run in progress (with percent and remaining time), a saved model, or a run that can resume. A run the app never finished, for example after the app was killed, reads as interrupted and resumes from its last valid checkpoint. **Share 3DGS model** builds `scan_…-3dgs.zip` and opens the system share sheet.
- **Enhance model** (on the saved model's screen) keeps training the saved model. See [enhancing a saved model](#enhancing-a-saved-model).
- **Retraining** keeps the saved model until the new run completes. Stopping it with *delete* removes only its own progress. Stopping it with *keep* leaves a run that resumes first, while the old model stays. **Delete progress** never deletes a saved model. The scan that is training cannot be deleted from History until its training stops.

## Method

**The model is MRNF-based.** Its base is MRNF, the default densification strategy of LichtFeld Studio (MrNeRF/LichtFeld-Studio), on a standard 3D Gaussian Splatting rasterizer with the Mip-Splatting 2D filter. On top of that base, this project adds its own methods to raise accuracy and speed. Each was measured on real iPhone 17 Pro scans, with held-out photos scored after test-time pose alignment:

| Added to MRNF | What it does | Measured effect |
| --- | --- | --- |
| Pose refinement with a per-view rate | ARKit-anchored camera corrections whose Adam rate grows when a view gets few updates | +0.7 to +1.2 dB |
| Seed spread | Spreads the fused seed lattice by its own spacing, at most 3 cm | +0.45 dB |
| LiDAR depth seeds | One seed in every empty 4 cm cell the photos' LiDAR saw | +0.3 to +0.5 dB; empty held-out pixels roughly halved |
| Hole filling | Faint seeds on camera rays where the render stays empty | For regions without depth: +0.45 dB on a synthetic scan; about +0.04 dB with LiDAR |
| LiDAR depth loss | Pulls every blended splat towards the measured surface | Share of pixels with depth off by more than 5%: 29% → 8% (FBDA13), 52% → 17% (7F2187), at equal PSNR |
| Growth ramp | Reaches the Gaussian cap at the end of the growth phase instead of within the first refines | +0.02 dB at 7,000 and +0.1 dB at 10,000 iterations; fewer empty pixels; a faster first half |
| Exact tile spans | Lists a splat only in the tiles its ellipse reaches | 22% fewer tile–Gaussian pairs; the same images |
| One-pass SIMD reduction | Sums a Gaussian's 13 backward values over a SIMD group in 16 shuffles instead of 65 | Backward pass 39.4 → 23.7 ms per iteration |
| Longer presets | Spends the speed-up on about 1.4× the iterations | +0.7 to +0.9 dB on three scans, in 10% less time (Standard) |

Together, on the same three scans (aligned held-out PSNR):

| Scan | MRNF base, as first built | With the accuracy additions | This trainer |
| --- | --- | --- | --- |
| FBDA13 | 27.56 dB | 29.13 dB | 30.04 dB |
| 7F2187 | 24.25 dB | 25.97 dB | 26.66 dB |
| 9F8040 | 27.45 dB | 28.31 dB | 29.10 dB |

The first column is the first build: MRNF with pose refinement at 10⁻⁴ and the fused seeds as they were. The second is the trainer before this speed work, measured again now; for 9F8040 it includes the LiDAR depth loss, which it did not have when it scored 28.55 dB. See [why scans trained poorly](#why-scans-trained-poorly-and-what-changed) and [speed](#speed-and-longer-presets) for each step. Where an idea came from other work, [provenance](#provenance-and-licences) says so.

The trainer is an independent Swift and Metal implementation. It follows the published methods and LichtFeld Studio's defaults for the MRNF base.

- **Rasterizer.** Tile-based EWA splatting (16×16 tiles) with a depth sort and a stable per-tile radix sort. Alpha is capped at 0.999, fragments below 1/255 are skipped, and a pixel stops when transmittance falls below 10⁻⁴.
  - **Exact tile spans:** a splat is listed only in the tiles whose pixel centres its ellipse reaches (alpha ≥ 1/255), computed row by row in O(1) per tile row. The bounding box alone also listed tiles that its corners crossed but the splat never touched.
  - **Backward pass:** it replays each tile in reverse. Each SIMD group sums its 32 pixels' 13 values per Gaussian with a transposed reduction of 16 shuffles and adds them with one device atomic each. Summing the eight SIMD groups in threadgroup memory first was slower, because its 26 KB left room for one threadgroup per GPU core.
  - **Submissions:** the render and the loss share one command buffer, and the CPU prepares the view's LiDAR target while it runs.
  - **Gradients:** they reach means, scales, rotations, opacity, spherical harmonics, and the camera pose. Finite-difference tests check them against a double-precision CPU reference.
- **GPU watchdog.** The backward pass is submitted in bands of tile rows, at most 2,048 tiles per command buffer: two at 960 × 720 and six at 1,920 × 1,440. A single full-resolution command buffer ran long enough that macOS aborted it (`kIOGPUCommandBufferCallbackErrorImpactingInteractivity`) when other GPU work competed. Bands give the same gradients as one pass, to float rounding. If a GPU submission still fails before the parameter update, that view is skipped; three failures in a row fall back to the last checkpoint as before.
- **Loss.** 0.8 · L1 + 0.2 · (1 − SSIM), with an 11×11 Gaussian window.
- **LiDAR depth loss.** On photos with LiDAR depth, the loss adds 0.1 · Σᵢ wᵢ |zᵢ − z| / z per pixel, decaying to 10% over the run. Here z is the LiDAR depth and wᵢ, zᵢ are each blended splat's weight and depth. Every contributing splat is pulled to the measured surface, so floaters in front of and behind it do not cancel out. It uses only medium- or high-confidence depth between 0.1 and 5 m, away from depth edges, where LiDAR blurs at 256 × 192.
- **Densification (MRNF).** LichtFeld Studio's default strategy, with the schedule scaled to the run length.
  - Error-weighted, edge-guided Gumbel top-k selection of splats to split, with long-axis splits.
  - Soft pruning below opacity 1/255; freed slots are reused.
  - Opacity and scale decay, position noise, and a screen-share limit.
  - Growth stops at the memory plan's Gaussian cap. **Growth ramp** (this project): the number of Gaussians may rise only linearly, from the seeded count to the cap at the end of the growth phase (half the run). Without it, MRNF reached the cap within the first 14% of a Standard run. See [learning after the cap](#learning-after-the-gaussian-cap).
- **Mip filter.** The Mip-Splatting 2D filter (0.1 px² with opacity compensation) in training, the live preview, and the saved-model viewer.
- **PPISP.** Per-image exposure and chromaticity, plus per-camera vignetting and response curve, trained jointly. Novel views use 0 EV, neutral colour, and the camera's vignetting and response. The optional exposure *controller* is not implemented.
- **Pose refinement.** Each training view gets a correction w2c′ = [R(ω) | τ] · w2c in its own camera frame. A Gaussian prior keeps it near the ARKit pose (0.25°, 5 mm). Metric scale never changes. Adam uses 10⁻³, scaled up to 3× when a view gets fewer than about 18 updates in a run (see below). Refined poses go to `model/training-poses.jsonl`; the scan's pose files are never rewritten.
- **Capture motion (experimental).** Each photo can be rendered with the camera's motion during exposure and readout, following Seiskari et al., "Gaussian Splatting on the Move" (2024).
  - **Velocity:** the camera-frame velocity comes from the neighbouring raw ARKit poses in time. Corrected pose sets can jump between segments, which would read as motion. A frame gets no velocity when its backward and forward differences disagree (by more than 1.5 rad/s or 0.8 m/s), when it moves faster than 3 rad/s or 1.5 m/s, or when it sits next to a gap.
  - **Rolling shutter:** a splat centre moves to where it was when its row was read.
  - **Motion blur:** the splat is spread along its pixel velocity over the exposure, with its opacity compensated so its total contribution is unchanged.
  - **Screen velocity:** computed at the same frustum-clamped ratios as the projection Jacobian, and capped so the shift and the blur stay within 5% of the image. Without the clamp, splats far off-axis or next to the camera got speeds large enough to throw them across the view: on FBDA13, a 12 ms readout changed some renders to 11–12 dB PSNR against the still render, where a real 2 px shift gives 31–37 dB.
  - **Gradients:** the velocities are treated as constants; the rolling-shutter row time still follows the splat's position.
  - **Previews and exports:** they render a still camera.

## Enhancing a saved model

**Enhance model** loads `model/` and continues it instead of seeding from the point cloud:

- **What is loaded:** every Gaussian from `gaussians.sog` (or the `gaussians.ply` of a model saved before SOG, exactly), each training view's refined pose from `training-poses.jsonl` (turned back into its correction of the ARKit pose, matched by frame id), and the PPISP colour model from `ppisp.json` when PPISP is on. The Adam moments start fresh.
- **Schedule:** a model saved at iteration *n* that gets *k* more runs as iteration *n* + 1 … *n* + *k* of an (*n* + *k*)-iteration schedule. Learning rates, densification, and pose refinement pick up at that point: growth continues only while the schedule is in its first half and the Gaussian cap has room, and refinement then prunes and replaces within the cap.
- **Choices:** 4,000, 10,000, or 20,000 more iterations (the quality cards), a training resolution, and the advanced settings. The Gaussian cap and SH degree are at least the saved model's. A higher SH degree starts its extra coefficients at zero, so the model first renders exactly as saved. No depth seeds are added.
- **Memory:** every saved Gaussian needs a row in the plan. If the chosen resolution leaves too few on this phone, the setup says how much memory is needed, and nothing starts.
- **Safety:** as with retraining, the saved model is replaced only when the enhancement completes, and stopping it with *delete* restores the saved model's status. Progress counts from the start of the enhancement, and the iteration line shows the total, for example 10,000 / 20,000.

On a synthetic scan, a model reloaded from its files rendered the training views at the same PSNR to 0.001 dB, with pose corrections equal to 10⁻¹⁵. Training it another 600 iterations raised held-out PSNR by about 1 dB (30.2–30.3 to 31.2–31.4 dB in two runs). On FBDA13, enhancing the 960 px Standard model by 3,000 iterations raised aligned PSNR at 1,920 × 1,440 by about 0.5 dB (see [training resolution](#training-resolution-and-a-stricter-held-out-test)).

## Memory safety

Every allocation comes from a plan computed before training, with overflow-checked sizes.

- **Budget:** the automatic budget is 55% of what the process can still allocate, minus 450 MB headroom. It never exceeds a device-tier ceiling: 900 MB on 4 GB phones, 1.6 GB on 6 GB phones, and 2.6 GB on 8 GB or larger.
- **Fitting the plan:** if the preset does not fit, the Gaussian cap is lowered. Densification never exceeds the cap. Higher training resolutions need larger image, loss, and tile buffers, so on smaller budgets they leave room for fewer Gaussians. For the Standard preset (600,000 requested):

  | Resolution | Plan, 1.6 GB or 2.6 GB budget | Gaussian cap, 900 MB budget |
  | --- | --- | --- |
  | 960 × 720 | 1,003 MB | 515,072 |
  | 1,440 × 1,080 | 1,125 MB | 415,744 |
  | 1,920 × 1,440 | 1,296 MB | 275,456 |

  The setup screen's memory check shows the plan for the chosen resolution before training starts.
- **Streaming:** training photos are decoded on demand at the training resolution, into a small bounded cache. Only the next view is prefetched.
- **Under pressure:** a memory warning purges the cache and freezes growth. Critical pressure saves a checkpoint and pauses. Repeated tile-buffer overflow saves and stops with a clear message.
- **Checkpoints:** written only when the run pauses (by the user, for heat, battery, memory, or a new capture), when the app leaves the foreground (also when training continues in the background), and when a run stops with its progress kept. A 600,000-Gaussian checkpoint is about 425 MB, so the periodic ones (every 1,000 iterations or 180 s, about every 30 s with the faster trainer) wrote gigabytes per run. Each checkpoint is a temporary file renamed over the previous one, with a checksum and an end marker, so there is only ever one; temporary files left by a write the app never finished are removed at the next save. A damaged, truncated, or mismatched checkpoint is refused.
  - If the app crashes or is force-quit in the foreground, the progress since the last pause is lost.
  - A GPU failure in the foreground with no checkpoint continues from memory; the trainer skips failed views before it touches the parameters.
- **Model viewer:** it checks the memory needed before loading a model.

## Files

Everything lives in `gaussian-training/` inside the scan:

```text
gaussian-training/
├── state.json          # Status, progress and configuration (History reads this)
├── checkpoint.gsck     # Resumable state: parameters, optimiser moments, PPISP, poses, schedule
├── snapshot.jpg        # Last checkpoint's view, shown on the resume screen
└── model/
    ├── gaussians.sog        # The model, SOG (models saved before SOG: gaussians.ply)
    ├── gaussians.json       # Metadata, frames, and viewer notes
    ├── ppisp.json           # Colour model, only when PPISP was used
    ├── training-poses.jsonl # Refined training cameras
    ├── training-report.json # Settings, timings, validation PSNR, peak memory
    └── preview.jpg
```

The dataset ZIP excludes this folder. `scan_…-3dgs.zip` contains `model/`. Deleting a scan deletes both.

**SOG model file.** A completed run saves `gaussians.sog`, the SOG format (version 2) that PlayCanvas / SuperSplat and LichtFeld Studio read. It is a ZIP of `meta.json` and lossless WebP textures with one texel per Gaussian in Morton order:

| Texture | Holds |
| --- | --- |
| `means_l`, `means_u` | sign(v) · ln(\|v\| + 1) of each coordinate, 16 bits split over two images |
| `quats` | the three smallest components of the unit quaternion; alpha 252 + the dropped one's index |
| `scales` | indices into a 256-entry codebook of log scales |
| `sh0` | indices into a 256-entry codebook of DC coefficients; alpha = opacity |
| `shN_centroids`, `shN_labels` | a k-means palette of the higher-band SH vectors (up to 65,536 entries, values through a 256-entry codebook), and each Gaussian's 16-bit label |

- **Writing on the phone:** ImageIO reads WebP but cannot write it, so the app has its own lossless WebP (VP8L) encoder: literals only, with the left-pixel predictor when it helps. The SH palette is clustered on the GPU in half precision (3 Lloyd steps), reusing the gradient and tile-pair buffers that training no longer needs, so saving allocates little beyond the memory plan.
- **Measured on FBDA13 (Standard, 600,000 Gaussians, Mac):**

  | | PLY | SOG |
  | --- | --- | --- |
  | Size | 148.8 MB | 12.1 MB (12.3× smaller) |
  | Held-out, aligned | 29.13 dB | 28.92 dB |
  | Writing | — | 10 s (k-means 8.9 s) |
  | Reading | — | 0.2 s |
  | Peak process footprint while saving | — | 959 MB, within the 1,036 MB plan |

  The palette size and the number of Lloyd steps were compared on the same model: 10 steps gave 28.93 dB in 47 s, 1 step 28.91 dB in 5.5 s, and a 16,384-entry palette 28.85 dB.
- **Lossy:** SOG keeps 16 bits per position axis and 8-bit codebooks for the rest, which cost about 0.2 dB here. The viewer and **Enhance model** read what was saved; an enhancement trains on from the compressed values. Models saved as PLY before SOG still open and enhance exactly.
- **Other tools:** SuperSplat, PlayCanvas and LichtFeld Studio open `gaussians.sog` directly; PlayCanvas `splat-transform` converts it to PLY for tools that need one.

**Viewer compatibility:**

- The model is in the COLMAP export frame, so Y-up viewers show it upside down. Rotate it 180° about X.
- Viewers without an anti-aliased mode dilate by 0.3 px² without compensation, so small splats look slightly thicker and brighter.
- Colours are pre-ISP. Viewers ignore `ppisp.json` and show the uncorrected look, the in-app **ISP off** view.
- Capture-motion settings affect training only.

## Why scans trained poorly, and what changed

Three real iPhone 17 Pro scans were replayed on the Mac GPU with the app's kernels (`tools/train_gaussians.swift`), each trained with the Standard preset of the time (7,000 iterations).

- **FBDA13:** 280 training photos, a room.
- **7F2187:** close range, fast motion.
- **9F8040:** a room at 3–5 m.

Every 8th photo was held out. Held-out views were scored after a 30-step test-time pose alignment. This is the standard fair score when training refines the other cameras, because a held-out view keeps its unrefined ARKit pose.

**1. Pose refinement barely moved the cameras.** Adam changes a view only when that view is sampled, about 18–26 times per run. At a learning rate of 10⁻⁴ that capped any correction near 0.05–0.1° and 1–2 mm, and the median correction was almost equal to the maximum. Real ARKit errors are larger: on FBDA13, the ARKit and anchor-corrected poses differ by a median 0.26° and 15 mm.

| FBDA13, pose learning rate | Training-view PSNR | Held-out, aligned | Median / max correction |
| --- | --- | --- | --- |
| 10⁻⁴ (before) | 27.46 dB | 27.56 dB | 0.061° 1.2 mm / 0.107° 1.9 mm |
| 10⁻³ | 28.80 dB | 28.25 dB | 0.135° 4.0 mm / 0.473° 10.4 mm |
| 3 · 10⁻³ | 28.84 dB | 28.29 dB | 0.150° 4.7 mm / 0.520° 21.9 mm |

Per view, at 10⁻³, 229 of 245 training photos improved, with a median gain of 1.2 dB; the worst 10% gained 1.6 dB. The gain levels off above 10⁻³. On 7F2187 the same change raised training-view PSNR from 24.19 to 25.76 dB and the aligned held-out PSNR from 24.25 to 25.41 dB.

The default is now 10⁻³. It is scaled up, to at most 3×, when a run gives each view fewer than about 18 updates, as in a Quick run or a scan with many photos, so the correction range does not shrink. On the synthetic pose test, the error left after training fell from 0.211° / 8.3 mm to 0.185° / 7.5 mm (from 0.300° / 10 mm before training).

**2. Fast motion blurs photos and skews rows.** Photos use 8.3 ms exposures. The median rotation was 30°/s on FBDA13 and 35°/s on 7F2187, which is about 6 px of blur at full resolution and, if readout takes about 12 ms, 8 px of rolling-shutter skew. Training-view PSNR falls with rotation speed:

- FBDA13: 29.1 dB in the slowest quarter, 27–28 dB in the faster quarters.
- 7F2187: 25.1 dB → 23.4 dB.

On a synthetic scan with physically integrated blur and row-by-row readout, the capture-motion model improved held-out photos by 2.2 dB. Its still renders were 0.9 dB closer to the sharp scene. The synthetic motion is large for its 160 px images, so the 5% cap limits it.

**3. The seed cloud is on a regular lattice.** About 63% of the fused cloud's coordinates sit exactly on 2 cm voxel centres. They are TSDF zero crossings on grid edges: they lie on the surface, but sample it in a regular pattern. The seed matters: keeping 10% of it cost 0.7 dB, and a random seed cost 1 dB.

| FBDA13 seed cloud (pose rate 10⁻⁴) | Held-out, aligned |
| --- | --- |
| As fused (two seeds) | 27.56 / 27.64 dB |
| Spread only along the lattice | 27.59 dB |
| + 1 cm Gaussian noise | 27.78 dB |
| + 2 cm Gaussian noise (two seeds) | 28.01 / 28.09 dB |

The regular pattern is not the problem. Giving the seeds some depth is what helps, which fits the ~1 cm disagreement between LiDAR and photos. Training now spreads the seeds by their median spacing, at most 3 cm; the scan's saved cloud is unchanged.

**4. Surfaces without seeds never grew Gaussians.** Densification only splits existing Gaussians, so a surface that starts without seeds is reached, if at all, by stretched neighbours. The fused cloud keeps only depth that passed its consistency checks. On FBDA13, 18.6% of the photos' LiDAR samples fell in 5 cm cells without a seed, and a quarter of the frames alone showed 16,361 such cells, against 24,446 cells the cloud covers.

Two changes, both on by default:

- **LiDAR depth seeds.** Before training, a grid of each training photo's LiDAR depth is back-projected. One seed, coloured from the photo, goes into every empty 4 cm cell. Medium- and high-confidence depth is used first; low-confidence depth under 4 m fills cells that are still empty. Seeds are capped at a quarter of the Gaussian cap. FBDA13 gained 48,950 seeds in 3.5 s on the Mac.
- **Hole filling during training.** While densification runs, each refine looks at the last rendered view for pixels the Gaussians barely cover (transmittance > 0.4) that differ from the photo (colour error > 0.08). A faint seed goes on each such pixel's ray, at the pixel's LiDAR depth or else the median depth of covered pixels nearby. Hole seeds take at most half of the free slots, and at most 2,000 per refine. Wrong guesses fade and are pruned.

| Pose rate 10⁻³, seed spread | Held-out, aligned | Empty held-out pixels |
| --- | --- | --- |
| FBDA13, no depth seeds | 28.61 dB | 3.87% |
| FBDA13, depth seeds | 29.10 dB | 2.07% |
| FBDA13, depth seeds + hole filling | 29.10 dB | 1.99% |
| 7F2187, no depth seeds | 25.41 dB | 3.28% |
| 7F2187, depth seeds | 25.87 dB | 1.08% |
| 7F2187, depth seeds + hole filling | 25.91 dB | 1.06% |
| 9F8040, no depth seeds | 28.29 dB | 0.36% |
| 9F8040, depth seeds | 28.55 dB | 0.39% |

With LiDAR, the depth seeds do most of the work, and hole filling adds little. Hole filling is for regions without depth. On a synthetic scan whose left wall had no seeds (and no depth), it raised held-out PSNR by 0.45 dB.

All changes together raised the aligned held-out PSNR of all three scans:

| Scan | Before | After |
| --- | --- | --- |
| FBDA13 | 27.56 dB | 29.10 dB |
| 7F2187 | 24.25 dB | 25.91 dB |
| 9F8040 | 27.45 dB | 28.55 dB |

The "before" runs use pose rate 10⁻⁴ and no seed changes. PPISP was off in every run (these captures had locked exposure).

**5. Geometry drifted from the measured surface.** Photos alone leave depth loosely constrained, so a model can match every photo with splats floating in front of or behind the surface. That shows when orbiting away from the capture path. The LiDAR depth loss fixes most of it with no loss in image quality. Depth error is the rendered depth of held-out views against high-confidence LiDAR.

| Scan, depth-loss weight | Held-out, aligned | Median depth error | Pixels off by > 5% |
| --- | --- | --- | --- |
| FBDA13, off | 29.11 dB | 3.14% | 29.3% |
| FBDA13, 0.1 (default) | 29.13 dB | 1.66% | 8.4% |
| FBDA13, 0.5 | 28.91 dB | 0.93% | 1.4% |
| 7F2187, off | 25.93 dB | 5.26% | 51.6% |
| 7F2187, 0.1 (default) | 25.96 dB | 2.06% | 17.1% |
| 7F2187, 0.5 | 25.94 dB | 1.04% | 4.4% |

A weight of 0.5 gives the best geometry but costs 0.2 dB on FBDA13. The loss can also make wrongly placed splats transparent, which raised the share of empty held-out pixels by 0.5–1 point without lowering PSNR.

**6. Things that were not the cause.**

- **Pose source:** training on raw ARKit poses instead of the anchor-corrected ones changed the aligned held-out PSNR by only 0.1 dB.
- **PPISP:** both locked-exposure scans (EV range ≈ 0.02) were worse with it: −1 dB held out on 9F8040. It is therefore off by default for such scans.
- **Mip filter:** no difference at training resolution.
- **Outlier photos:** FBDA13's worst training photos were the first four, from the first second of the capture, and one blurred photo. Leaving out those six lowered the aligned held-out PSNR from 29.10 to 28.95 dB, so bad-looking views still carry useful information.
- **ARKit intrinsics:** on a trained FBDA13 model, scaling the focal length by ±0.5% cost about 2.5 dB of training-view PSNR, and the fitted optimum sits within 0.02% of ARKit's value. Shifting the principal point by 2 px cost about 3.7 dB, almost equally in every direction. A model trained with given intrinsics favours them, but an error of 0.1% would still show up as an asymmetry, and none did.

## Speed and longer presets

Measured on the Mac GPU (M1 Pro) with the app's kernels, on FBDA13 at 960 × 720. For the stages, the same trained Standard model ran 400 more iterations with each version; the times are GPU time per iteration.

| Stage | Before | After |
| --- | --- | --- |
| Projection and depth sort | 1.65 ms | 1.75 ms |
| Tile sort, blending and loss | 7.32 ms | 6.91 ms |
| Backward pass | 39.41 ms | 23.71 ms |
| Adam | 5.53 ms | 5.74 ms |
| Iteration, wall clock | 57.9 ms | 40.7 ms |
| Tile–Gaussian pairs per view | 694,602 | 544,778 |

Step by step, per iteration: 57.9 ms, then 55.5 ms with exact tile spans, 43.1 ms with the transposed SIMD reduction, and 40.2 ms with SIMD-group atomics instead of the threadgroup buffer. Sharing one command buffer for the render and the loss made no measurable difference on the Mac (40.7 ms); it saves two CPU–GPU round trips per iteration. Backward batches of 128 or 256 Gaussians instead of 64 changed nothing. The rasterizer tests pass unchanged, and the new kernels trained the same model: 29.10 dB against 29.13 dB, within the run-to-run spread of about 0.05 dB.

Whole Standard runs of FBDA13, one at a time on an otherwise idle GPU:

| Run | Time | Held-out, aligned | Empty held-out pixels |
| --- | --- | --- | --- |
| Before, 7,000 iterations | 354 s | 29.13 dB | 2.46% |
| This trainer, 7,000 iterations | 236 s, 1.50× faster | 29.20 dB | 2.08% |
| This trainer, 9,000 iterations | 299 s | 29.58 dB | 1.75% |
| This trainer, 10,000 iterations (the new Standard) | 319 s | 29.96 dB | 1.76% |

The growth ramp adds to the speed-up, because a run's first half holds fewer Gaussians. More iterations are what raise quality (see [learning after the cap](#learning-after-the-gaussian-cap)), so the presets now spend the speed-up on them:

| Preset | Before | This trainer |
| --- | --- | --- |
| Quick (300,000 cap, SH 2) | 3,000 iterations, 89 s, 27.07 dB | 4,000 iterations, 81 s, 27.46 dB |
| Standard (600,000) | 7,000 iterations, 354 s, 29.13 dB | 10,000 iterations, 319 s, 29.96 dB |
| High (1,000,000) | 15,000 iterations, 1,101 s, 30.39 dB | 20,000 iterations, 978 s, 30.87 dB |

On FBDA13 every preset now takes about 10% less time and scores 0.4–0.8 dB higher.

The same comparison on the other two scans, Standard before (7,000 iterations) and now (10,000), run four at a time:

| Scan | Before | This trainer |
| --- | --- | --- |
| 7F2187 | 25.97 dB | 26.66 dB (+0.69) |
| 9F8040 | 28.31 dB | 29.10 dB (+0.80) |

**Memory:** peak process footprint rose from 914 MB to 1,005 MB on FBDA13, still within the 1,036 MB plan. The rise coincides with the tile–Gaussian pairs of a view growing with the model, from about 0.3 to 0.86 million, which uses more of the planned pair buffer. An autorelease pool around each iteration now releases its Metal command buffers at once; the training thread has no run loop to do it. It lowered the Standard peak from 1,005 to 991 MB. Before that pool, the High preset (1,000,000 Gaussians) peaked at 1,770 MB during growth, above its 1,531 MB plan; it was not measured again with the pool. On an iPhone, memory warnings still freeze growth and critical pressure still pauses the run with a checkpoint.

## Learning after the Gaussian cap

With plain MRNF, a Standard run of FBDA13 reached its 600,000-Gaussian cap by iteration 1,000 of 7,000. From then on MRNF only refills the slots it soft-prunes, about 8,500 per refine (1.4%), by splitting opaque Gaussians. A fixed count does not mean the model stopped learning: its parameters keep improving, and training-view PSNR rose from 22.6 dB at the cap to 29.6 dB at the end. What limits detail is the number of optimisation steps, not the number of slots:

| FBDA13 (every 8th photo held out) | 7,000 iterations | 10,000 iterations |
| --- | --- | --- |
| MRNF, 600,000 cap | 29.10 dB | 29.93 dB |
| With the growth ramp (default) | 29.12 dB | 30.04 dB |
| Growth ramp, 800,000 cap | 29.11 dB | 29.87 dB |
| Growth ramp and evidence-based relocation | 29.09 dB | 29.85 dB |

- **Growth ramp (on).** The Gaussian count may rise only linearly, from the seeded count to the cap at the end of the growth phase. New Gaussians are then placed by error statistics from a model that already fits the scene, instead of by the first, coarse errors. It gains 0.02–0.1 dB, leaves fewer held-out pixels empty (2.43% → 2.07% at 7,000 iterations, 1.85% → 1.73% at 10,000), and makes the first half faster. Checkpoints written before it resume without it.
- **A larger cap does not help.** 800,000 Gaussians scored the same or lower, and cost memory and time.
- **Evidence-based relocation (experimental, off).** It moves slots within the cap, from Gaussians the photos show are wasted to those they show are under-fit:
  - it judges a Gaussian only when at least three views of the refine window reached it;
  - donors blend less than 2% of the median Gaussian's weight per view, in two consecutive windows (hidden or redundant);
  - receivers cover pixels whose error stays above the image mean across those views, and are split like MRNF parents;
  - at most 0.5% of the Gaussians move per refine, tapering to zero at the end of refinement, and nothing moves without receivers.

  About 1,500–2,500 Gaussians moved per refine, yet held-out PSNR fell by 0.03–0.19 dB. MRNF's own refill already moves 1.4% per refine, and a Gaussian hidden in the window's views can still matter for another view. `tools/train_gaussians.swift --relocate` runs it.
- **Other attempts that lost quality:**
  - Adam only on the Gaussians the view reached ("sparse" or "visible" Adam): −0.15 dB, although it saved 3.5 ms per iteration.
  - Refilling pruned slots by splitting the highest-error Gaussians instead of opaque ones: −0.43 dB.

## Training resolution and a stricter held-out test

The replays above score held-out views at the training resolution, after downscaling the photo, and hold out every 8th photo. Both flatter the model. Two options in `tools/train_gaussians.swift` test it harder:

- **`--eval-full-res`** scores the aligned held-out views at the photos' own 1,920 × 1,440, so detail the training resolution cannot hold counts against the model.
- **`--holdout-segment 0.1`** holds out the middle 10% of the trajectory as one stretch instead of every 8th photo, and prints each held-out view's PSNR against its distance from the nearest training camera. With every 8th photo held out, a held-out view sits a few centimetres from training views on both sides, so the score measures interpolation.

All runs use the Standard preset of the time (7,000 iterations, 600,000 Gaussians, before the growth ramp) with PPISP off, and PSNR / SSIM after test-time alignment:

| Scan, held out | Trained at | At training resolution | At 1,920 × 1,440 | Peak footprint |
| --- | --- | --- | --- | --- |
| FBDA13, every 8th | 960 px | 29.09 / 29.15 dB | 28.93 / 28.99 dB, SSIM 0.913 | 875 MB |
| FBDA13, every 8th | 1,440 px | 29.11 dB | 28.99 dB, SSIM 0.914 | 1,007 MB |
| FBDA13, every 8th | 1,920 px | 28.95 dB | 28.95 dB, SSIM 0.913 | 1,329 MB |
| 7F2187, every 8th | 960 px | 25.96 dB | 25.82 dB, SSIM 0.865 | 904 MB |
| 7F2187, every 8th | 1,920 px | 25.80 dB | 25.80 dB, SSIM 0.864 | 1,346 MB |
| FBDA13, middle 10% | 960 / 1,440 / 1,920 px | 16.23 / 16.25 / 16.12 dB | 16.24 / 16.24 / 16.12 dB | 910 / 1,007 / 1,338 MB |
| 7F2187, middle 10% | 960 / 1,920 px | 16.75 / 16.75 dB | 16.73 / 16.75 dB | 937 / 1,343 MB |

Two runs of the same settings differ by about 0.05 dB.

- **Full resolution buys no measurable quality on these scans.** At 1,920 × 1,440, models trained at 960, 1,440, and 1,920 px score within the run-to-run spread on both scans. Scoring at full resolution costs the 960 px model only 0.16 dB, so the photos hold little detail beyond it. At a median 30–35°/s, an 8.3 ms exposure smears about 6 px at full resolution. The High (original) choice remains for slow, sharp captures, which were not measured.
- **More training helps more than more pixels.** The 960 px FBDA13 model enhanced by 3,000 iterations reached 29.48 dB at 960 px and 29.53 dB at 1,920 px (SSIM 0.916 and 0.917), about 0.5 dB above both the base model and the 1,920 px run.
- **Views away from the capture path are much worse.** Holding out the middle of the path drops aligned PSNR to 16–17 dB on both scans at every resolution. The per-view report shows why:
  - FBDA13's middle views turned about 100° towards a part of the room that no other stretch sees from nearby. Its held-out views fall from 23.7 dB two centimetres from a training camera to 11.5 dB in the middle, and 9% of their pixels stay empty.
  - 7F2187 is close range (1–2 m). Its nearest similar training views are 0.1–0.5 m away, which already changes the viewpoint a lot. Held-out views within 0.1 m of a training camera average 21.0 dB, and the rest 16.3 dB.

  This is a coverage limit: the model cannot show what no training photo saw. The seed cloud (`review.ply`) was fused from all photos, including the held-out stretch, so the segment scores are, if anything, optimistic.

## Validation

Measured on the Mac GPU with the same Metal source:

- **`tools/test_gaussian_raster.swift`:** forward against a double-precision reference, with parameter and pose gradients checked by finite differences. It covers the Mip filter on and off, with and without capture motion and the LiDAR depth loss, and shows that the banded backward pass matches the single pass (20 checks).
- **`tools/test_gaussian_loss.swift`:** loss, image and PPISP gradients.
- **`tools/test_gaussian_training.swift`:** 65 end-to-end checks.
  - Memory-plan fitting and overflow checks; resolution tiers, the full-resolution plan, tile bands, and the held-out segment.
  - MRNF units, the growth ramp and its ceiling, relocation (evidence, rate, taper, no receivers), PLY export frame, and convergence.
  - SOG: lossless WebP texels through ImageIO, stored ZIP archives against `unzip` and `zip`, palette and texture sizes, and a trained SH 3 model written and read back (positions within 0.04 mm, rotations 0.6°, rendering within 0.1 dB).
  - PPISP exposure recovery, pose refinement, and capture motion.
  - Cap under a small budget; checkpoint exactness, corruption, atomic replacement, and resuming a version 1 checkpoint. Leaving the app saves a checkpoint while training continues, and stale partial files are removed.
  - The session state machine: pause, stop, interrupt, and resume.
  - Enhance model: a saved SOG model reloads with its poses and renders within 0.5 dB of the trained one, and a PLY model exactly (also with a raised SH degree); it continues its schedule and replaces the model only on completion. Finish and save model from a pause.
  - The saved-model viewer, both archives, and a 1,200-frame run within the plan.
- **Real scans:** alone on the Mac, the Standard preset (10,000 iterations) took 5.3 minutes on FBDA13, with a peak process footprint of 0.99 GB against a 1.04 GB plan. For the High preset see [memory](#speed-and-longer-presets).
- **Simulator (iPhone 16 Pro; iPhone 17 Pro on iOS 26.3):** covered the user flow only.
  - Setup, live viewer, completion, and the History card after relaunch.
  - Resume after the app was killed.
  - A background pause with checkpoint.
  - The resolution switcher, training on while browsing the app, and the home status line.
  - Finish and save model from a running resume; Enhance model setup at High (original), its start from the saved iteration, and stopping it with *delete*, which left the saved model unchanged.
  - The Simulator reports no background GPU, so only the pause fallback of background training ran.

**Not yet measured on an iPhone:** training speed, peak memory, and thermal behaviour. Mac and Simulator numbers say nothing about phone memory safety or timing.

## Provenance and licences

The trainer is part of this personal research project, which is not a product of or endorsed by any employer or organisation. It is licensed under the [Apache License 2.0](../LICENSE): it may be used commercially, and copies and derivative works must keep [NOTICE](../NOTICE) and credit Kuo Feng-Yuan (KuoFengYuan) as the author. Third-party patents may cover some methods; this is not legal advice.


- **Code:** no LichtFeld Studio (GPL-3.0) source code is included. Only its published algorithms and default parameters were followed: MRNF, the PPISP integration, and the Mip filter settings.
- **PPISP:** implements the formulation described by nv-tlabs/ppisp.
- **Methods:**
  - Mip-Splatting (Yu et al., 2024) and 3D Gaussian Splatting (Kerbl et al., 2023);
  - capture motion after Seiskari et al. (2024);
  - the SOG file format as described in the PlayCanvas documentation; the WebP encoder, ZIP handling and k-means are this project's own;
  - exact tile spans after the precise tile intersection of Speedy-Splat (Hanson et al., 2025), derived and implemented here as a per-row ellipse span;
  - the visible-only Adam experiment after the sparse Adam of Taming 3DGS (Mallick et al., 2024). The growth ramp is similar in spirit to Taming 3DGS's budgeted densification, and the relocation experiment to the relocation of 3DGS-MCMC (Kheradmand et al., 2024).
- **This project's own additions to the MRNF base:** pose refinement with a per-view rate, seed spread, LiDAR depth seeds, hole filling, the LiDAR depth loss, the growth ramp, evidence-based relocation, the transposed SIMD reduction in the backward pass, and the longer presets.
- **Pose refinement:** LichtFeld Studio documents a direct pose-optimisation mode without shipping code for it, so the mode here was implemented from that description.

## Limits

- Capture motion is experimental.
  - Velocities come from poses about 0.1 s apart, not from the IMU.
  - The rolling-shutter readout time of the iPhone video format is not published; a fixed value is used.
- Pose refinement shifts training cameras by millimetres. Held-out views on raw ARKit poses therefore score lower without test-time alignment. This does not affect orbit viewing.
- The PPISP exposure controller is not implemented, and novel views use neutral exposure and colour.
- One scan trains at a time. Background training needs iOS 26, device support, and the Background GPU Access capability; otherwise switching apps pauses the run.
- Full-resolution (1,920 px) training has only been run on the Mac. Its speed, memory, and heat on an iPhone are not measured.
