#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/pose-refinement.XXXXXX")
trap 'rm -rf "$work"' EXIT
cache="${TMPDIR:-/tmp}/fable-swift-cache"
C=arkit-3dgs-scanner/Capture
# Solver and feature tests use minimal stubs instead of the app models.
swiftc -O -module-cache-path "$cache" $C/PoseRefiner.swift $C/BundleAdjuster.swift \
  tools/test_bundle_adjust.swift tools/test_stubs_core.swift tools/test_stubs_ba.swift -o "$work/bundle_adjust"
"$work/bundle_adjust"
swiftc -O -module-cache-path "$cache" $C/FeatureTracker.swift $C/BundleAdjuster.swift $C/PoseRefiner.swift \
  tools/test_feature_index.swift tools/test_stubs_core.swift -o "$work/feature_index"
"$work/feature_index"
swiftc -O -module-cache-path "$cache" \
  $C/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,TrainingFrameSelector,PhotometricPoseValidator}.swift \
  tools/test_photometric_validation.swift -o "$work/photometric_validation"
"$work/photometric_validation"
