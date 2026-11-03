#!/bin/bash
# Build only this public acceptance fixture. Never installs or launches it.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
destination="${1:-/tmp/OpenCompanionGuidanceFixture.app}"
if [ "$#" -gt 1 ] || [[ "$destination" != /*.app ]]; then
  echo "Usage: $0 [absolute-output.app under /tmp or this repository]" >&2
  exit 2
fi
parent="$(cd "$(dirname "$destination")" && pwd -P)"
destination="$parent/$(basename "$destination")"
case "$destination" in
  /private/tmp/*.app|"$repo_root"/*.app) ;;
  *) echo "Fixture output must be inside /tmp or this repository." >&2; exit 2 ;;
esac
if [ -L "$destination" ]; then
  echo "Refusing a symbolic-link destination." >&2
  exit 2
fi
if /usr/bin/pgrep -x GuidanceFixture >/dev/null; then
  echo "Quit Guidance Fixture before rebuilding it." >&2
  exit 1
fi
if [ -e "$destination" ]; then
  existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$existing_id" != org.opencompanion.fixture.guidance ]; then
    echo "Refusing to replace a bundle with another identifier." >&2
    exit 2
  fi
fi

scratch="$(mktemp -d /tmp/OpenCompanionGuidanceFixture-build.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
bundle="$scratch/Guidance Fixture.app"
mkdir -p "$bundle/Contents/MacOS" /tmp/opencompanion-guidance-fixture-module-cache
xcrun swiftc -parse-as-library -swift-version 6 -O -framework AppKit \
  -module-cache-path /tmp/opencompanion-guidance-fixture-module-cache \
  "$repo_root/scripts/fixtures/GuidanceFixture.swift" \
  -o "$bundle/Contents/MacOS/GuidanceFixture"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.opencompanion.fixture.guidance</string>
<key>CFBundleName</key><string>Guidance Fixture</string>
<key>CFBundleDisplayName</key><string>Guidance Fixture</string>
<key>CFBundleExecutable</key><string>GuidanceFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
if /usr/bin/pgrep -x GuidanceFixture >/dev/null; then
  echo "Guidance Fixture started during compilation; quit it before rebuilding." >&2
  exit 1
fi
if [ -e "$destination" ]; then rm -rf "$destination"; fi
mv "$bundle" "$destination"
printf 'Built public fixture: %s\nBundle ID: org.opencompanion.fixture.guidance\n' "$destination"
