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
        self.assertEqual(waiting["detail"], "permission")
        self.assertNotIn("Bash", self.path.read_text())
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


    def test_failure_preserves_outcome(self):
        self.fire("working", "UserPromptSubmit")
        state = self.fire("done", "StopFailure")
        self.assertEqual(state["last_event"], "StopFailure")
        self.assertEqual(state["state"], "done")

    def test_input_detail_is_generic(self):
        state = self.fire("waiting", "Notification", notification_type="elicitation_dialog", message="Private question")
        self.assertEqual(state["detail"], "input")
        self.assertNotIn("Private", self.path.read_text())

    def test_session_end_preserves_lock_inode(self):
        import hashlib
        self.fire("idle", "SessionStart")
        bucket = int(hashlib.sha256(b"session").hexdigest(), 16) % 64
        lock = self.path.parent / ".locks" / str(bucket)
        inode = lock.stat().st_ino
        self.assertIsNone(self.fire("done", "SessionEnd"))
        self.assertEqual(lock.stat().st_ino, inode)
        self.fire("idle", "SessionStart")
        self.assertEqual(lock.stat().st_ino, inode)

    def test_queued_resume_cannot_overwrite_stop(self):
        import fcntl
        import hashlib
        self.fire("waiting", "Notification")
        bucket = int(hashlib.sha256(b"session").hexdigest(), 16) % 64
        lock = self.path.parent / ".locks" / str(bucket)
        with lock.open("a") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            payload = dict(session_id="session", hook_event_name="PreToolUse", cwd="/tmp/project")
            proc = subprocess.Popen(["/bin/bash", str(SCRIPT), "resume"], stdin=subprocess.PIPE,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                    env=dict(os.environ, HOME=str(self.home)))
            try:
                proc.stdin.write(json.dumps(payload))
                proc.stdin.close()
                # The writer must remain blocked while we own its bucket lock.
                with self.assertRaises(subprocess.TimeoutExpired):
                    proc.wait(timeout=0.2)
                state = json.loads(self.path.read_text())
                state.update(state="done", last_event="Stop")
                temporary = self.path.with_suffix(".tmp")
                temporary.write_text(json.dumps(state))
                temporary.replace(self.path)
                fcntl.flock(held, fcntl.LOCK_UN)
                self.assertEqual(proc.wait(timeout=5), 0)
                self.assertEqual(json.loads(self.path.read_text())["state"], "done")
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
                proc.stdout.close()
                proc.stderr.close()


if __name__ == "__main__":
    unittest.main()
