#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/Veil.app/Contents/{MacOS,Resources} build/module-cache
cargo build --release --locked
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx14.0" -module-cache-path build/module-cache -import-objc-header core/include/veil.h Sources/Veil/*.swift -L target/release -lveil_core -o build/Veil.app/Contents/MacOS/Veil
cp Resources/Info.plist build/Veil.app/Contents/Info.plist
codesign --force --sign - build/Veil.app
