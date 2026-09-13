"""Exercise the distributed files with a clean HOME and only the system PATH."""
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

APP = pathlib.Path(sys.argv.pop(1) if len(sys.argv) > 1 else "dist/AgentChirp.app").resolve()


class BundleTests(unittest.TestCase):
    def test_metadata_and_signature(self):
        info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "com.hosseintoussi.agentchirp")
        self.assertEqual(info["LSMinimumSystemVersion"], "13.0")
        self.assertTrue(info["LSUIElement"])
        self.assertTrue(info["NSAppleEventsUsageDescription"])
        self.assertTrue((APP / "Contents/Resources/AgentChirp.icns").is_file())
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(APP)], check=True)
        if not info["AgentChirpDevelopment"]:
            for product in ["agentchirp", "agentchirp-hook"]:
                arches = subprocess.check_output(["lipo", "-archs", str(APP / "Contents/MacOS" / product)], text=True)
                self.assertEqual(set(arches.split()), {"arm64", "x86_64"})
            self.assertTrue(info["SUPublicEDKey"])

    def test_installed_helper_without_python_or_brew(self):
        with tempfile.TemporaryDirectory(prefix="agentchirp clean home ") as directory:
            home = pathlib.Path(directory)
            hooks = home / ".codex/hooks"
            hooks.mkdir(parents=True)
            shutil.copy2(APP / "Contents/Resources/agentchirp.sh", hooks)
            shutil.copy2(APP / "Contents/MacOS/agentchirp-hook", hooks)
            subprocess.run(["codesign", "--verify", "--strict", str(hooks / "agentchirp-hook")], check=True)
            env = dict(os.environ, HOME=directory, CODEX_HOME=str(home / ".codex"), PATH="/usr/bin:/bin:/usr/sbin:/sbin")
            for provider, args, folder in [
                ("claude", ["working"], home / ".claude/agentchirp/sessions"),
                ("codex", ["codex"], home / ".codex/agentchirp/sessions"),
            ]:
                result = subprocess.run(["/bin/bash", str(hooks / "agentchirp.sh"), *args],
                    input=json.dumps(dict(session_id="bundle-test", hook_event_name="UserPromptSubmit", cwd="/tmp/project")),
                    text=True, capture_output=True, env=env, check=True)
                self.assertEqual(result.stderr, "")
                if provider == "codex":
                    self.assertEqual(json.loads(result.stdout), {})
                self.assertEqual(json.loads((folder / "bundle-test.json").read_text())["state"], "working")
            # A shell-only fake Codex proves the launcher itself needs no interpreter.
            binary = home / "bin"
            binary.mkdir()
            fake = binary / "codex"
            fake.write_text('#!/bin/sh\nif [ "$1" = app-server ]; then printf \'{"socketPath":"/tmp/socket with spaces.sock"}\\n\'; else printf \'%s\\n\' "$@" > "$CAPTURE"; fi\n')
            fake.chmod(0o755)
            env.update(PATH=str(binary) + ":" + env["PATH"], CAPTURE=str(home / "args"))
            subprocess.run([str(APP / "Contents/Resources/codex-chirp"), "resume", "--last"], cwd=home, env=env, check=True)
            self.assertEqual((home / "args").read_text().splitlines(),
                             ["--remote", "unix:///tmp/socket with spaces.sock", "--cd", str(home.resolve()), "resume", "--last"])


if __name__ == "__main__":
    unittest.main()
