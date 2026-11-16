#!/bin/sh
# RetroVisionApp の SwiftPM 実行ファイルを .app バンドルに組み立てる（#2 / #16 の暫定バンドル化）。
#   使い方: sh Scripts/make-app.sh [debug|release]   （既定 release）
#   出力:   build/RetroVision AI.app
# Xcode プロジェクトを持たないため、Info.plist はここで生成する。署名は ad-hoc（OQ-24）。
set -eu

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PKG="$ROOT/App/RetroVisionApp"
OUT_DIR="$ROOT/build"
APP_NAME="RetroVision AI"
APP="$OUT_DIR/$APP_NAME.app"
VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo 0.0.0)"

(cd "$APP_PKG" && swift build -c "$CONFIG" --product RetroVisionApp)
BIN_DIR="$(cd "$APP_PKG" && swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/RetroVisionApp" "$APP/Contents/MacOS/RetroVisionApp"
# SwiftPM のリソースバンドル（あれば）を同梱する。
for b in "$BIN_DIR"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>dev.retrovision.RetroVisionApp</string>
  <key>CFBundleExecutable</key><string>RetroVisionApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Video</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.movie</string>
        <string>public.mpeg</string>
        <string>public.mpeg-2-video</string>
        <string>public.mpeg-4</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "built: $APP"
