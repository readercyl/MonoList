#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT_DIR/build/tests"
swiftc -parse-as-library \
  "$ROOT_DIR/MonoList/Tasks/TaskItem.swift" \
  "$ROOT_DIR/MonoList/Tasks/TaskStore.swift" \
  "$ROOT_DIR/MonoList/Shared/AtomicFileWriter.swift" \
  "$ROOT_DIR/MonoList/Shared/AppError.swift" \
  "$ROOT_DIR/Tests/TaskCLISmoke.swift" \
  -o "$ROOT_DIR/build/tests/TaskCLISmoke"
"$ROOT_DIR/build/tests/TaskCLISmoke"
