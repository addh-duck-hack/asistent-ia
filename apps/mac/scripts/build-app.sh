#!/usr/bin/env bash
# Compila "Asistent IA.app" en Release y la deja en apps/mac/dist/.
#   scripts/build-app.sh            # solo compila
#   scripts/build-app.sh --install  # además la copia a /Applications
#   scripts/build-app.sh --dmg      # además genera dist/AsistentIA.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "Falta XcodeGen: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet

xcodebuild -project AsistentIA.xcodeproj -scheme AsistentIA -configuration Release \
  -derivedDataPath build -destination 'platform=macOS,arch=arm64' -quiet build

APP="build/Build/Products/Release/Asistent IA.app"
rm -rf dist && mkdir -p dist
cp -R "$APP" dist/
codesign --verify --deep --strict "dist/Asistent IA.app"
echo "Listo: apps/mac/dist/Asistent IA.app ($(defaults read "$PWD/dist/Asistent IA.app/Contents/Info" CFBundleShortVersionString))"

for arg in "$@"; do
  case "$arg" in
    --install)
      # Cerrar la versión anterior si está abierta, para reemplazarla.
      osascript -e 'quit app "Asistent IA"' 2>/dev/null || true
      rm -rf "/Applications/Asistent IA.app"
      cp -R "dist/Asistent IA.app" /Applications/
      echo "Instalada en /Applications/Asistent IA.app"
      ;;
    --dmg)
      hdiutil create -volname "Asistent IA" -srcfolder "dist/Asistent IA.app" -ov -format UDZO dist/AsistentIA.dmg -quiet
      echo "DMG: apps/mac/dist/AsistentIA.dmg"
      ;;
  esac
done
