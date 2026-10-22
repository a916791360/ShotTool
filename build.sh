#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ShotTool"
BUNDLE="dist/${APP_NAME}.app"

echo "==> 编译（release）"
# --disable-sandbox 是必须的：SwiftPM 默认用 sandbox-exec 编译 manifest，
# 在受限环境里会直接报 "sandbox_apply: Operation not permitted"。
swift build -c release --disable-sandbox

echo "==> 组装 .app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp ".build/release/${APP_NAME}" "$BUNDLE/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

echo "==> 签名"
# 必须用真实证书签，不要用 ad-hoc。
# 原因：ad-hoc 签名的 designated requirement 里带 cdhash，每次重新编译 cdhash 就变，
#       TCC 会认为「这是另一个程序」，屏幕录制授权立刻失效——而系统设置里开关还显示是开的，
#       表现为「明明授权了却一直提示没权限」，极难自查。
# 用 Apple Development 证书签，requirement 只绑 identifier + Team，重装不再掉授权。
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/' || true)

if [ -n "${IDENTITY}" ]; then
  echo "    证书：${IDENTITY}"
  codesign --force --sign "${IDENTITY}" --identifier "com.yangran.shottool" "$BUNDLE"
else
  echo "    ! 未找到 Apple Development 证书，退回 ad-hoc —— 每次重装都要重新授权"
  codesign --force --sign - --identifier "com.yangran.shottool" "$BUNDLE"
fi

echo "==> 完成：$(pwd)/$BUNDLE"
