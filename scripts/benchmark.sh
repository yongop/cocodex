#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -O -swift-version 6 -parse-as-library \
  Sources/CocountCore/*.swift Benchmarks/Performance.swift \
  -o .build/checks/CocountPerformance
.build/checks/CocountPerformance
