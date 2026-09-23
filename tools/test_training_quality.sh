#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/arkit-quality.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
swiftc -O -module-cache-path "${TMPDIR:-/tmp}/arkit-swift-module-cache" \
  arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,ExportManager,TrainingFrameSelector,OfflinePoseRefinement,LocalSurfaceRefiner,LoopClosureRefiner,FeatureTracker,BundleAdjuster,PoseRefiner,PhotometricPoseValidator}.swift \
  arkit-3dgs-scanner/History/{ScanLibrary,ScanLibrary+Optimization}.swift \
  tools/test_training_quality.swift -o "$test_dir/test_training_quality"
"$test_dir/test_training_quality"
