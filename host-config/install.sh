#!/bin/bash
# 把本仓库 host-config/ 下的宿主机便利配置（目前是 bash_aliases）接进当前用户的
# shell 里。可重复运行：已经装过就跳过，不会重复追加。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_LINE="source \"$SCRIPT_DIR/bash_aliases\""
TARGET="$HOME/.bash_aliases"

touch "$TARGET"

if grep -qF "$SOURCE_LINE" "$TARGET"; then
  echo "已经配置过，跳过：$TARGET"
else
  {
    echo ""
    echo "# --- openclaw-container host-config (host-config/install.sh 添加) ---"
    echo "$SOURCE_LINE"
  } >> "$TARGET"
  echo "已写入 $TARGET"
fi

echo "运行 'source ~/.bashrc' 或重新开一个终端让它生效。"
