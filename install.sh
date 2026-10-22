#!/bin/bash
# 编译并覆盖安装到 /Applications，然后启动。
# 以后改了代码，跑这一个脚本就行。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ShotTool"
TARGET="/Applications/${APP_NAME}.app"

echo "==> 1/4 编译"
./build.sh

echo "==> 2/4 停止旧实例"
killall -x "$APP_NAME" 2>/dev/null || true
sleep 1
# killall 偶尔留残影，按 PID 再补一刀
for pid in $(pgrep -x "$APP_NAME" 2>/dev/null || true); do
  kill -TERM "$pid" 2>/dev/null || true
done
sleep 1

echo "==> 3/4 安装到 $TARGET"
rm -rf "$TARGET"
ditto "dist/${APP_NAME}.app" "$TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

echo "==> 4/4 启动"
open "$TARGET"
sleep 2

COUNT=$(pgrep -x "$APP_NAME" | wc -l | tr -d ' ')
echo ""
if [ "$COUNT" = "1" ]; then
  echo "完成。实例数 ${COUNT}，菜单栏左边应该有四角框图标。"
else
  echo "注意：当前有 ${COUNT} 个实例在跑，热键可能打架。"
fi
