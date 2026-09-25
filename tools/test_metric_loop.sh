#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/metric-loop.XXXXXX")
trap 'rm -rf "$work"' EXIT
sources=(arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,ExportManager,TrainingFrameSelector,OfflinePoseRefinement,LocalSurfaceRefiner,LoopClosureRefiner,RevisitGuide,FeatureTracker,BundleAdjuster,PoseRefiner,PhotometricPoseValidator,SceneMetricScale}.swift arkit-3dgs-scanner/History/{ScanLibrary,ScanLibrary+Metrics}.swift)
for test in test_loop_closure test_revisit_tracks test_revisit_guide test_metric_scale; do
  swiftc -O -module-cache-path /tmp/fable-swift-cache "${sources[@]}" "tools/$test.swift" -o "$work/$test"
  "$work/$test"
done
