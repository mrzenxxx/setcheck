#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# The Command Line Tools distribution ships Swift Testing, but not XCTest.
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$PWD/.build/swift-cache}"
frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
if [[ -d "$frameworks/Testing.framework" ]]; then
    swift test --disable-sandbox --disable-xctest --enable-swift-testing \
        -Xswiftc -F -Xswiftc "$frameworks" \
        -Xlinker -rpath -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker "$(xcode-select -p)/Library/Developer/usr/lib" "$@"
else
    swift test --disable-sandbox "$@"
fi
