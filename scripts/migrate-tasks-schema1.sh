#!/usr/bin/env bash
set -euo pipefail

SOURCE_PATH="${1:?请提供 tasks.json 路径}"
OUTPUT_PATH="${2:-$SOURCE_PATH}"

[[ -f "$SOURCE_PATH" ]] || {
  echo "缺少任务数据文件：$SOURCE_PATH" >&2
  exit 1
}

schema_version="$(jq -r '.schemaVersion // empty' "$SOURCE_PATH")"
[[ "$schema_version" == "2" ]] || {
  echo "只允许迁移 schema 2，当前为：$schema_version" >&2
  exit 1
}

child_count="$(jq '[.tasks[] | select(.parentID != null)] | length' "$SOURCE_PATH")"
[[ "$child_count" == "0" ]] || {
  echo "存在子任务，不能降级为 schema 1：$child_count 条" >&2
  exit 1
}

output_dir="$(dirname "$OUTPUT_PATH")"
temporary_path="$(mktemp "$output_dir/.tasks-schema1.XXXXXX")"
cleanup() {
  rm -f "$temporary_path"
}
trap cleanup EXIT

jq 'del(.tasks[].parentID) | .schemaVersion = 1' "$SOURCE_PATH" > "$temporary_path"
chmod "$(stat -f '%Lp' "$SOURCE_PATH")" "$temporary_path"
mv "$temporary_path" "$OUTPUT_PATH"
trap - EXIT

echo "$OUTPUT_PATH"
