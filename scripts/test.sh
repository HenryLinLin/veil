#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=14.0
cargo test --release --locked
mkdir -p build/module-cache
common=(-swift-version 5 -O -whole-module-optimization -target "$(uname -m)-apple-macosx14.0" -module-cache-path build/module-cache)
swiftc "${common[@]}" Sources/Veil/Geometry.swift Sources/Veil/MaskTracker.swift Sources/Veil/ContentChanges.swift Tests/native.swift -o build/native-tests
build/native-tests
swiftc "${common[@]}" -D FEED_TEST_MAIN Sources/Veil/{Geometry,Feed,Settings}.swift Tests/FeedTests.swift -o build/feed-tests
build/feed-tests
swiftc "${common[@]}" Sources/Veil/TextMaskTracker.swift Tests/TrackingTests.swift -o build/tracking-tests
build/tracking-tests
swiftc "${common[@]}" Sources/Veil/TextMaskTracker.swift Tests/RenderedTextTests.swift -o build/rendered-text-tests
build/rendered-text-tests
swiftc "${common[@]}" Sources/Veil/Geometry.swift Sources/Veil/Accessibility.swift Tests/AXBoundsTests.swift -o build/ax-bounds-tests
build/ax-bounds-tests
swiftc "${common[@]}" Sources/Veil/{Geometry,TextMaskTracker,Capture}.swift Tests/CaptureTests.swift -o build/capture-tests
build/capture-tests
