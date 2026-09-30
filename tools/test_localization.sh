#!/bin/bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). See LICENSE and NOTICE.
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/arkit-localization.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
swiftc -O -module-cache-path "${TMPDIR:-/tmp}/arkit-swift-module-cache" \
  arkit-3dgs-scanner/Capture/{Localization,FloorPlanData,FloorPlanDrawing}.swift \
  tools/test_localization.swift -o "$test_dir/test_localization"
"$test_dir/test_localization" "$PWD/arkit-3dgs-scanner"
