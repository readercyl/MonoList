#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/tests"
TEST_EXECUTABLE="$BUILD_DIR/WindowCoordinatorSmoke"

mkdir -p "$BUILD_DIR"

swiftc \
  -parse-as-library \
  "$ROOT_DIR/MonoList/App/WindowCoordinator.swift" \
  "$ROOT_DIR/MonoList/Tasks/TaskItem.swift" \
  "$ROOT_DIR/MonoList/Tasks/TaskStore.swift" \
  "$ROOT_DIR/MonoList/Tasks/TaskDropCoordinator.swift" \
  "$ROOT_DIR/MonoList/Tasks/TaskListView.swift" \
  "$ROOT_DIR/MonoList/Tasks/HomeView.swift" \
  "$ROOT_DIR/MonoList/Tasks/TaskDraftState.swift" \
  "$ROOT_DIR/MonoList/Tasks/TaskTextEditor.swift" \
  "$ROOT_DIR/MonoList/Tasks/TaskRowView.swift" \
  "$ROOT_DIR/MonoList/Tasks/HistoryView.swift" \
  "$ROOT_DIR/MonoList/Tasks/DataRecoveryView.swift" \
  "$ROOT_DIR/MonoList/Settings/AppSettings.swift" \
  "$ROOT_DIR/MonoList/Settings/SettingsView.swift" \
  "$ROOT_DIR/MonoList/Settings/LoginItemController.swift" \
  "$ROOT_DIR/MonoList/Reminder/ReminderScheduler.swift" \
  "$ROOT_DIR/MonoList/Update/AppUpdater.swift" \
  "$ROOT_DIR/MonoList/Shared/AtomicFileWriter.swift" \
  "$ROOT_DIR/MonoList/Shared/AppError.swift" \
  "$ROOT_DIR/MonoList/Shared/MonoListLogoView.swift" \
  "$ROOT_DIR/Tests/WindowCoordinatorSmoke.swift" \
  -o "$TEST_EXECUTABLE"

"$TEST_EXECUTABLE"
