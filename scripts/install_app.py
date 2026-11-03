#!/usr/bin/env python3
"""Install one canonical local bundle. Never terminates apps or touches user data."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import ctypes
from dataclasses import dataclass
import fcntl
from functools import wraps
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

BUNDLE_ID = "org.opencompanion.mac"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


class InstallError(RuntimeError):
    pass


@dataclass(frozen=True)
class Paths:
    application_dir: Path
    home: Path
    repo: Path

    @property
    def target(self) -> Path:
        return self.application_dir / "OpenCompanion.app"

    @property
    def default_source(self) -> Path:
        return self.repo / "dist/.staging.noindex/OpenCompanion.app"

    def legacy_candidates(self) -> list[Path]:
        candidates = [self.home / "Applications/OpenCompanion.app", self.repo / "dist/OpenCompanion.app",
                      self.default_source]
        for derived in ("Xcode", "Xcode.noindex"):
            for configuration in ("Release", "Debug"):
                candidates.append(self.repo / f"build/{derived}/Build/Products/{configuration}/OpenCompanion.app")
        previous = self.repo / "build/PreviousInstallations"
        if previous.is_dir() and not previous.is_symlink():
            candidates.extend(sorted(previous.glob("OpenCompanion-*.app.backup")))
        # Recover interrupted transactions without indexing their old bundles.
        for transaction in sorted(self.application_dir.glob(".OpenCompanion-install-*.noindex")):
            if transaction.is_dir() and not transaction.is_symlink():
                candidates.append(transaction / "OpenCompanion.app")
        return candidates


def ensure_plain_path(path: Path) -> None:
    """Refuse symlink traversal for app roots and constrained cleanup locations."""
    current = path
    while current != current.parent:
        if current.is_symlink():
            raise InstallError(f"Refusing symbolic-link path: {current}")
        current = current.parent


def bundle_info(path: Path) -> dict:
    ensure_plain_path(path)
    if not path.is_dir():
        raise InstallError(f"App bundle is missing: {path}")
    try:
        with (path / "Contents/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise InstallError(f"Cannot read bundle metadata: {path}: {error}") from error
    if info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundleExecutable") != "OpenCompanion":
        raise InstallError(f"Refusing bundle with an unexpected identifier or executable: {path}")
    binary = path / "Contents/MacOS/OpenCompanion"
    if not binary.is_file() or binary.is_symlink():
        raise InstallError(f"App executable is missing or a symbolic link: {path}")
    return info


class System:
    def __init__(self, repo: Path):
        self.helper = repo / "scripts/installation-system.swift"

    def helper_call(self, *arguments: str) -> str:
        cache = Path(tempfile.gettempdir()) / "opencompanion-installer-module-cache"
        return subprocess.check_output(["/usr/bin/swift", "-module-cache-path", str(cache),
                                        str(self.helper), *arguments], text=True).strip()

    def running(self) -> list[dict]:
        return json.loads(self.helper_call("running"))

    def verify(self, path: Path) -> None:
        bundle_info(path)
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(path)], check=True)

    def copy(self, source: Path, destination: Path) -> None:
        subprocess.run(["/usr/bin/ditto", str(source), str(destination)], check=True)

    def exchange(self, first: Path, second: Path) -> None:
        # RENAME_SWAP replaces the installed directory atomically: interruption
        # cannot leave /Applications without either the old or the new bundle.
        library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        operation = library.renameatx_np
        operation.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        operation.restype = ctypes.c_int
        if operation(-2, os.fsencode(first), -2, os.fsencode(second), 0x00000002) != 0:
            number = ctypes.get_errno()
            raise OSError(number, os.strerror(number), str(second))

    def trash(self, path: Path) -> None:
        self.helper_call("trash", str(path))

    def register(self, path: Path, *, remove: bool = False) -> None:
        subprocess.run([LSREGISTER, "-u" if remove else "-f", str(path)], check=True,
                       stdout=subprocess.DEVNULL)

    def open(self, path: Path) -> None:
        subprocess.run(["/usr/bin/open", str(path)], check=True)


def refuse_running(system: System) -> None:
    running = system.running()
    if running:
        locations = ", ".join(str(item.get("path", "unknown")) for item in running)
        raise InstallError(f"Quit OpenCompanion before installing or uninstalling. Running: {locations}")


def cleanup_candidates(paths: Paths, *, excluding: set[Path] | None = None) -> list[Path]:
    candidates = []
    for path in paths.legacy_candidates():
        if path.is_symlink():
            raise InstallError(f"Refusing symbolic-link cleanup candidate: {path}")
        if path == paths.target or path in (excluding or set()) or not path.exists():
            continue
        # Foreign or symbolic-link bundles are never removed, even at known paths.
        bundle_info(path)
        candidates.append(path)
    return candidates


def trash_verified(path: Path, system: System) -> None:
    refuse_running(system)
    bundle_info(path)
    system.register(path, remove=True)
    system.trash(path)


@contextmanager
def installation_lock(paths: Paths):
    ensure_plain_path(paths.application_dir)
    lock_path = paths.application_dir / ".OpenCompanion-install.lock"
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise InstallError(f"Unexpected installer lock owner or type: {lock_path}")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise InstallError("Another OpenCompanion installer or uninstaller is running.") from error
        yield
    finally:
        os.close(descriptor)


def serialized(operation):
    @wraps(operation)
    def call(paths, system, *args, **kwargs):
        if kwargs.get("dry_run", False):
            return operation(paths, system, *args, **kwargs)
        with installation_lock(paths):
            return operation(paths, system, *args, **kwargs)
    return call


@serialized
def install(paths: Paths, system: System, source: Path, *, no_open: bool = False,
            dry_run: bool = False) -> dict:
    source = Path(os.path.abspath(source))
    ensure_plain_path(paths.application_dir)
    ensure_plain_path(paths.target)
    if source == paths.target:
        raise InstallError("The source cannot be the canonical installed app.")
    refuse_running(system)
    info = bundle_info(source)
    system.verify(source)
    if paths.target.exists():
        bundle_info(paths.target)
    candidates = cleanup_candidates(paths)
    plan = {"target": str(paths.target), "source": str(source),
            "legacyCopies": [str(path) for path in candidates], "dryRun": dry_run}
    if dry_run:
        return plan

    # Stage and verify on the destination filesystem before moving the prior app.
    # A permission failure is fatal; there is no ~/Applications fallback.
    transaction = Path(tempfile.mkdtemp(prefix=".OpenCompanion-install-", suffix=".noindex",
                                       dir=paths.application_dir))
    staged = transaction / "OpenCompanion.app"
    committed = False
    exchanged = False
    try:
        system.copy(source, staged)
        system.verify(staged)
        refuse_running(system)
        if paths.target.exists():
            bundle_info(paths.target)
            system.exchange(staged, paths.target)
            exchanged = True
        else:
            staged.rename(paths.target)
        try:
            system.verify(paths.target)
        except BaseException:
            if exchanged:
                system.exchange(staged, paths.target)
                exchanged = False
            else:
                paths.target.rename(staged)
            raise
        committed = True
    finally:
        # Preserve the old app if an atomic rollback itself could not complete.
        if not committed and not exchanged:
            shutil.rmtree(transaction)

    issues = []
    for path in ([staged] if staged.exists() else []) + candidates:
        if not path.exists():
            continue
        try:
            trash_verified(path, system)
        except (OSError, InstallError, subprocess.SubprocessError) as error:
            issues.append(f"Retained {path}: {error}")
    try:
        system.register(paths.target)
    except subprocess.SubprocessError as error:
        issues.append(f"Launch Services registration failed: {error}")
    if transaction.exists() and not any(transaction.iterdir()):
        transaction.rmdir()

    binary = paths.target / "Contents/MacOS/OpenCompanion"
    receipt = {**plan, "installedAt": datetime.now(timezone.utc).isoformat(),
               "bundleID": BUNDLE_ID, "version": info.get("CFBundleShortVersionString"),
               "sourceRevision": info.get("OpenCompanionSourceRevision"),
               "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
               "cleanupIssues": issues}
    receipt_dir = paths.repo / "dist"
    receipt_dir.mkdir(exist_ok=True)
    receipt_path = receipt_dir / "INSTALL-RECEIPT.json"
    temporary = receipt_path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(receipt, indent=2) + "\n")
    temporary.replace(receipt_path)
    if not no_open and not issues:
        system.open(paths.target)
    return receipt


@serialized
def uninstall(paths: Paths, system: System, *, dry_run: bool = False) -> dict:
    refuse_running(system)
    ensure_plain_path(paths.target)
    candidates = cleanup_candidates(paths)
    if paths.target.exists():
        bundle_info(paths.target)
        candidates.insert(0, paths.target)
    if not dry_run:
        for path in candidates:
            refuse_running(system)
            trash_verified(path, system)
    return {"uninstall": True, "dryRun": dry_run, "bundles": [str(p) for p in candidates],
            "userData": "Library and Keychain preserved"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", help="Defaults to dist/.staging.noindex/OpenCompanion.app")
    parser.add_argument("--no-open", action="store_true", help="Install without launching the app")
    parser.add_argument("--dry-run", action="store_true", help="Validate and print plan without changing files")
    parser.add_argument("--uninstall", action="store_true", help="Trash known app copies; preserve library and credentials")
    args = parser.parse_args()
    paths = Paths(Path("/Applications"), Path.home(), Path(__file__).resolve().parent.parent)
    system = System(paths.repo)
    try:
        result = (uninstall(paths, system, dry_run=args.dry_run) if args.uninstall else
                  install(paths, system, Path(args.source) if args.source else paths.default_source,
                          no_open=args.no_open, dry_run=args.dry_run))
        print(json.dumps(result, indent=2))
        return 2 if result.get("cleanupIssues") else 0
    except (OSError, InstallError, subprocess.SubprocessError, ValueError) as error:
        print(f"OpenCompanion installer: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
