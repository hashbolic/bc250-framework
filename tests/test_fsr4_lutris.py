import importlib.util
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("fsr4_lutris", HERE / "helpers/fsr4_lutris.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class LutrisFsR4Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        home = Path(self.temp.name)
        m.HOME = home
        m.STATE_DIR = home / ".local/share/bc250-framework/fsr4-research"
        m.STATE = m.STATE_DIR / "lutris-state.json"
        m.BACKUP = m.STATE_DIR / "cyberpunk-original.yml"
        m.GAME_DIRS = [home / ".config/lutris/games"]
        m.GAME_DIRS[0].mkdir(parents=True)
        self.game = m.GAME_DIRS[0] / "cyberpunk-2077-111.yml"
        self.content = ("name: Cyberpunk 2077\n"
                        "wine:\n  version: protonge-latest-bc250\n"
                        "system:\n  env:\n    MANGOHUD: '0'\n"
                        "    PROTON_FSR4_UPGRADE: '4.1.1'\n"
                        "    PROTON_USE_OPTISCALER: '1'\n")
        self.game.write_text(self.content, encoding="utf-8")

    def test_applies_and_restores_verbatim(self):
        m.apply("default")
        data = self.game.read_text()
        self.assertIn("MANGOHUD: '1'", data)
        self.assertIn("MANGOHUD_CONFIGFILE:", data)
        self.assertIn("PROTON_FSR4_UPGRADE: '4.1.1'", data)
        self.assertIn("PROTON_USE_OPTISCALER: '1'", data)
        self.assertEqual(data.count("MANGOHUD:"), 1)
        m.restore()
        self.assertEqual(self.game.read_text(), self.content)
        self.assertFalse(m.STATE.exists())

    def test_switches_modes_without_stacking_old_overrides(self):
        m.apply("default")
        dump = m.STATE_DIR / "shader-dump"
        m.apply("dump")
        data = self.game.read_text()
        self.assertIn("VKD3D_SHADER_DUMP_PATH:", data)
        self.assertEqual(data.count("MANGOHUD_CONFIGFILE:"), 1)
        self.assertTrue(dump.exists())
        m.apply("default")
        self.assertNotIn("VKD3D_SHADER_DUMP_PATH:", self.game.read_text())
        m.restore()

    def test_preserves_external_edits(self):
        m.apply("default")
        self.game.write_text(self.game.read_text() + "\n# user edit\n")
        with self.assertRaises(SystemExit):
            m.restore()
        self.assertTrue(m.BACKUP.exists())

    def test_refuses_inline_system_environment(self):
        with self.assertRaises(SystemExit):
            m.system_env_edit("system:\n  env: {foo: bar}\n", {"MANGOHUD": "1"})


if __name__ == "__main__":
    unittest.main()
