#!/usr/bin/env python3
"""Install or remove this user's native host registration (never needs sudo)."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import sys

HOST = 'org.opencompanion.browser'
BROWSERS = {'chrome': 'Google/Chrome', 'chromium': 'Chromium', 'edge': 'Microsoft Edge'}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--extension-id', help='32-letter ID shown by chrome://extensions.')
    parser.add_argument('--browser', choices=BROWSERS, default='chrome')
    parser.add_argument('--uninstall', action='store_true')
    args = parser.parse_args()
    support = Path.home() / 'Library/Application Support'
    registration = support / BROWSERS[args.browser] / 'NativeMessagingHosts' / f'{HOST}.json'
    install_dir = support / 'OpenCompanion/NativeBrowserHost'
    if args.uninstall:
        registration.unlink(missing_ok=True)
        # Other browser registrations can share the host, so keep its files.
        print(f'Removed {registration}. Shared host files remain at {install_dir}.')
        return 0
    if not args.extension_id or not re.fullmatch('[a-p]{32}', args.extension_id):
        parser.error('--extension-id must be the 32-letter ID from the extension manager.')
    if sys.platform != 'darwin':
        parser.error('This installer currently supports macOS only.')
    install_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(install_dir, 0o700)
    shutil.copyfile(Path(__file__).with_name('host.py'), install_dir / 'host.py')
    launcher = install_dir / 'opencompanion-browser'
    launcher.write_text(f'#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(install_dir / "host.py"))} "$@"\n')
    launcher.chmod(0o700)
    manifest = {'name': HOST, 'description': 'OpenCompanion local browser bridge', 'path': str(launcher), 'type': 'stdio', 'allowed_origins': [f'chrome-extension://{args.extension_id}/']}
    registration.parent.mkdir(parents=True, exist_ok=True)
    registration.write_text(json.dumps(manifest, indent=2) + '\n')
    registration.chmod(0o600)
    print(f'Installed {registration}. Open the app, then connect a tab in the extension popup.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
