#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_app="${1:-dist/OpenCompanion.app}"
target_app="$HOME/Applications/OpenCompanion.app"
if [ ! -d "$source_app" ]; then printf '%s\n' 'Build the app first with scripts/build-app.sh' >&2; exit 1; fi
codesign --verify --deep --strict "$source_app"
mkdir -p "$HOME/Applications"
if [ -e "$target_app" ]; then
    printf '%s\n' 'An installed OpenCompanion already exists. Quit it and move it aside before installing this build. Library data will be preserved.' >&2
    exit 1
fi
ditto "$source_app" "$target_app"
printf 'Installed: %s\n' "$target_app"
open "$target_app"
