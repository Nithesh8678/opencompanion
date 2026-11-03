#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/Xcode.noindex dist/.staging.noindex
if [ ! -f App/AppIcon.icns ]; then
    swift -module-cache-path /tmp/opencompanion-icon-cache scripts/generate-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o App/AppIcon.icns
fi
python3 scripts/generate-project.py
source_revision="$(git rev-parse HEAD)"
if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then source_revision="${source_revision}-dirty"; fi
python3 <<'PYPREFLIGHT'
from pathlib import Path
import sys
sys.path.insert(0,str(Path('scripts').resolve()))
from install_app import System, InstallError
product=Path('build/Xcode.noindex/Build/Products/Release/OpenCompanion.app').resolve()
stage=Path('dist/.staging.noindex/OpenCompanion.app').resolve()
for item in System(Path.cwd()).running():
    if Path(item.get('path','')).resolve() in (product,stage):
        raise InstallError('Quit the build or staging copy of OpenCompanion before rebuilding.')
PYPREFLIGHT
xcodebuild -project OpenCompanion.xcodeproj -scheme OpenCompanion -configuration Release -derivedDataPath build/Xcode.noindex CODE_SIGN_IDENTITY=- OPENCOMPANION_SOURCE_REVISION="$source_revision" build

python3 - "$source_revision" <<'PYRECEIPT'
import hashlib,json,plistlib,re,subprocess,sys,zipfile
from pathlib import Path
sys.path.insert(0, str(Path('scripts').resolve()))
from install_app import System, InstallError, bundle_info

source=Path('build/Xcode.noindex/Build/Products/Release/OpenCompanion.app').resolve()
stage=Path('dist/.staging.noindex/OpenCompanion.app').absolute()
system=System(Path.cwd())
system.verify(source)
if stage.exists() or stage.is_symlink():
    bundle_info(stage)
    if any(item.get('path') == str(stage) for item in system.running()):
        raise InstallError('Quit the staging copy of OpenCompanion before rebuilding.')
    system.trash(stage)
system.copy(source,stage)
system.verify(stage)
binary=stage/'Contents/MacOS/OpenCompanion'
info=bundle_info(stage)

# Replace the archive only after ZIP integrity and the executable hash agree.
archive=Path('dist/OpenCompanion-latest.zip')
temporary=Path('dist/.staging.noindex/OpenCompanion-latest.zip.tmp')
subprocess.run(['/usr/bin/ditto','-c','-k','--sequesterRsrc','--keepParent',str(stage),str(temporary)],check=True)
digest=hashlib.sha256(binary.read_bytes()).hexdigest()
with zipfile.ZipFile(temporary) as zipped:
    if zipped.testzip() is not None:
        raise InstallError('Built archive failed ZIP verification.')
    archived_digest=hashlib.sha256(zipped.read('OpenCompanion.app/Contents/MacOS/OpenCompanion')).hexdigest()
    if digest != archived_digest:
        raise InstallError('Built archive executable does not match the staged app.')
temporary.replace(archive)
for previous in Path('dist').glob('OpenCompanion-*.zip'):
    if previous != archive and re.fullmatch(r'OpenCompanion-\d+(?:\.\d+){1,3}-(?:arm64|x86_64|universal)\.zip',previous.name):
        previous.unlink()
receipt={'sourceRevision':sys.argv[1],'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),'bundleID':info['CFBundleIdentifier'],'version':info['CFBundleShortVersionString'],'signing':'ad-hoc, for local use','notarized':False,'architecture':subprocess.check_output(['lipo','-archs',str(binary)],text=True).strip()}
Path('dist/BUILD-RECEIPT.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(f'Built: {stage}')
print(f'Archive: {archive.resolve()}')
print(f'Binary SHA-256: {digest}')
print('Install the canonical app with scripts/install.sh; temporary app copies are removed after installation.')
PYRECEIPT
