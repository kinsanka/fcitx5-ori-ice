"""Exercise real installer configuration changes in an isolated temporary HOME."""
import configparser
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

import yaml


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "install.sh").read_text(encoding="utf-8")
PYTHON = SCRIPT.split("<<'PY_CONFIG'\n", 1)[1].split("\nPY_CONFIG\n", 1)[0]
CONFIG = {"__name__": "installer_config"}
exec(compile(PYTHON, "install.sh:embedded-python", "exec"), CONFIG)


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.config = self.root / "配置 with spaces"
        self.data = self.root / "data"
        self.state = self.root / "state"
        self.niri = self.config / "niri/config.kdl"
        self.niri.parent.mkdir(parents=True)
        self.original = 'environment {\n    TEST "keep"\n}\ninput { keyboard { xkb { layout "us"; }; }; }\n'
        self.niri.write_text(self.original, encoding="utf-8")
        self.env = patch.dict(os.environ, {
            "CONFIG_ROOT": str(self.config), "DATA_ROOT": str(self.data),
            "STATE_ROOT": str(self.state), "NIRI_CONFIG": str(self.niri),
            "ICE_REV": "ice-test", "ORI_REV": "ori-test",
        })
        self.env.start()
        self.work = self.root / "work"
        (self.work / "ice/lua").mkdir(parents=True)
        (self.work / "ice/build").mkdir()
        (self.work / "ice/build/not-for-install.txt").write_text("skip")
        (self.work / "ice/default.yaml").write_text("config_version: '2026'\n")
        (self.work / "ice/custom_phrase.txt").write_text("upstream phrases")
        (self.work / "ice/lua/date.lua").write_text("return 1")
        for name in ["OriDark", "OriLight"]:
            directory = self.work / "ori" / name
            directory.mkdir(parents=True)
            (directory / "theme.conf").write_text("[Metadata]\nName=" + name)

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def apply(self, theme="dark", schema="rime_ice"):
        CONFIG["apply"](self.work, theme, schema)

    def test_install_preserves_niri_and_sets_full_pinyin(self):
        self.apply()
        text = self.niri.read_text(encoding="utf-8")
        self.assertTrue(text.startswith(self.original.rstrip()))
        self.assertIn('include "', text)
        self.assertIn("配置 with spaces", text)
        settings = yaml.safe_load((self.config / "fcitx5/rime/default.custom.yaml").read_text())
        self.assertEqual(settings["patch"]["schema_list"], [{"schema": "rime_ice"}])
        self.assertFalse((self.config / "fcitx5/rime/build/not-for-install.txt").exists())
        self.assertTrue((self.data / "fcitx5/themes/OriDark/theme.conf").exists())

    def test_reinstall_has_one_include_and_one_managed_group(self):
        self.apply()
        self.apply("light", "double_pinyin_flypy")
        self.assertEqual(self.niri.read_text(encoding="utf-8").count("// BEGIN fcitx5-ori-ice"), 1)
        profile = (self.config / "fcitx5/profile").read_text()
        self.assertEqual(profile.count("Name=Ori Ice"), 1)
        self.assertEqual(profile.count("Name=rime"), 1)
        classic = (self.config / "fcitx5/conf/classicui.conf").read_text()
        self.assertIn("Theme=OriLight", classic)
        selected = yaml.safe_load((self.config / "fcitx5/rime/user.yaml").read_text())
        self.assertEqual(selected["var"]["previously_selected_schema"], "double_pinyin_flypy")

    def test_existing_groups_layout_and_custom_settings_survive(self):
        profile_path = self.config / "fcitx5/profile"
        profile_path.parent.mkdir(parents=True)
        profile_path.write_text('[Groups/0]\nName=Existing\nDefault Layout=de\nDefaultIM=pinyin\n'
                                '[Groups/0/Items/0]\nName=pinyin\nLayout=\n[GroupOrder]\n0=Existing\n')
        rime = self.config / "fcitx5/rime"
        rime.mkdir()
        (rime / "custom_phrase.txt").write_text("my phrases")
        (rime / "my.userdb").mkdir()
        (rime / "my.userdb/data").write_bytes(b"personal data")
        (rime / "default.custom.yaml").write_text('patch:\n  menu/page_size: 9\n')
        (rime / "rime_ice.custom.yaml").write_text('patch:\n  switches/@0/reset: 1\n')
        self.apply()
        self.assertEqual((rime / "custom_phrase.txt").read_text(), "my phrases")
        self.assertEqual((rime / "my.userdb/data").read_bytes(), b"personal data")
        custom = yaml.safe_load((rime / "default.custom.yaml").read_text())
        self.assertEqual(custom["patch"]["menu/page_size"], 9)
        self.assertIn("reset: 1", (rime / "rime_ice.custom.yaml").read_text())
        profile = configparser.ConfigParser()
        profile.read(profile_path)
        self.assertEqual(profile["Groups/0"]["DefaultIM"], "pinyin")
        self.assertEqual(profile["Groups/1"]["Default Layout"], "de")
        self.assertEqual(profile["GroupOrder"]["0"], "Ori Ice")
        self.assertEqual(profile["GroupOrder"]["1"], "Existing")

    def test_restore_exact_previous_content_and_remove_new_files(self):
        backup = self.root / "backup"
        backup.mkdir()
        CONFIG["snapshot"](backup)
        self.apply()
        CONFIG["restore"](backup)
        self.assertEqual(self.niri.read_text(encoding="utf-8"), self.original)
        self.assertFalse((self.config / "fcitx5/rime").exists())
        self.assertFalse((self.config / "niri/fcitx5-ori-ice.kdl").exists())
        self.assertFalse((self.config / "environment.d/90-fcitx5-ori-ice.conf").exists())
        self.assertFalse((self.state / "installed.json").exists())

    def test_restore_can_recover_deleted_niri_config(self):
        backup = self.root / "backup"
        backup.mkdir()
        CONFIG["snapshot"](backup)
        self.niri.unlink()
        CONFIG["preflight"](require_niri=False)
        CONFIG["restore"](backup)
        self.assertEqual(self.niri.read_text(encoding="utf-8"), self.original)

    def test_backup_cannot_restore_into_different_config_root(self):
        backup = self.root / "backup"
        backup.mkdir()
        CONFIG["snapshot"](backup)
        with patch.dict(os.environ, {"DATA_ROOT": str(self.root / "other-data")}):
            with self.assertRaisesRegex(ValueError, "路径"):
                CONFIG["restore"](backup)
        self.assertEqual(self.niri.read_text(encoding="utf-8"), self.original)

    def test_incomplete_backup_is_rejected_before_any_restore(self):
        self.apply()
        backup = self.root / "backup"
        backup.mkdir()
        CONFIG["snapshot"](backup)
        shutil.rmtree(backup / "0")
        with self.assertRaisesRegex(ValueError, "不完整"):
            CONFIG["restore"](backup)
        self.assertTrue((self.state / "installed.json").exists())

    def test_root_ini_keeps_unrelated_values_and_sections(self):
        result = CONFIG["root_ini"]("# comment\nTheme=old\nFont=Sans 14\n"
                                      "[Other]\nTheme=keep\n", {"Theme": "OriDark"})
        self.assertIn("# comment", result)
        self.assertIn("Font=Sans 14", result)
        self.assertIn("[Other]\nTheme=keep", result)

    def test_auto_theme_and_systemd_launcher_environment(self):
        self.apply("auto")
        classic = (self.config / "fcitx5/conf/classicui.conf").read_text()
        self.assertIn("UseDarkTheme=True", classic)
        fragment = (self.config / "niri/fcitx5-ori-ice.kdl").read_text(encoding="utf-8")
        self.assertIn("GTK_IM_MODULE null", fragment)
        session = (self.config / "fcitx5-ori-ice/session.sh").read_text()
        self.assertIn("unset-environment GTK_IM_MODULE", session)
        self.assertIn("import-environment XMODIFIERS QT_IM_MODULE QT_IM_MODULES", session)

    def test_invalid_custom_yaml_can_be_rolled_back(self):
        rime = self.config / "fcitx5/rime"
        rime.mkdir(parents=True)
        original = "patch: [wrong, type]\n"
        (rime / "default.custom.yaml").write_text(original)
        backup = self.root / "backup"
        backup.mkdir()
        CONFIG["snapshot"](backup)
        with self.assertRaisesRegex(ValueError, "映射"):
            self.apply()
        CONFIG["restore"](backup)
        self.assertEqual((rime / "default.custom.yaml").read_text(), original)
        self.assertFalse((rime / "lua").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
