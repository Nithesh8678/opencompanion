#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build dist
if [ ! -f App/AppIcon.icns ]; then
    swift -module-cache-path /tmp/opencompanion-icon-cache scripts/generate-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o App/AppIcon.icns
fi
python3 scripts/generate-project.py
source_revision="$(git rev-parse HEAD)"
if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then source_revision="${source_revision}-dirty"; fi
xcodebuild -project OpenCompanion.xcodeproj -scheme OpenCompanion -configuration Release -derivedDataPath build/Xcode CODE_SIGN_IDENTITY=- OPENCOMPANION_SOURCE_REVISION="$source_revision" build
rm -rf dist/OpenCompanion.app
cp -R build/Xcode/Build/Products/Release/OpenCompanion.app dist/
codesign --verify --deep --strict dist/OpenCompanion.app
shasum -a 256 dist/OpenCompanion.app/Contents/MacOS/OpenCompanion

python3 - "$source_revision" <<'PYRECEIPT'
import hashlib,json,plistlib,subprocess,sys
from pathlib import Path
binary=Path('dist/OpenCompanion.app/Contents/MacOS/OpenCompanion')
info=plistlib.loads(Path('dist/OpenCompanion.app/Contents/Info.plist').read_bytes())
receipt={'sourceRevision':sys.argv[1],'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),'bundleID':info['CFBundleIdentifier'],'version':info['CFBundleShortVersionString'],'signing':'ad-hoc, for local use','notarized':False,'architecture':subprocess.check_output(['lipo','-archs',str(binary)],text=True).strip()}
Path('dist/BUILD-RECEIPT.json').write_text(json.dumps(receipt,indent=2)+'\n')
PYRECEIPT
