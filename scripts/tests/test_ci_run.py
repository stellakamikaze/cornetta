"""windows/tools/ci-run.sh sceglie solo la run del push del tag, sul commit del tag (#3500).

  python3 -m unittest discover -s scripts/tests
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
CI_RUN = os.environ.get("CORNETTA_CI_RUN", os.path.join(ROOT, "windows", "tools", "ci-run.sh"))
TAG = "win-v0.4.0"


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class CiRunTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.repo = os.path.join(self.tmp, "repo")
        os.makedirs(self.repo)
        git(self.repo, "init", "-q")
        git(self.repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "uno")
        git(self.repo, "-c", "user.name=t", "-c", "user.email=t@t", "tag", "-a", TAG, "-m", "tag annotato")
        self.sha = git(self.repo, "rev-parse", "HEAD")
        bin_dir = os.path.join(self.tmp, "bin")
        os.makedirs(bin_dir)
        shutil.copy(os.path.join(HERE, "fake_gh.py"), os.path.join(bin_dir, "gh"))
        os.chmod(os.path.join(bin_dir, "gh"), 0o755)
        self.env = dict(os.environ, PATH=bin_dir + os.pathsep + os.environ["PATH"],
                        FAKE_GH_RUNS=os.path.join(self.tmp, "runs.json"), FAKE_GH_LOG=os.path.join(self.tmp, "gh.log"))

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_ci(self, runs, **env):
        with open(self.env["FAKE_GH_RUNS"], "w", encoding="utf-8") as f:
            json.dump(runs, f)
        return subprocess.run([CI_RUN, "0.4.0"], cwd=self.repo, env=dict(self.env, **env), capture_output=True, text=True)

    def run_of(self, run_id, event, sha):
        return {"databaseId": run_id, "event": event, "headSha": sha, "headBranch": TAG, "conclusion": "success"}

    def test_pull_request_from_fork_with_tag_name_is_never_chosen(self):
        # La PR da fork è la più recente: la versione vecchia (--limit 1 sul nome del ramo) la sceglieva.
        runs = [self.run_of(666, "pull_request", "f" * 40), self.run_of(42, "push", self.sha)]
        result = self.run_ci(runs)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "42")

    def test_only_fork_run_means_nothing_to_publish(self):
        result = self.run_ci([self.run_of(666, "pull_request", "f" * 40)])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "")
        self.assertIn("Nessuna run verde", result.stderr)

    def test_result_is_checked_even_if_gh_ignores_filters(self):
        # Un gh che non applica --event e --commit: decide il controllo su headSha ed evento.
        runs = [self.run_of(666, "pull_request", "f" * 40), self.run_of(7, "push", "e" * 40), self.run_of(42, "push", self.sha)]
        result = self.run_ci(runs, FAKE_GH_IGNORE_FILTERS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "42")

    def test_push_on_another_commit_is_refused(self):
        result = self.run_ci([self.run_of(7, "push", "e" * 40)], FAKE_GH_IGNORE_FILTERS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "")

    def test_asks_github_for_push_on_the_tag_commit(self):
        self.run_ci([self.run_of(42, "push", self.sha)])
        with open(self.env["FAKE_GH_LOG"], encoding="utf-8") as f:
            call = json.loads(f.readline())
        self.assertIn("--event", call)
        self.assertEqual(call[call.index("--event") + 1], "push")
        self.assertEqual(call[call.index("--commit") + 1], self.sha)

    def test_missing_tag_stops(self):
        git(self.repo, "tag", "-d", TAG)
        result = self.run_ci([self.run_of(42, "push", self.sha)])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Il tag win-v0.4.0 non c'è", result.stderr)


if __name__ == "__main__":
    unittest.main()
