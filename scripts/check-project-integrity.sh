#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if git -C "$ROOT_DIR" ls-files | grep -qE '(^|/)\.DS_Store$'; then
  echo "仓库中不能跟踪 .DS_Store。" >&2
  exit 1
fi

for path in MonoList MenuBarHelper Tests scripts docs release-notes; do
  [[ -d "$ROOT_DIR/$path" ]] || {
    echo "缺少项目目录：$path" >&2
    exit 1
  }
done

required_files=(
  "$ROOT_DIR/Tests/AppLaunchSmoke.swift"
  "$ROOT_DIR/Tests/AppSettingsSmoke.swift"
  "$ROOT_DIR/Tests/AppUpdaterSmoke.swift"
  "$ROOT_DIR/Tests/MenuBarBridgeSmoke.swift"
  "$ROOT_DIR/Tests/ReminderSchedulerSmoke.swift"
  "$ROOT_DIR/Tests/TaskDropCoordinatorSmoke.swift"
  "$ROOT_DIR/Tests/TaskStoreSmoke.swift"
  "$ROOT_DIR/Tests/UpdateInstallerSmoke.swift"
  "$ROOT_DIR/Tests/WindowCoordinatorSmoke.swift"
  "$ROOT_DIR/scripts/build-local.sh"
  "$ROOT_DIR/scripts/package-dmg.sh"
  "$ROOT_DIR/scripts/release.sh"
  "$ROOT_DIR/scripts/cleanup-build.sh"
  "$ROOT_DIR/scripts/migrate-tasks-schema1.sh"
)

for file in "${required_files[@]}"; do
  [[ -f "$file" ]] || {
    echo "缺少项目文件：$file" >&2
    exit 1
  }
done

if ! rg -q 'BUILD_FLAVOR=.*development' "$ROOT_DIR/scripts/build-local.sh" ||
   ! rg -q 'MonoList 开发版\.app' "$ROOT_DIR/scripts/build-local.sh" ||
   ! rg -q 'com\.qingcheng\.monolist\.dev' "$ROOT_DIR/scripts/build-local.sh"; then
  echo "直接构建必须生成与正式版明确区分的 MonoList 开发版。" >&2
  exit 1
fi

if ! rg -q 'MONOLIST_BUILD_FLAVOR=release' "$ROOT_DIR/scripts/package-dmg.sh" ||
   ! rg -q 'com\.qingcheng\.monolist\.mac' "$ROOT_DIR/scripts/build-local.sh"; then
  echo "正式打包必须显式使用 MonoList release 身份。" >&2
  exit 1
fi

if rg -q 'open[[:space:]].*build/local/MonoList\.app' "$ROOT_DIR/README.md"; then
  echo "README 不能引导直接启动未区分身份的开发构建。" >&2
  exit 1
fi

while IFS= read -r script_path; do
  [[ -f "$ROOT_DIR/$script_path" ]] || {
    echo "README 或发布流程引用了不存在的脚本：$script_path" >&2
    exit 1
  }
done < <(
  rg -o --no-filename 'scripts/[A-Za-z0-9._-]+\.sh' \
    "$ROOT_DIR/README.md" \
    "$ROOT_DIR/scripts/release.sh" |
    sort -u
)

package_line="$(
  rg -n 'bash scripts/package-dmg\.sh' "$ROOT_DIR/scripts/release.sh" |
    head -n 1 |
    cut -d: -f1
)"
launch_line="$(
  rg -n 'bash scripts/check-app-launch\.sh' "$ROOT_DIR/scripts/release.sh" |
    head -n 1 |
    cut -d: -f1
)"
if [[ -z "$package_line" || -z "$launch_line" || "$package_line" -ge "$launch_line" ]]; then
  echo "发布流程必须先构建最终 App，再执行 App 启动检查。" >&2
  exit 1
fi

if ! rg -q -- "-name '\\*.app'" "$ROOT_DIR/scripts/cleanup-build.sh"; then
  echo "清理脚本必须删除 build 中的测试 App，避免污染 Spotlight。" >&2
  exit 1
fi

echo "Project integrity check passed."
