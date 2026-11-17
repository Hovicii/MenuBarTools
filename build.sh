#!/bin/bash
# MenuBarTools 빌드 스크립트 — .app 번들 생성 후 /Applications 에 설치(선택)
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="MenuBarTools"
BUILD_DIR="$DIR/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "▶ 정리..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

echo "▶ 컴파일..."
swiftc -O \
  "$DIR/Sources/main.swift" \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  -framework Cocoa \
  -framework Network

echo "▶ 번들 구성..."
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"

# 로컬 실행용 ad-hoc 코드서명 (권한 프롬프트 안정화)
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (코드서명 생략)"

echo "✅ 빌드 완료: $APP"
echo ""
echo "실행:      open \"$APP\""
echo "설치:      cp -R \"$APP\" /Applications/"
