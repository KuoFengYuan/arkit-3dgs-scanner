#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/surface-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
sources=(arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,LocalSurfaceRefiner,TrainingFrameSelector}.swift)
swiftc -O -module-cache-path /tmp/fable-swift-cache "${sources[@]}" tools/test_surface_reconstruction.swift -o "$work/test"
"$work/test" "$@"
