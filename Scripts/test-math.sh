#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="${TMPDIR:-/tmp}/boxdepth-math-tests"
mkdir -p "$build_dir"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -module-cache-path "$build_dir/module-cache" BoxDepth/SpatialMath.swift Tests/main.swift -o "$build_dir/test-math"
"$build_dir/test-math"
