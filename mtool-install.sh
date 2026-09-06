#!/usr/bin/env bash
# 旧链接兼容入口；完整脚本与说明已移至 mtool/ 目录。
set -Eeuo pipefail
task_script=$(mktemp)
trap 'rm -f -- "$task_script"' EXIT
curl -fsSL --fail-early --connect-timeout 10 --max-time 120 \
    'https://raw.githubusercontent.com/xchenya/scripts/main/mtool/install.sh' -o "$task_script"
bash -n "$task_script"
bash "$task_script" "$@"
