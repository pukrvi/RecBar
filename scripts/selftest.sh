#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release --product RecBar
BIN="$(swift build -c release --show-bin-path)/RecBar"
"$BIN" --selftest
"$BIN" --selftest-recovery
