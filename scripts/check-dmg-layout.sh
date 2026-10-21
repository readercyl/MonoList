#!/usr/bin/env bash
set -euo pipefail

INPUT_PATH="${1:?请提供 DMG 或 staging 目录路径}"
MOUNT_DIR=""

cleanup() {
  if [[ -n "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
    rm -rf "$MOUNT_DIR"
  fi
}
trap cleanup EXIT

if [[ -f "$INPUT_PATH" ]]; then
  hdiutil verify "$INPUT_PATH" >/dev/null
  MOUNT_DIR="$(mktemp -d)"
  hdiutil attach "$INPUT_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIR" >/dev/null
  ROOT="$MOUNT_DIR"
else
  ROOT="$INPUT_PATH"
fi

[[ -d "$ROOT/MonoList.app" ]] || {
  echo "DMG 中缺少 MonoList.app" >&2
  exit 1
}
[[ -L "$ROOT/Applications" ]] || {
  echo "DMG 中缺少 Applications 快捷方式" >&2
  exit 1
}
[[ "$(readlink "$ROOT/Applications")" == "/Applications" ]] || {
  echo "Applications 快捷方式目标不正确" >&2
  exit 1
}

CLI_LAUNCHER="$ROOT/MonoList.app/Contents/MacOS/monolist-cli"
[[ -x "$CLI_LAUNCHER" ]] || {
  echo "安装包中缺少可执行 CLI 入口" >&2
  exit 1
}
"$CLI_LAUNCHER" help >/dev/null

echo "DMG layout and bundled CLI check passed."
