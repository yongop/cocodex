#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
# Compile the real core sources with the checks: runs on Command Line Tools alone.
swiftc -swift-version 6 -parse-as-library \
  Sources/CocountCore/*.swift Tests/CocountCoreTests/*.swift \
  -o .build/checks/CocountChecks
.build/checks/CocountChecks

# Exercise the actual store's async scheduling with a fake provider and an isolated log root.
CHECK_MODULE_DIR="$PWD/.build/checks/store"
mkdir -p "$CHECK_MODULE_DIR"
swiftc -swift-version 6 -parse-as-library -emit-module -emit-library \
  -module-name CocountCore Sources/CocountCore/*.swift \
  -emit-module-path "$CHECK_MODULE_DIR/CocountCore.swiftmodule" \
  -o "$CHECK_MODULE_DIR/libCocountCore.dylib"
swiftc -swift-version 6 -parse-as-library \
  -I "$CHECK_MODULE_DIR" -L "$CHECK_MODULE_DIR" -lCocountCore \
  -Xlinker -rpath -Xlinker "$CHECK_MODULE_DIR" \
  Sources/Cocount/UsageStore.swift Sources/Cocount/Design/ThemePreset.swift \
  Tests/CocountStoreTests/*.swift -o "$CHECK_MODULE_DIR/CocountStoreChecks"
"$CHECK_MODULE_DIR/CocountStoreChecks"
