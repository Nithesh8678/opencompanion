#!/usr/bin/env python3
"""Resolve local code-signing settings without inspecting or exporting keys."""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import sys
from typing import Mapping


def load_settings(config_path: Path, environment: Mapping[str, str]) -> tuple[str, str]:
    settings = {}
    if environment.get("CI", "").lower() != "true" and config_path.exists():
        if config_path.stat().st_size > 16_384:
            raise ValueError("Local signing configuration exceeds 16 KiB.")
        try:
            settings = json.loads(config_path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise ValueError(f"Cannot read local signing configuration: {error}") from error
        if not isinstance(settings, dict) or "identity" not in settings or set(settings) - {"identity", "team"}:
            raise ValueError("Local signing configuration requires identity and accepts only identity and team.")
        if any(not isinstance(value, str) for value in settings.values()):
            raise ValueError("Local signing identity and team must be strings.")
        _validate(settings.get("identity", "-"), settings.get("team", ""))
    identity = environment.get("CODE_SIGN_IDENTITY", settings.get("identity", "-"))
    team = environment.get("DEVELOPMENT_TEAM", settings.get("team", ""))
    if environment.get("CODE_SIGN_IDENTITY") == "-" and "DEVELOPMENT_TEAM" not in environment:
        team = ""
    _validate(identity, team)
    return identity, team


def _validate(identity: str, team: str) -> None:
    if not identity or len(identity) > 200 or any(ord(character) < 32 or ord(character) == 127 for character in identity):
        raise ValueError("Code-signing identity must be a nonempty name or SHA-1, without control characters.")
    if team and re.fullmatch(r"[A-Z0-9]{10}", team) is None:
        raise ValueError("Development team must be an uppercase 10-character team identifier.")


if __name__ == "__main__":
    try:
        identity, team = load_settings(Path(__file__).resolve().parent.parent / "build/local-signing.json", os.environ)
        print(f"{identity}\t{team}")
    except (OSError, ValueError) as error:
        print(f"OpenCompanion signing configuration: {error}", file=sys.stderr)
        raise SystemExit(1)
