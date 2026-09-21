#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TASK_LIST="$ROOT_DIR/MonoList/Tasks/TaskListView.swift"
HOME_VIEW="$ROOT_DIR/MonoList/Tasks/HomeView.swift"
TASK_ROW="$ROOT_DIR/MonoList/Tasks/TaskRowView.swift"
WINDOW_COORDINATOR="$ROOT_DIR/MonoList/App/WindowCoordinator.swift"
SETTINGS="$ROOT_DIR/MonoList/Settings/SettingsView.swift"
APP_SETTINGS="$ROOT_DIR/MonoList/Settings/AppSettings.swift"

for source in "$TASK_LIST" "$HOME_VIEW" "$TASK_ROW" "$WINDOW_COORDINATOR"; do
  if grep -qE '今日专注|短期任务|长期任务|focusStore|focusSection|focusPicker' "$source"; then
    echo "当前任务界面不能保留专注或短期/长期分类入口：$source" >&2
    exit 1
  fi
done

for source in "$TASK_LIST" "$HOME_VIEW" "$TASK_ROW"; do
  if grep -q 'chevron.right' "$source"; then
    echo "一级任务展开不能再使用左侧箭头：$source" >&2
    exit 1
  fi
done

if ! grep -q 'priorityRank' "$TASK_ROW" ||
   ! grep -q 'case 0: return 18' "$TASK_ROW" ||
   ! grep -q 'case 1: return 16' "$TASK_ROW" ||
   ! grep -q 'case 2: return 14' "$TASK_ROW"; then
  echo "前三条待办必须使用从大到小的字号层级。" >&2
  exit 1
fi

if ! grep -q 'width: indentationLevel == 0 ? 0 : 20' "$TASK_LIST" ||
   ! grep -q 'width: indentationLevel == 0 ? 0 : 20' "$HOME_VIEW"; then
  echo "主页和浮窗草稿行必须复用一级/二级待办的行首对齐规则。" >&2
  exit 1
fi

if ! grep -q 'olderCompletedGroups' "$TASK_LIST" ||
   ! grep -q 'olderCompletedGroups' "$HOME_VIEW"; then
  echo "主页和浮窗都必须保留已完成任务的日期归类。" >&2
  exit 1
fi

if ! grep -q 'Text("今天")' "$TASK_LIST" ||
   ! grep -q 'Text("今天")' "$HOME_VIEW"; then
  echo "主页和浮窗标题必须显示今天和日期。" >&2
  exit 1
fi

if ! grep -q '@State private var showsOlderCompleted = true' "$TASK_LIST" ||
   ! grep -q '@State private var showsOlderCompleted = true' "$HOME_VIEW"; then
  echo "主页和浮窗已完成任务必须默认展开。" >&2
  exit 1
fi

if grep -q 'systemName: "xmark"' "$TASK_LIST"; then
  echo "菜单栏浮窗右上角不能再显示独立关闭按钮。" >&2
  exit 1
fi

if ! grep -q 'visibleCompletedTasks' "$TASK_LIST" ||
   ! grep -q 'onChange(of: showsOlderCompleted)' "$TASK_LIST"; then
  echo "浮窗隐藏历史记录后必须按可见内容重新计算窗口高度。" >&2
  exit 1
fi

if ! grep -q '声音类型' "$SETTINGS" ||
   [[ "$(grep -c 'reminderSoundEnabled' "$SETTINGS")" -lt 2 ]]; then
  echo "提醒开关和声音开关必须拆分，声音类型单独选择。" >&2
  exit 1
fi

if ! grep -q 'SettingsView(' "$HOME_VIEW" ||
   grep -q 'private var settingsWindow' "$WINDOW_COORDINATOR"; then
  echo "设置必须内置主页，不能再创建独立设置窗口。" >&2
  exit 1
fi

if ! grep -q 'homeWindow: self.homeWindow' "$WINDOW_COORDINATOR"; then
  echo "菜单栏浮窗外点判断必须覆盖主页窗口。" >&2
  exit 1
fi

if ! grep -q 'reminderSoundEnabled: Bool? = false' "$APP_SETTINGS" ||
   ! grep -q ') ?? false' "$APP_SETTINGS"; then
  echo "提醒声音默认值必须是关闭。" >&2
  exit 1
fi

if grep -q 'NSComboBox' "$SETTINGS" ||
   ! grep -q 'SettingsSwitchStyle' "$SETTINGS" ||
   ! grep -q 'SettingValueBackground' "$SETTINGS"; then
  echo "设置页控件必须保留统一原生样式。" >&2
  exit 1
fi

echo "UI source style check passed."
