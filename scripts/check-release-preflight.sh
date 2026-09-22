#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECKS=(
  check-task-store.sh
  check-task-drop-coordinator.sh
  check-app-settings.sh
  check-ui-source-style.sh
  check-reminder-scheduler.sh
  check-menu-bar-bridge.sh
  check-window-coordinator.sh
  check-project-integrity.sh
  check-app-updater.sh
  check-update-installer.sh
)

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/monolist-release-checks.XXXXXX")"
PIDS=()

cleanup() {
  rm -rf "$LOG_DIR"
}
trap cleanup EXIT

for check in "${CHECKS[@]}"; do
  bash "$ROOT_DIR/scripts/$check" >"$LOG_DIR/$check.log" 2>&1 &
  PIDS+=("$!")
done

failed=0
for index in "${!PIDS[@]}"; do
  if ! wait "${PIDS[$index]}"; then
    failed=1
    printf '发布前检查失败：%s\n' "${CHECKS[$index]}" >&2
    cat "$LOG_DIR/${CHECKS[$index]}.log" >&2
  fi
done

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "Release preflight checks passed."
