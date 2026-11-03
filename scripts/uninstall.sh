#!/bin/bash
set -euo pipefail
target_app="$HOME/Applications/OpenCompanion.app"
printf '%s\n' 'Quit OpenCompanion first. This removes only the app bundle; your library and Keychain entries are preserved.'
if [ -d "$target_app" ]; then
    trash_app="$HOME/.Trash/OpenCompanion-$(date +%Y%m%d-%H%M%S).app"
    mv "$target_app" "$trash_app"
    printf 'Moved app to: %s\n' "$trash_app"
fi
printf '%s\n' 'Browser helper manifests are separate. Use NativeBrowserHost/install.py --help for removal instructions.'
