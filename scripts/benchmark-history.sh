#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -O -swift-version 6 -parse-as-library \
  Sources/CocountCore/*.swift Benchmarks/DailyHistory.swift \
  -o .build/checks/CocountDailyHistoryPerformance
.build/checks/CocountDailyHistoryPerformance
