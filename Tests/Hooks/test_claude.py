"""Run the bundled Claude adapter against a temporary HOME; never touches real state."""
import json
import os
import pathlib
import subprocess
import tempfile
import time
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "ccbeacon.sh"


class ClaudeHookTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = pathlib.Path(self.temp.name)
        self.path = self.home / ".claude" / "cc-sessions" / "session.json"

    def tearDown(self):
        self.temp.cleanup()

    def fire(self, state, event, **fields):
        payload = dict(session_id="session", hook_event_name=event, cwd="/tmp/project",
                       transcript_path="/tmp/project/transcript.jsonl", **fields)
        env = dict(os.environ, HOME=str(self.home))
        subprocess.run(["/bin/bash", str(SCRIPT), state], input=json.dumps(payload), text=True,
                       capture_output=True, check=True, env=env)
        return json.loads(self.path.read_text()) if self.path.exists() else None

    def test_permission_grant_resumes_working(self):
        self.assertEqual(self.fire("working", "UserPromptSubmit")["state"], "working")
        waiting = self.fire("waiting", "Notification", message="Claude needs your permission to use Bash")
        self.assertEqual(waiting["state"], "waiting")
        self.assertEqual(waiting["detail"], "Claude needs your permission to use Bash")
        resumed = self.fire("resume", "PreToolUse", tool_name="Bash")
        self.assertEqual(resumed["state"], "working")
        self.assertEqual(resumed["detail"], "")

    def test_tool_calls_while_working_are_free(self):
        first = self.fire("working", "UserPromptSubmit")
        # Backdate the file so a rewrite would be visible as a newer mtime.
        old = time.time() - 100
        os.utime(self.path, (old, old))
        again = self.fire("resume", "PreToolUse", tool_name="Read")
        self.assertEqual(again, first)
        self.assertLess(abs(os.path.getmtime(self.path) - old), 1, "fast path must not rewrite the file")

    def test_repeated_state_keeps_its_clock(self):
        first = self.fire("working", "UserPromptSubmit")
        rewritten = json.loads(self.path.read_text())
        rewritten["ts"] = first["ts"] - 300
        self.path.write_text(json.dumps(rewritten))
        second = self.fire("working", "UserPromptSubmit")
        self.assertEqual(second["ts"], first["ts"] - 300)

    def test_resume_without_a_file_records_working(self):
        self.assertEqual(self.fire("resume", "PreToolUse", tool_name="Bash")["state"], "working")


if __name__ == "__main__":
    unittest.main()
