#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/fusion-memory.XXXXXX")
trap 'rm -rf "$work"' EXIT
sources=(arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,PointCloudFusion}.swift)
for test in test_fusion_memory_pressure test_stop_processing test_fusion_export test_large_scan_memory test_lidar_consistency; do
    swiftc -O -module-cache-path /tmp/fable-swift-cache "${sources[@]}" "tools/$test.swift" -o "$work/$test"
    "$work/$test"
done
