#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=14.0
cargo test --release --locked
mkdir -p build/module-cache
common=(-swift-version 5 -O -whole-module-optimization -target "$(uname -m)-apple-macosx14.0" -module-cache-path build/module-cache)
swiftc "${common[@]}" Sources/Veil/Geometry.swift Sources/Veil/MaskTracker.swift Tests/native.swift -o build/native-tests
build/native-tests
swiftc "${common[@]}" -D FEED_TEST_MAIN Sources/Veil/{Geometry,Feed,Settings}.swift Tests/FeedTests.swift -o build/feed-tests
build/feed-tests
