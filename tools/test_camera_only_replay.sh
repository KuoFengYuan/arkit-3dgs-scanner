#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/camera-only-replay.XXXXXX")
trap 'rm -rf "$work"' EXIT
cache="${TMPDIR:-/tmp}/fable-swift-cache"
C=arkit-3dgs-scanner/Capture
# Metrics tests; the replay CLI itself is compiled too, so its sources cannot silently rot.
swiftc -O -module-cache-path "$cache" \
  $C/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF}.swift \
  tools/camera_only_metrics.swift tools/test_camera_only_replay.swift -o "$work/camera_only_replay_test"
"$work/camera_only_replay_test"
swiftc -O -module-cache-path "$cache" \
  $C/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,TrainingFrameSelector,PhotometricPoseValidator,RGBStereoMatcher,RGBReconstructionEngine}.swift \
  tools/camera_only_metrics.swift tools/replay_camera_only.swift -o "$work/replay_camera_only"
usage=$("$work/replay_camera_only" 2>&1 || true)
[[ "$usage" == "Usage: replay_camera_only "* ]] || { echo "FAIL: replay_camera_only usage"; exit 1; }
echo "PASS: replay_camera_only builds and prints usage"
