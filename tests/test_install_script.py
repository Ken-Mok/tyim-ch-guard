"""Exercise installation and rollback using fake CLIs and a private fixture root."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parent.parent


class InstallScriptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.user_root = self.root / "account"
        self.fake_bin = self.root / "commands"
        self.fake_bin.mkdir()
        self.install_dir = self.user_root / "Library/Application Support/tyim-ch-guard"
        self.install_dir.mkdir(parents=True)
        self.plist = self.user_root / "Library/LaunchAgents/com.ken.tyim-ch-guard.plist"
        self.plist.parent.mkdir(parents=True)
        self.plist.write_bytes(plistlib.dumps({"Label": "com.ken.tyim-ch-guard",
            "ProgramArguments": [str(self.install_dir / "tyim-ch-guard")],
            "RunAtLoad": True, "KeepAlive": True, "CustomSetting": "preserve me"}))
        (self.install_dir / "tyim-ch-guard").write_bytes(b"original executable")
        (self.install_dir / "main.swift").write_bytes(b"original source")
        self.original = {p.name: p.read_bytes() for p in [self.plist,
            self.install_dir / "tyim-ch-guard", self.install_dir / "main.swift"]}
        self.state = self.root / "loaded"
        self.state.write_text("running")
        self.env = os.environ.copy()
        self.env.update({"PATH": str(self.fake_bin) + os.pathsep + self.env["PATH"],
            "TYIM_GUARD_USER_ROOT": str(self.user_root),
            "TYIM_GUARD_TEST_STATE": str(self.state)})
        self.command("codesign", "#!/bin/sh\nexit 0\n")
        self.command("open", "#!/bin/sh\nexit 0\n")
        self.command("swiftc", '''#!/usr/bin/env python3
import os, pathlib, sys
if os.environ.get("TYIM_GUARD_TEST_COMPILE_FAIL"):
    sys.exit(9)
out = pathlib.Path(sys.argv[sys.argv.index("-o") + 1])
out.write_text("#!/bin/sh\\ncase \\\"$1\\\" in\\n--version) echo 'tyim-ch-guard 1.1.1';;\\n--status) echo '{\\\"accessibility_granted\\\" : false, \\\"version\\\" : \\\"1.1.1\\\"}';;\\nesac\\n")
out.chmod(0o755)
''')
        self.command("launchctl", '''#!/usr/bin/env python3
import os, pathlib, sys
p = pathlib.Path(os.environ["TYIM_GUARD_TEST_STATE"])
command = sys.argv[1]
if command == "print":
    if not p.exists(): sys.exit(3)
    print("state = running\\n pid = 1234")
elif command == "bootout":
    p.unlink(missing_ok=True)
elif command == "bootstrap":
    marker = p.with_name("bootstrap-failed-once")
    if os.environ.get("TYIM_GUARD_TEST_FAIL_BOOTSTRAP") and not marker.exists():
        marker.touch()
        sys.exit(5)
    p.write_text("running")
elif command != "enable":
    sys.exit(2)
''')

    def command(self, name, text):
        p = self.fake_bin / name
        p.write_text(text)
        p.chmod(0o755)

    def install(self):
        return subprocess.run(["bash", str(REPOSITORY / "scripts/install.sh")],
                              env=self.env, text=True, capture_output=True)

    def test_upgrade_backs_up_files_preserves_plist_and_warns_about_permission(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ACTION REQUIRED", result.stdout)
        self.assertIn("Computer History settings were not changed", result.stdout)
        self.assertEqual(self.plist.read_bytes(), self.original[self.plist.name])
        self.assertEqual((self.install_dir / "main.swift").read_bytes(), (REPOSITORY / "Sources/main.swift").read_bytes())
        backups = list(self.install_dir.glob("backups-*"))
        self.assertEqual(len(backups), 1)
        for name, content in self.original.items():
            self.assertEqual((backups[0] / name).read_bytes(), content)
        self.assertTrue(self.state.exists())

    def test_failed_start_restores_original_files_and_service(self):
        self.env["TYIM_GUARD_TEST_FAIL_BOOTSTRAP"] = "1"
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Rollback result: 1", result.stderr)
        for name in ["tyim-ch-guard", "main.swift"]:
            self.assertEqual((self.install_dir / name).read_bytes(), self.original[name])
        self.assertEqual(self.plist.read_bytes(), self.original[self.plist.name])
        self.assertTrue(self.state.exists())

    def test_compile_failure_never_stops_or_changes_the_installation(self):
        self.env["TYIM_GUARD_TEST_COMPILE_FAIL"] = "1"
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.state.exists())
        for name in ["tyim-ch-guard", "main.swift"]:
            self.assertEqual((self.install_dir / name).read_bytes(), self.original[name])
        self.assertEqual(list(self.install_dir.glob("backups-*")), [])

    def test_first_install_creates_a_valid_login_agent(self):
        self.plist.unlink()
        (self.install_dir / "tyim-ch-guard").unlink()
        (self.install_dir / "main.swift").unlink()
        self.state.unlink()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with self.plist.open("rb") as stream:
            config = plistlib.load(stream)
        self.assertEqual(config["ProgramArguments"], [str(self.install_dir / "tyim-ch-guard")])
        self.assertTrue(config["RunAtLoad"])
        self.assertTrue(config["KeepAlive"])
        self.assertTrue(self.state.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
