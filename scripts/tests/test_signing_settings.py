"""Signing settings fixtures; no Keychain, signing tools, or app services."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "signing_settings.py"
SPEC = importlib.util.spec_from_file_location("opencompanion_signing_fixture", MODULE_PATH)
assert SPEC and SPEC.loader
signing = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = signing
SPEC.loader.exec_module(signing)


class SigningSettingsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="opencompanion-signing-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.config = Path(self.temporary.name) / "local-signing.json"

    def write_config(self, value):
        self.config.write_text(json.dumps(value), encoding="utf-8")

    def test_missing_config_defaults_to_ad_hoc_without_team(self):
        self.assertEqual(signing.load_settings(self.config, {}), ("-", ""))

    def test_local_identity_and_team_are_used(self):
        self.write_config({"identity": "Apple Development: Fixture Developer", "team": "ABC123DE45"})
        self.assertEqual(signing.load_settings(self.config, {}),
                         ("Apple Development: Fixture Developer", "ABC123DE45"))

    def test_environment_overrides_each_local_setting_independently(self):
        self.write_config({"identity": "Local Identity", "team": "ABC123DE45"})
        cases = (
            ({"CODE_SIGN_IDENTITY": "Environment Identity"},
             ("Environment Identity", "ABC123DE45")),
            ({"DEVELOPMENT_TEAM": "12345ABCDE"}, ("Local Identity", "12345ABCDE")),
            ({"CODE_SIGN_IDENTITY": "Environment Identity", "DEVELOPMENT_TEAM": "12345ABCDE"},
             ("Environment Identity", "12345ABCDE")),
        )
        for environment, expected in cases:
            with self.subTest(environment=environment):
                self.assertEqual(signing.load_settings(self.config, environment), expected)

    def test_explicit_ad_hoc_drops_local_team_unless_environment_team_is_explicit(self):
        self.write_config({"identity": "Local Identity", "team": "ABC123DE45"})
        self.assertEqual(signing.load_settings(self.config, {"CODE_SIGN_IDENTITY": "-"}),
                         ("-", ""))
        self.assertEqual(signing.load_settings(self.config, {
            "CODE_SIGN_IDENTITY": "-", "DEVELOPMENT_TEAM": "12345ABCDE"}),
            ("-", "12345ABCDE"))

    def test_ci_skips_even_malformed_local_config_and_only_uses_explicit_environment(self):
        self.config.write_text("this is not JSON", encoding="utf-8")
        self.assertEqual(signing.load_settings(self.config, {"CI": "true"}), ("-", ""))
        self.assertEqual(signing.load_settings(self.config, {
            "CI": "true", "CODE_SIGN_IDENTITY": "CI Identity", "DEVELOPMENT_TEAM": "ABC123DE45"}),
            ("CI Identity", "ABC123DE45"))
        self.assertEqual(signing.load_settings(self.config, {
            "CI": "true", "CODE_SIGN_IDENTITY": "CI Identity"}), ("CI Identity", ""))

    def test_malformed_config_fails_even_when_environment_could_override_it(self):
        for contents in ("not JSON", "{", '["identity"]'):
            with self.subTest(contents=contents):
                self.config.write_text(contents, encoding="utf-8")
                with self.assertRaises(ValueError):
                    signing.load_settings(self.config, {"CODE_SIGN_IDENTITY": "Environment Identity"})

    def test_unexpected_keys_or_non_string_values_are_rejected(self):
        invalid = (
            {},
            {"team": "ABC123DE45"},
            {"identity": "Fixture Identity", "unexpected": "value"},
            {"identity": 42},
            {"identity": None},
            {"identity": True},
            {"team": 1234567890},
            {"team": None},
            {"team": ["ABC123DE45"]},
        )
        for value in invalid:
            with self.subTest(value=value):
                self.write_config(value)
                with self.assertRaises(ValueError):
                    signing.load_settings(self.config, {})

    def test_identity_length_and_control_characters_are_validated(self):
        self.write_config({"identity": "x" * 200, "team": ""})
        self.assertEqual(signing.load_settings(self.config, {}), ("x" * 200, ""))
        for identity in ("x" * 201, "Line\nBreak", "Carriage\rReturn", "Tab\tName",
                         "Null\x00Name", "Delete\x7fName"):
            with self.subTest(identity=repr(identity)):
                self.write_config({"identity": identity})
                with self.assertRaises(ValueError):
                    signing.load_settings(self.config, {})

    def test_team_requires_exactly_ten_uppercase_ascii_letters_or_digits(self):
        for team in ("abc123DE45", "ABC123DE4", "ABC123DE456", "ABC12-DE45", " ABC123DE45",
                     "ABC123DE45\n", "ＡBC123DE45"):
            with self.subTest(team=repr(team)):
                self.write_config({"identity": "Fixture Identity", "team": team})
                with self.assertRaises(ValueError):
                    signing.load_settings(self.config, {})

    def test_invalid_environment_settings_are_rejected_including_ci(self):
        for environment in (
            {"CODE_SIGN_IDENTITY": "Invalid\nIdentity"},
            {"CI": "true", "CODE_SIGN_IDENTITY": "x" * 201},
            {"DEVELOPMENT_TEAM": "invalid"},
            {"CI": "true", "DEVELOPMENT_TEAM": "abc123DE45"},
        ):
            with self.subTest(environment=environment):
                with self.assertRaises(ValueError):
                    signing.load_settings(self.config, environment)


if __name__ == "__main__":
    unittest.main()
