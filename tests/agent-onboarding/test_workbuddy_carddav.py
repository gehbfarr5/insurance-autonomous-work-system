import importlib.util
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "agent-onboarding" / "workbuddy_carddav.py"
spec = importlib.util.spec_from_file_location("workbuddy_carddav", SCRIPT)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class TestWorkBuddyConfig(unittest.TestCase):
    def test_new_file_dry_run_no_write(self):
        with TemporaryDirectory() as t:
            p = Path(t) / "mcp.json"
            self.assertEqual(m.install(p), "DRY_RUN_READY")
            self.assertFalse(p.exists())

    def test_new_file_apply(self):
        with TemporaryDirectory() as t:
            p = Path(t) / ".workbuddy" / "mcp.json"
            self.assertEqual(m.install(p, apply=True), "INSTALLED_CONFIG_ONLY_OAUTH_REQUIRED")
            self.assertEqual(json.loads(p.read_text())["mcpServers"]["icloud-carddav"], m.ENTRY)
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)

    def test_preserve_existing_and_backup(self):
        with TemporaryDirectory() as t:
            p = Path(t) / "mcp.json"
            original = {"mcpServers": {"andromeld": {"type": "stdio", "command": "echo", "disabled": True}}, "other": 1}
            p.write_text(json.dumps(original))
            self.assertEqual(m.install(p, apply=True), "INSTALLED_CONFIG_ONLY_OAUTH_REQUIRED")
            updated = json.loads(p.read_text())
            self.assertEqual(updated["other"], 1)
            self.assertEqual(updated["mcpServers"]["andromeld"], original["mcpServers"]["andromeld"])
            self.assertEqual(updated["mcpServers"]["icloud-carddav"], m.ENTRY)
            backups = list(p.parent.glob("mcp.json.backup-*"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(json.loads(backups[0].read_text()), original)

    def test_idempotent(self):
        with TemporaryDirectory() as t:
            p = Path(t) / "mcp.json"
            m.install(p, apply=True)
            self.assertEqual(m.install(p, apply=True), "ALREADY_CONFIGURED")
            self.assertEqual(len(list(p.parent.glob("*.backup-*"))), 0)

    def test_conflict_keeps_existing(self):
        with TemporaryDirectory() as t:
            p = Path(t) / "mcp.json"
            p.write_text('{"mcpServers":{"icloud-carddav":{"url":"https://example.org/mcp"}}}')
            old = p.read_bytes()
            with self.assertRaisesRegex(RuntimeError, "refusing"):
                m.install(p, apply=True)
            self.assertEqual(old, p.read_bytes())

    def test_malformed_json_refused(self):
        with TemporaryDirectory() as t:
            p = Path(t) / "mcp.json"
            p.write_text('{broken')
            with self.assertRaisesRegex(RuntimeError, "invalid"):
                m.install(p, apply=True)
            self.assertEqual(p.read_text(), '{broken')


if __name__ == "__main__":
    unittest.main()
