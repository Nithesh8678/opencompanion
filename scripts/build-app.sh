#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build dist
if [ ! -f App/AppIcon.icns ]; then
    swift -module-cache-path /tmp/opencompanion-icon-cache scripts/generate-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o App/AppIcon.icns
fi
python3 scripts/generate-project.py
xcodebuild -project OpenCompanion.xcodeproj -scheme OpenCompanion -configuration Release -derivedDataPath build/Xcode CODE_SIGN_IDENTITY=- build
rm -rf dist/OpenCompanion.app
cp -R build/Xcode/Build/Products/Release/OpenCompanion.app dist/
codesign --verify --deep --strict dist/OpenCompanion.app
shasum -a 256 dist/OpenCompanion.app/Contents/MacOS/OpenCompanion
