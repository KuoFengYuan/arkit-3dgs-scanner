#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
# On-device 3DGS training: kernel gradients, loss/PPISP gradients and end-to-end training tests.
# Runs the app's Metal kernels on the Mac GPU (same source; not a substitute for iPhone runs).
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/gaussian-training.XXXXXX")
trap 'rm -rf "$work"' EXIT
cache="${TMPDIR:-/tmp}/fable-swift-cache"
T=arkit-3dgs-scanner/Training
C=arkit-3dgs-scanner/Capture
xcrun -sdk macosx metal -std=metal3.1 -ffast-math $T/*.metal -o "$work/gs.metallib"
swiftc -O -module-cache-path "$cache" $C/Localization.swift \
  $T/{GaussianMetal,GaussianSorter,GaussianRasterizer}.swift tools/test_gaussian_raster.swift -o "$work/raster"
"$work/raster" "$work/gs.metallib"
swiftc -O -module-cache-path "$cache" $C/Localization.swift \
  $T/{GaussianMetal,GaussianSorter,GaussianRasterizer,GaussianLoss,PPISP}.swift tools/test_gaussian_loss.swift -o "$work/loss"
"$work/loss" "$work/gs.metallib"
swiftc -O -module-cache-path "$cache" \
  $C/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,ExportManager,TrainingFrameSelector}.swift \
  arkit-3dgs-scanner/History/ScanLibrary.swift $T/*.swift tools/test_gaussian_training.swift -o "$work/training"
"$work/training" "$work/gs.metallib"
# The real-scan harness must keep compiling.
swiftc -O -module-cache-path "$cache" \
  $C/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,ExportManager,TrainingFrameSelector}.swift \
  arkit-3dgs-scanner/History/ScanLibrary.swift $T/*.swift tools/train_gaussians.swift -o "$work/train_gaussians"
usage=$("$work/train_gaussians" 2>&1 || true)
[[ "$usage" == "Usage: train_gaussians "* ]] || { echo "FAIL: train_gaussians usage"; exit 1; }
echo "PASS: train_gaussians builds and prints usage"
