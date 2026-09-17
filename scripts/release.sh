#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${MONOLIST_APP_VERSION:-}"
MODE="${1:-}"
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "必须提供 MONOLIST_APP_VERSION=vX.Y.Z。" >&2
  exit 1
}

NOTES_PATH="release-notes/$VERSION.md"
DMG_PATH="build/release/MonoList-$VERSION.dmg"
[[ -f "$NOTES_PATH" ]] || {
  echo "缺少中文发布说明：$NOTES_PATH" >&2
  exit 1
}

if [[ "$MODE" == "--publish" ]]; then
  gh release view "$VERSION" --json isDraft,tagName >/dev/null
  gh release edit "$VERSION" --draft=false --latest
  echo "已公开 Release：$VERSION"
  exit 0
fi

[[ -z "$(git status --porcelain)" ]] || {
  echo "发布前工作树必须干净。" >&2
  exit 1
}
if git rev-parse "$VERSION" >/dev/null 2>&1; then
  echo "Tag 已存在：$VERSION" >&2
  exit 1
fi

bash scripts/check-task-store.sh
bash scripts/check-focus-store.sh
bash scripts/check-task-drop-coordinator.sh
bash scripts/check-app-settings.sh
bash scripts/check-ui-source-style.sh
bash scripts/check-reminder-scheduler.sh
bash scripts/check-menu-bar-bridge.sh
bash scripts/check-window-coordinator.sh
bash scripts/check-project-integrity.sh
bash scripts/check-app-updater.sh
bash scripts/check-update-installer.sh
MONOLIST_APP_VERSION="$VERSION" bash scripts/package-dmg.sh >/dev/null
bash scripts/check-app-launch.sh \
  build/local/MonoList.app \
  com.qingcheng.monolist.mac \
  com.qingcheng.monolist.menubar.v2 \
  MonoList
bash scripts/check-release-signature.sh
bash scripts/check-dmg-layout.sh "$DMG_PATH"

if [[ "$MODE" == "--dry-run" ]]; then
  bash scripts/cleanup-build.sh
  echo "Release dry run passed: $VERSION"
  exit 0
fi

git tag "$VERSION"
git push origin HEAD:main
git push origin "$VERSION"
gh release create "$VERSION" "$DMG_PATH" \
  --draft \
  --title "$VERSION" \
  --notes-file "$NOTES_PATH"
bash scripts/cleanup-build.sh
echo "Draft Release 已创建：$VERSION"
