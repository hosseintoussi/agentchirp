"""Run the bundled Codex adapter with fixtures; never writes real agent settings."""
import json
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "agentchirp.sh"


class CodexHookTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = pathlib.Path(self.temp.name) / "state with spaces"
        self.path = self.directory / "session.json"

    def tearDown(self):
        self.temp.cleanup()

    def fire(self, event, turn="t1", **fields):
        payload = dict(session_id="session", hook_event_name=event, turn_id=turn,
                       cwd="/tmp/project", model="gpt-test", **fields)
        result = subprocess.run(["/bin/bash", str(SCRIPT), "codex", str(self.directory)],
                                input=json.dumps(payload), text=True, capture_output=True, check=True)
        self.assertEqual(json.loads(result.stdout), {})
        self.assertEqual(result.stderr, "")
        return json.loads(self.path.read_text()) if self.path.exists() else None

    def test_lifecycle(self):
        self.assertEqual(self.fire("SessionStart")["state"], "idle")
        self.assertEqual(self.fire("UserPromptSubmit")["state"], "working")
        self.assertEqual(self.fire("PermissionRequest", tool_name="Bash", tool_input={"command": "pwd"})["state"], "waiting")
        self.assertEqual(self.fire("PostToolUse", tool_name="Bash", tool_input={"command": "pwd"})["state"], "working")
        self.assertEqual(self.fire("Stop")["state"], "done")
        self.assertIsNone(self.fire("SessionEnd"))

    def test_turn_isolation(self):
        self.fire("UserPromptSubmit", "old")
        self.fire("Stop", "old")
        self.assertEqual(self.fire("PermissionRequest", "old")["state"], "done")
        self.fire("UserPromptSubmit", "new")
        self.assertEqual(self.fire("Stop", "old")["state"], "working")
        self.assertEqual(self.fire("SessionStart", "new")["state"], "working")

    def test_detail_records_the_ask(self):
        self.fire("UserPromptSubmit")
        command = "  git   push origin main\n"
        state = self.fire("PermissionRequest", tool_name="Bash", tool_input={"command": command})
        self.assertEqual(state["detail"], "permission")
        self.assertNotIn("git push", self.path.read_text())
        state = self.fire("PostToolUse", tool_name="Bash", tool_input={"command": command})
        self.assertEqual(state["detail"], "")
        state = self.fire("PermissionRequest", tool_name="apply_patch", tool_input={"patch": "x"})
        self.assertEqual(state["detail"], "permission")
        self.assertEqual(self.fire("Stop")["detail"], "")

    def test_parallel_approvals(self):
        self.fire("UserPromptSubmit")
        for command in ("one", "two"):
            self.fire("PermissionRequest", tool_name="Bash", tool_input={"command": command})
        self.assertEqual(self.fire("PostToolUse", tool_name="Bash", tool_input={"command": "one"})["state"], "waiting")
        self.assertEqual(self.fire("PostToolUse", tool_name="Bash", tool_input={"command": "two"})["state"], "working")

    def test_approval_description_does_not_prevent_resume(self):
        self.fire("UserPromptSubmit")
        self.fire("PermissionRequest", tool_name="Bash", tool_input={"command": "pwd", "description": "Approve?"})
        self.assertEqual(self.fire("PostToolUse", tool_name="Bash", tool_input={"command": "pwd"})["state"], "working")

    def test_input_question(self):
        self.fire("UserPromptSubmit")
        self.assertEqual(self.fire("PreToolUse", tool_name="request_user_input", tool_input={})["state"], "waiting")
        self.assertEqual(self.fire("PostToolUse", tool_name="request_user_input", tool_input={})["state"], "working")

    def test_question_answer_correlates_by_invocation(self):
        self.fire("UserPromptSubmit")
        state = self.fire("PreToolUse", tool_name="request_user_input", tool_use_id="question-1", tool_input={"questions": ["One?"]})
        self.assertEqual(state["state"], "waiting")
        state = self.fire("PostToolUse", tool_name="request_user_input", tool_use_id="question-1", tool_input={})
        self.assertEqual(state["state"], "working")
        self.assertEqual(state["pending_tools"], [])

    def test_parallel_questions_keep_other_request_waiting(self):
        self.fire("UserPromptSubmit")
        for call in ("a", "b"):
            self.fire("PreToolUse", tool_name="request_user_input", tool_use_id=call, tool_input={})
        self.assertEqual(self.fire("PostToolUse", tool_name="request_user_input", tool_use_id="a", tool_input={})["state"], "waiting")
        self.assertEqual(self.fire("PostToolUse", tool_name="request_user_input", tool_use_id="b", tool_input={})["state"], "working")

    def test_permission_without_id_matches_completion_with_id(self):
        self.fire("UserPromptSubmit")
        self.fire("PermissionRequest", tool_name="Bash", tool_input={"command": "long command"})
        self.assertEqual(self.fire("PostToolUse", tool_name="Bash", tool_use_id="exec-1", tool_input={"command": "long command"})["state"], "working")

    def test_interruption(self):
        self.fire("UserPromptSubmit")
        self.fire("PermissionRequest")
        state = self.fire("Interrupt")
        self.assertEqual(state["state"], "idle")
        self.assertEqual(state["pending_tools"], [])
        self.assertEqual(self.fire("PostToolUse")["last_event"], "Interrupt")

    def test_clock_and_model(self):
        first = self.fire("UserPromptSubmit")
        second = self.fire("PreToolUse")
        self.assertEqual(first["ts"], second["ts"])
        self.assertEqual(second["model"], "gpt-test")
        self.assertEqual(second["provider"], "codex")

    def test_child_does_not_finish_parent(self):
        self.fire("UserPromptSubmit")
        transcript = pathlib.Path(self.temp.name) / "child.jsonl"
        transcript.write_text(json.dumps({"type": "session_meta", "payload": {"id": "child"}}) + "\n")
        self.assertEqual(self.fire("Stop", transcript_path=str(transcript))["state"], "working")

    def test_malformed_payload(self):
        for payload in ("{", "[]", '{"session_id":"../escape","hook_event_name":"Stop"}'):
            result = subprocess.run(["bash", str(SCRIPT), "codex", str(self.directory)],
                                    input=payload, text=True, capture_output=True, check=True)
            self.assertEqual(json.loads(result.stdout), {})
        self.assertFalse(self.path.exists())


if __name__ == "__main__":
    unittest.main()
