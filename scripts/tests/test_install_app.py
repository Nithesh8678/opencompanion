"""Isolated installer transaction fixtures; never call macOS app/library services."""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

MODULE_PATH = Path(__file__).resolve().parents[1] / "install_app.py"
SPEC = importlib.util.spec_from_file_location("opencompanion_install_fixture", MODULE_PATH)
assert SPEC and SPEC.loader
installer = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = installer
SPEC.loader.exec_module(installer)


def make_bundle(path: Path, marker: str, identifier: str = installer.BUNDLE_ID) -> Path:
    (path / "Contents/MacOS").mkdir(parents=True)
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": identifier,
        "CFBundleExecutable": "OpenCompanion",
        "CFBundleShortVersionString": "0.1.0",
        "OpenCompanionSourceRevision": marker,
    }))
    binary = path / "Contents/MacOS/OpenCompanion"
    binary.write_bytes(marker.encode())
    binary.chmod(0o755)
    return path


def marker(path: Path) -> str:
    return (path / "Contents/MacOS/OpenCompanion").read_text()


class FixtureSystem:
    """All mutation and service calls are constrained to a temporary fixture root."""
    def __init__(self, root: Path, paths):
        self.root = root
        self.paths = paths
        self.trash_root = root / "recoverable-trash"
        self.trash_root.mkdir()
        self.running_sequence = [[]]
        self.verify_failure = None
        self.copy_failure = False
        self.exchange_failure = False
        self.trash_failure = False
        self.copied = []
        self.verified = []
        self.trashed = []
        self.registered = []
        self.opened = []
        self.exchanged = []

    def constrain(self, path: Path):
        if not path.is_relative_to(self.root):
            raise AssertionError(f"Fixture attempted external path: {path}")

    def running(self):
        result = self.running_sequence[0]
        if len(self.running_sequence) > 1:
            self.running_sequence.pop(0)
        return result

    def verify(self, path: Path):
        self.constrain(path)
        installer.bundle_info(path)
        self.verified.append(path)
        staged = path.parent.name.startswith(".OpenCompanion-install-")
        if self.verify_failure == "stage" and staged:
            raise OSError("Injected staged signature verification failure")
        if self.verify_failure == "canonical" and path == self.paths.target:
            raise OSError("Injected installed signature verification failure")

    def copy(self, source: Path, destination: Path):
        self.constrain(source)
        self.constrain(destination)
        self.copied.append((source, destination))
        shutil.copytree(source, destination)
        if self.copy_failure:
            raise OSError("Injected interrupted copy")

    def exchange(self, first: Path, second: Path):
        self.constrain(first)
        self.constrain(second)
        self.exchanged.append((first, second))
        if self.exchange_failure:
            raise OSError("Injected atomic exchange failure")
        # The real System uses Darwin RENAME_SWAP. The fake models its completed
        # state; this test does not claim to prove filesystem crash guarantees.
        temporary = first.parent / ".fixture-swap"
        first.rename(temporary)
        second.rename(first)
        temporary.rename(second)

    def trash(self, path: Path):
        self.constrain(path)
        if self.trash_failure:
            raise OSError("Injected recoverable Trash failure")
        destination = self.trash_root / f"{len(self.trashed)}-{path.name}"
        path.rename(destination)
        self.trashed.append((path, destination))

    def register(self, path: Path, *, remove=False):
        self.constrain(path)
        self.registered.append((path, remove))

    def open(self, path: Path):
        self.constrain(path)
        self.opened.append(path)


class InstallerTransactionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="OpenCompanionInstallerFixture-")
        # macOS exposes /var through a system symlink. Production explicitly
        # rejects traversed symlinks; fixtures start from a resolved root.
        self.root = Path(self.directory.name).resolve()
        self.paths = installer.Paths(self.root / "Applications", self.root / "home", self.root / "repo")
        self.paths.application_dir.mkdir()
        self.paths.home.mkdir()
        self.paths.repo.mkdir()
        self.source = make_bundle(self.paths.default_source, "new-build")
        self.system = FixtureSystem(self.root, self.paths)
        self.library = self.paths.home / "Library/Application Support/OpenCompanion/library.sqlite"
        self.library.parent.mkdir(parents=True)
        self.library.write_bytes(b"private fixture library bytes")
        self.credentials = self.paths.home / "Library/Keychains/fixture-only-sentinel"
        self.credentials.parent.mkdir(parents=True)
        self.credentials.write_bytes(b"fixture credential sentinel; no real Keychain API")

    def tearDown(self):
        self.directory.cleanup()

    def installed(self):
        return make_bundle(self.paths.target, "old-build")

    def assert_user_data_unchanged(self):
        self.assertEqual(self.library.read_bytes(), b"private fixture library bytes")
        self.assertEqual(self.credentials.read_bytes(), b"fixture credential sentinel; no real Keychain API")

    def assert_old_install_intact(self):
        self.assertEqual(marker(self.paths.target), "old-build")
        self.assertEqual(marker(self.source), "new-build")
        self.assertFalse(self.system.trashed)
        self.assertFalse(self.system.opened)
        self.assert_user_data_unchanged()

    def test_success_keeps_one_canonical_app_and_recoverable_old_copies(self):
        self.installed()
        legacy = make_bundle(self.paths.home / "Applications/OpenCompanion.app", "legacy-home")
        derived = make_bundle(self.paths.repo / "build/Xcode/Build/Products/Release/OpenCompanion.app", "derived")
        previous = make_bundle(self.paths.repo / "build/PreviousInstallations/OpenCompanion-old.app.backup", "previous")
        result = installer.install(self.paths, self.system, self.source, no_open=True)
        self.assertEqual(marker(self.paths.target), "new-build")
        self.assertEqual(result["cleanupIssues"], [])
        for old_path in [self.source, legacy, derived, previous]:
            self.assertFalse(old_path.exists(), old_path)
        recovered = {marker(destination) for _, destination in self.system.trashed}
        self.assertEqual(recovered, {"old-build", "legacy-home", "derived", "previous", "new-build"})
        self.assertEqual(list(self.paths.application_dir.glob("OpenCompanion.app")), [self.paths.target])
        self.assertIn((self.paths.target, False), self.system.registered)
        self.assertFalse(self.system.opened)
        self.assert_user_data_unchanged()

    def test_running_app_refuses_before_copy_or_cleanup(self):
        self.installed()
        self.system.running_sequence = [[{"path": str(self.paths.target), "pid": 42}]]
        with self.assertRaises(installer.InstallError):
            installer.install(self.paths, self.system, self.source, no_open=True)
        self.assertFalse(self.system.copied)
        self.assert_old_install_intact()

    def test_running_app_race_is_rechecked_before_commit(self):
        self.installed()
        self.system.running_sequence = [[], [{"path": str(self.paths.target), "pid": 42}]]
        with self.assertRaises(installer.InstallError):
            installer.install(self.paths, self.system, self.source, no_open=True)
        self.assertEqual(len(self.system.copied), 1)
        self.assertFalse(self.system.exchanged)
        self.assert_old_install_intact()

    def test_running_app_started_after_commit_prevents_trashing_its_bundle(self):
        self.installed()
        legacy = make_bundle(self.paths.home / "Applications/OpenCompanion.app", "legacy-home")
        self.system.running_sequence = [[], [], [{"path": str(legacy), "pid": 42}]]
        result = installer.install(self.paths, self.system, self.source, no_open=True)
        self.assertEqual(marker(self.paths.target), "new-build")
        self.assertTrue(result["cleanupIssues"])
        self.assertEqual(marker(legacy), "legacy-home")
        self.assertFalse(self.system.trashed)
        self.assert_user_data_unchanged()

    def test_interrupted_copy_never_moves_the_existing_install(self):
        self.installed()
        self.system.copy_failure = True
        with self.assertRaises(OSError):
            installer.install(self.paths, self.system, self.source, no_open=True)
        self.assertFalse(self.system.exchanged)
        self.assert_old_install_intact()

    def test_staged_verification_failure_never_moves_the_existing_install(self):
        self.installed()
        self.system.verify_failure = "stage"
        with self.assertRaises(OSError):
            installer.install(self.paths, self.system, self.source, no_open=True)
        self.assertFalse(self.system.exchanged)
        self.assert_old_install_intact()

    def test_atomic_exchange_failure_leaves_the_existing_install_unchanged(self):
        self.installed()
        self.system.exchange_failure = True
        with self.assertRaises(OSError):
            installer.install(self.paths, self.system, self.source, no_open=True)
        self.assert_old_install_intact()

    def test_installed_verification_failure_exchanges_the_old_install_back(self):
        self.installed()
        self.system.verify_failure = "canonical"
        with self.assertRaises(OSError):
            installer.install(self.paths, self.system, self.source, no_open=True)
        self.assertEqual(len(self.system.exchanged), 2)
        self.assert_old_install_intact()

    def test_trash_failure_keeps_new_canonical_and_old_recoverable_data(self):
        self.installed()
        self.system.trash_failure = True
        result = installer.install(self.paths, self.system, self.source, no_open=False)
        self.assertEqual(marker(self.paths.target), "new-build")
        self.assertTrue(result["cleanupIssues"])
        self.assertFalse(self.system.opened)
        recovery = list(self.paths.application_dir.glob(".OpenCompanion-install-*.noindex/*"))
        self.assertTrue(any(path.is_dir() and marker(path) == "old-build" for path in recovery))
        self.assert_user_data_unchanged()

    def test_unexpected_source_or_existing_bundle_id_is_never_trashed(self):
        self.installed()
        other = make_bundle(self.root / "foreign.app", "foreign", identifier="com.example.unrelated")
        with self.assertRaises(installer.InstallError):
            installer.install(self.paths, self.system, other, no_open=True)
        self.assert_old_install_intact()
        shutil.rmtree(self.paths.target)
        make_bundle(self.paths.target, "foreign-target", identifier="com.example.unrelated")
        with self.assertRaises(installer.InstallError):
            installer.install(self.paths, self.system, self.source, no_open=True)
        self.assertEqual(marker(self.paths.target), "foreign-target")
        self.assertFalse(self.system.trashed)
        self.assert_user_data_unchanged()

    def test_source_and_target_symlinks_are_refused_including_broken_target(self):
        self.installed()
        link = self.root / "source-link.app"
        link.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(installer.InstallError):
            installer.install(self.paths, self.system, link, no_open=True)
        self.assert_old_install_intact()
        shutil.rmtree(self.paths.target)
        self.paths.target.symlink_to(self.root / "missing-bundle.app", target_is_directory=True)
        with self.assertRaises(installer.InstallError):
            installer.install(self.paths, self.system, self.source, no_open=True)
        self.assertTrue(self.paths.target.is_symlink())
        self.assertFalse(self.system.trashed)
        self.assert_user_data_unchanged()

    def test_source_equal_to_target_is_refused(self):
        self.installed()
        with self.assertRaises(installer.InstallError):
            installer.install(self.paths, self.system, self.paths.target, no_open=True)
        self.assert_old_install_intact()

    def test_dry_run_does_not_copy_trash_open_or_write_receipt(self):
        self.installed()
        result = installer.install(self.paths, self.system, self.source, no_open=False, dry_run=True)
        self.assertTrue(result["dryRun"])
        self.assertFalse(self.system.copied)
        self.assertFalse(self.system.exchanged)
        self.assertFalse((self.paths.repo / "dist/INSTALL-RECEIPT.json").exists())
        self.assert_old_install_intact()

    def test_uninstall_trashes_only_known_bundles_and_preserves_user_data(self):
        self.installed()
        make_bundle(self.paths.home / "Applications/OpenCompanion.app", "legacy-home")
        unrelated = make_bundle(self.root / "Unrelated.app", "unrelated", identifier="com.example.unrelated")
        result = installer.uninstall(self.paths, self.system)
        self.assertTrue(result["uninstall"])
        self.assertFalse(self.paths.target.exists())
        self.assertFalse(self.source.exists())
        self.assertEqual(marker(unrelated), "unrelated")
        self.assert_user_data_unchanged()

    def test_destination_lock_prevents_overlapping_install_and_uninstall(self):
        self.installed()
        child = r"""
import importlib.util
from pathlib import Path
import sys
spec = importlib.util.spec_from_file_location("installer_child_fixture", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
paths = module.Paths(Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4]))
class NoSystemCalls:
    def __getattr__(self, name):
        raise AssertionError("Lock failed before system operation: " + name)
for operation in ("install", "uninstall"):
    try:
        if operation == "install":
            module.install(paths, NoSystemCalls(), Path(sys.argv[5]), no_open=True)
        else:
            module.uninstall(paths, NoSystemCalls())
    except module.InstallError as error:
        if "Another OpenCompanion installer or uninstaller" not in str(error):
            raise
    else:
        raise AssertionError("Concurrent " + operation + " unexpectedly acquired the lock")
print("INDEPENDENT_PROCESS_LOCK_REFUSAL_PASSED")
"""
        # Acquire the real API's lock instead of duplicating its filename. A
        # second Python process proves the exclusion boundary independently.
        with installer.installation_lock(self.paths):
            result = subprocess.run(
                [sys.executable, "-c", child, str(MODULE_PATH), str(self.paths.application_dir),
                 str(self.paths.home), str(self.paths.repo), str(self.source)],
                capture_output=True, text=True, timeout=10, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("INDEPENDENT_PROCESS_LOCK_REFUSAL_PASSED", result.stdout)
        self.assert_old_install_intact()


class LaunchServicesAdapterTests(unittest.TestCase):
    """Exercise only the subprocess adapter; no Launch Services calls occur."""

    def setUp(self):
        self.system = installer.System(Path("/fixture/repo"))
        self.bundle = Path("/fixture/Applications/OpenCompanion.app")
        self.absent = f"failed to scan {self.bundle}: -10814"

    def test_success_accepts_register_and_unregister(self):
        for remove in (False, True):
            with self.subTest(remove=remove):
                result = subprocess.CompletedProcess([], 0, "", "")
                with mock.patch.object(installer.subprocess, "run", return_value=result) as run:
                    self.system.register(self.bundle, remove=remove)
                run.assert_called_once_with(
                    [installer.LSREGISTER, "-u" if remove else "-f", str(self.bundle)],
                    capture_output=True, text=True, check=False)

    def test_unregister_accepts_only_exact_absent_diagnostic_with_optional_spotlight_line(self):
        diagnostics = (
            (self.absent, ""),
            ("", self.absent),
            (f"  {self.absent}  \n\n from spotlight \n", ""),
            ("", f"\n\t{self.absent}\t\n from spotlight \n"),
            (self.absent, "from spotlight"),
        )
        for stdout, stderr in diagnostics:
            with self.subTest(stdout=stdout, stderr=stderr):
                result = subprocess.CompletedProcess([], 1, stdout, stderr)
                with mock.patch.object(installer.subprocess, "run", return_value=result) as run:
                    self.system.register(self.bundle, remove=True)
                run.assert_called_once_with(
                    [installer.LSREGISTER, "-u", str(self.bundle)],
                    capture_output=True, text=True, check=False)

    def test_unregister_rejects_unexpected_failure_and_preserves_diagnostics(self):
        failures = (
            (2, "", self.absent),
            (1, "", "failed to scan /another/OpenCompanion.app: -10814"),
            (1, "", self.absent.replace("-10814", "-10811")),
            (1, "", self.absent + "\nPermission denied"),
            (1, "Unrelated warning", self.absent),
            (1, "", self.absent + " from spotlight"),
            (1, "", "from spotlight\n" + self.absent),
            (1, "", ""),
        )
        for code, stdout, stderr in failures:
            with self.subTest(code=code, stdout=stdout, stderr=stderr):
                result = subprocess.CompletedProcess([], code, stdout, stderr)
                with mock.patch.object(installer.subprocess, "run", return_value=result):
                    with self.assertRaises(subprocess.CalledProcessError) as raised:
                        self.system.register(self.bundle, remove=True)
                self.assertEqual(raised.exception.returncode, code)
                self.assertEqual(raised.exception.cmd, [installer.LSREGISTER, "-u", str(self.bundle)])
                self.assertEqual(raised.exception.output, stdout)
                self.assertEqual(raised.exception.stderr, stderr)

    def test_canonical_registration_rejects_absent_diagnostic(self):
        result = subprocess.CompletedProcess([], 1, "", self.absent + "\nfrom spotlight")
        with mock.patch.object(installer.subprocess, "run", return_value=result) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                self.system.register(self.bundle)
        run.assert_called_once_with(
            [installer.LSREGISTER, "-f", str(self.bundle)],
            capture_output=True, text=True, check=False)


if __name__ == "__main__":
    unittest.main()
