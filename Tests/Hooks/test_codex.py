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

    def test_event_freshness_is_separate_from_state_clock(self):
        first = self.fire("UserPromptSubmit")
        first.update(ts=first["ts"] - 300, updated_at=first["updated_at"] - 300)
        self.path.write_text(json.dumps(first))
        second = self.fire("PreToolUse")
        self.assertEqual(second["ts"], first["ts"])
        self.assertGreater(second["updated_at"], first["updated_at"] + 290)

    def test_resumed_owner_drops_abandoned_turn_state(self):
        # A real parent named codex lets the native helper discover ownership.
        owner = pathlib.Path(self.temp.name) / "codex"
        source = """
        #include <unistd.h>
        #include <sys/wait.h>
        int main(int argc, char **argv) {
            pid_t child = fork();
            if (child < 0) return 2;
            if (child == 0) {
                execl(argv[1], argv[1], "codex", argv[2], (char *)0);
                _exit(127);
            }
            int status;
            if (waitpid(child, &status, 0) < 0) return 3;
            return WIFEXITED(status) ? WEXITSTATUS(status) : 4;
        }
        """
        subprocess.run(["cc", "-x", "c", "-o", str(owner), "-"], input=source,
                       text=True, capture_output=True, check=True)
        helper = SCRIPT.parent / ".build/release/agentchirp-hook"
        self.directory.mkdir(parents=True)
        for state in ("idle", "working", "waiting"):
            self.path.write_text(json.dumps(dict(session_id="session", state=state, ts=100,
                agent_pid=99999999, turn_id="abandoned", last_event="Interrupt",
                pending_tools=["old-request"], detail="input", cwd="/tmp/project")))
            result = subprocess.run([str(owner), str(helper), str(self.directory)],
                input=json.dumps(dict(session_id="session", hook_event_name="SessionStart")),
                text=True, capture_output=True, check=True)
            self.assertEqual(json.loads(result.stdout), {})
            resumed = json.loads(self.path.read_text())
            self.assertEqual(resumed["state"], "idle")
            self.assertGreater(resumed["agent_pid"], 0)
            self.assertNotEqual(resumed["agent_pid"], 99999999)
            self.assertGreater(resumed["ts"], 100)
            self.assertGreaterEqual(resumed["updated_at"], resumed["ts"])
            self.assertEqual(resumed["turn_id"], "")
            self.assertEqual(resumed["pending_tools"], [])
            self.assertEqual(resumed["cwd"], "/tmp/project")

    def test_mixed_request_kinds_and_legacy_pending_requests(self):
        self.fire("UserPromptSubmit")
        self.fire("PreToolUse", tool_name="request_user_input", tool_use_id="question")
        mixed = self.fire("PermissionRequest", tool_name="Bash")
        self.assertEqual(mixed["detail"], "input")
        remaining = self.fire("PostToolUse", tool_name="request_user_input", tool_use_id="question")
        self.assertEqual(remaining["detail"], "permission")
        self.assertEqual(list(remaining["pending_kinds"].values()), ["permission"])
        # Upgrading an old record cannot turn untyped requests into audible input asks.
        remaining.pop("pending_kinds")
        remaining["detail"] = "input"
        self.path.write_text(json.dumps(remaining))
        legacy = self.fire("PreToolUse", tool_name="Read")
        self.assertEqual(legacy["detail"], "permission")
        self.assertEqual(self.fire("PostToolUse", tool_name="Bash")["pending_kinds"], {})

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
