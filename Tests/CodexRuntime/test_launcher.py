import json
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]

class LauncherTests(unittest.TestCase):
    def test_start_server_and_forward_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            hooks = home / "hooks"
            hooks.mkdir()
            adapter = hooks / "agentchirp.sh"
            adapter.write_bytes((ROOT / "agentchirp.sh").read_bytes())
            adapter.chmod(0o755)
            fake = home / "codex"
            fake.write_text('''#!/usr/bin/env python3
import json,os,sys
if sys.argv[1:] == ["app-server","daemon","start"]:
 print(json.dumps({"socketPath":"/tmp/socket with spaces.sock"}))
else:
 with open(os.environ["CAPTURE"],"w") as f: json.dump(sys.argv[1:],f)
''')
            fake.chmod(0o755)
            env = dict(os.environ, CODEX_HOME=directory, PATH=directory + os.pathsep + os.environ["PATH"], CAPTURE=str(home / "args"))
            for launcher in ["codex-chirp"]:
                subprocess.run([str(ROOT / launcher), "resume", "--last"], env=env, cwd=directory, check=True)
                self.assertEqual(json.loads((home / "args").read_text()), ["--remote", "unix:///tmp/socket with spaces.sock", "--cd", str(home.resolve()), "resume", "--last"])
                result = subprocess.run([str(ROOT / launcher), "--remote", "ws://other"], env=env, capture_output=True)
                self.assertEqual(result.returncode, 2)

    def test_failed_daemon_does_not_launch_standalone(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "codex"
            path.write_text("#!/bin/sh\nexit 7\n")
            path.chmod(0o755)
            result = subprocess.run(["bash", str(ROOT / "agentchirp.sh"), "launch-codex"], env=dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"]))
            self.assertEqual(result.returncode, 7)

if __name__ == "__main__":
    unittest.main()
