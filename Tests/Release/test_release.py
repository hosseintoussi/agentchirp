"""Execute release version selection against temporary Git histories."""
import os
import pathlib
import subprocess
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/release.yml").read_text()
TAG_STEP = textwrap.dedent(WORKFLOW.split("      - name: Find version tag on this commit\n", 1)[1]
                          .split("        run: |\n", 1)[1].split("\n\n", 1)[0])


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = pathlib.Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.version = self.repo / "Sources/AgentChirpCore/Version.swift"
        self.version.parent.mkdir(parents=True)
        self.commit("1.0.0")

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True, stderr=subprocess.DEVNULL).strip()

    def commit(self, version):
        self.version.write_text(f'public let appVersion = "{version}"\n')
        self.git("add", ".")
        self.git("commit", "-qm", version)
        return self.git("rev-parse", "HEAD")

    def select(self):
        output = self.repo / "output"
        result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", TAG_STEP], cwd=self.repo,
                                env=dict(os.environ, GITHUB_OUTPUT=str(output)), capture_output=True, text=True)
        return result.returncode, output.read_text().strip() if output.exists() else ""

    def test_untagged_commit_is_skipped(self):
        self.assertEqual(self.select(), (0, "name="))

    def test_checked_out_ci_commit_wins_over_newer_branch(self):
        tested = self.git("rev-parse", "HEAD")
        self.git("tag", "v1.0.0")
        self.commit("1.1.0")
        self.git("checkout", "--detach", tested)
        self.assertEqual(self.select(), (0, "name=v1.0.0"))

    def test_mismatched_binary_version_fails(self):
        self.git("tag", "v2.0.0")
        self.assertNotEqual(self.select()[0], 0)

    def test_annotated_tag_is_supported(self):
        self.git("tag", "-a", "v1.0.0", "-m", "release")
        self.assertEqual(self.select(), (0, "name=v1.0.0"))


if __name__ == "__main__":
    unittest.main()
