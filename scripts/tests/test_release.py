"""Script di rilascio: guardia comune prima del deploy (#3450) e sync-published.py (#3451).

  python3 -m unittest discover -s scripts/tests
CORNETTA_GUARDIA e CORNETTA_SYNC_PY puntano a un'altra versione dei file, CORNETTA_REPO a un'altra copia
del repo: servono per la prova sul codice vecchio.
"""
import contextlib
import functools
import http.server
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.environ.get("CORNETTA_REPO", os.path.abspath(os.path.join(HERE, "..", "..")))
GUARDIA = os.environ.get("CORNETTA_GUARDIA", os.path.join(REPO, "scripts", "lib", "guardia.sh"))
SYNC = os.environ.get("CORNETTA_SYNC_PY", os.path.join(REPO, "scripts", "sync-published.py"))
SCRIPTS = ("scripts/deploy-site.sh", "scripts/release.sh", "windows/tools/publish.sh")
GIT_ENV = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, env=GIT_ENV, check=True, capture_output=True, text=True).stdout.strip()


def guardia(cwd, function, env=None):
    return subprocess.run(["bash", "-c", f'source "$1" && {function}', "_", GUARDIA], cwd=cwd,
                          env=env or GIT_ENV, capture_output=True, text=True)


class GuardiaRepoTests(unittest.TestCase):
    """Un clone pulito di un origin locale: ogni test lo sporca in un modo e la guardia deve fermarsi."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.origin = os.path.join(self.tmp, "origin.git")
        self.work = os.path.join(self.tmp, "work")
        git(self.tmp, "init", "-q", "--bare", "-b", "master", self.origin)
        git(self.tmp, "clone", "-q", self.origin, self.work)
        git(self.work, "checkout", "-q", "-b", "master")
        open(os.path.join(self.work, "a.txt"), "w").write("uno\n")
        git(self.work, "add", "a.txt")
        git(self.work, "commit", "-q", "-m", "uno")
        git(self.work, "push", "-q", "-u", "origin", "master")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def assertStops(self, message):
        result = guardia(self.work, "guardia_repo")
        self.assertNotEqual(result.returncode, 0, "la guardia doveva fermarsi")
        self.assertIn(message, result.stdout + result.stderr)

    def test_clean_and_aligned_passes(self):
        result = guardia(self.work, "guardia_repo")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_untracked_file_stops(self):
        # Un worker/public/bozza.html non tracciato andrebbe online: «git diff» non lo vede.
        open(os.path.join(self.work, "bozza.html"), "w").write("<p>bozza</p>\n")
        self.assertStops("non tracciati")

    def test_staged_change_stops(self):
        open(os.path.join(self.work, "a.txt"), "w").write("due\n")
        git(self.work, "add", "a.txt")
        self.assertStops("non committate")

    def test_detached_head_stops(self):
        git(self.work, "checkout", "-q", "--detach")
        self.assertStops("HEAD staccato")

    def test_branch_without_upstream_stops(self):
        git(self.work, "checkout", "-q", "-b", "prova")
        self.assertStops("upstream")

    def test_unpushed_commit_stops(self):
        git(self.work, "commit", "-q", "--allow-empty", "-m", "locale")
        self.assertStops("non pushati")

    def test_behind_origin_stops(self):
        other = os.path.join(self.tmp, "other")
        git(self.tmp, "clone", "-q", self.origin, other)
        git(other, "commit", "-q", "--allow-empty", "-m", "dall'altra macchina")
        git(other, "push", "-q", "origin", "master")
        self.assertStops("indietro")


class GuardiaMigrationsTests(unittest.TestCase):
    """Il D1 vero lo simula un npx finto che risponde come «wrangler d1 execute --json»."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.tmp, "worker", "migrations"))
        for name in ("0001_eventi.sql", "0002_avvio.sql"):
            open(os.path.join(self.tmp, "worker", "migrations", name), "w").write("SELECT 1;\n")
        bin_dir = os.path.join(self.tmp, "bin")
        os.makedirs(bin_dir)
        npx = os.path.join(bin_dir, "npx")
        # newline="\n": su Windows il modo testo scrive CRLF, e bash legge «/bin/bash\r» e «$FAKE_NPX_LOG\r».
        open(npx, "w", newline="\n").write('#!/bin/bash\necho "$*" >> "$FAKE_NPX_LOG"\n[ -n "$FAKE_D1" ] || exit 1\necho "$FAKE_D1"\n')
        os.chmod(npx, 0o755)
        self.log = os.path.join(self.tmp, "npx.log")
        self.env = dict(GIT_ENV, PATH=bin_dir + os.pathsep + os.environ["PATH"], FAKE_NPX_LOG=self.log)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_with(self, applied):
        d1 = json.dumps([{"results": [{"name": n} for n in applied], "success": True}]) if applied is not None else ""
        return guardia(self.tmp, "guardia_migrations", env=dict(self.env, FAKE_D1=d1))

    def test_all_applied_passes(self):
        result = self.run_with(["0001_eventi.sql", "0002_avvio.sql"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("d1 execute cornetta-telemetria --remote", open(self.log).read())

    def test_missing_migration_stops_with_the_command(self):
        result = self.run_with(["0001_eventi.sql"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("0002_avvio.sql", result.stderr)
        self.assertIn("d1 migrations apply cornetta-telemetria --remote", result.stderr)

    def test_unreadable_d1_stops(self):
        self.assertNotEqual(self.run_with(None).returncode, 0)


class ScriptsUseGuardiaTests(unittest.TestCase):
    def test_every_deploy_script_runs_the_guardia_before_wrangler(self):
        for name in SCRIPTS:
            script = open(os.path.join(REPO, name), encoding="utf-8").read()
            source = script.find("source scripts/lib/guardia.sh\nguardia\n")
            self.assertGreater(source, 0, f"{name} non carica e lancia la guardia")
            self.assertLess(source, script.index("wrangler@"), f"{name}: la guardia va prima del deploy")
            self.assertNotIn("git diff --quiet && git diff --cached --quiet", script, f"{name}: guardia vecchia")

    def test_no_deploy_script_confirms_lost_files_by_itself(self):
        # --recover è il momento in cui una persona ha controllato le copie locali: nessuno script lo salta.
        for name in SCRIPTS:
            self.assertNotIn("--recover", open(os.path.join(REPO, name), encoding="utf-8").read(), name)

    def test_publish_commits_only_redirects_and_pushes(self):
        script = open(os.path.join(REPO, "windows", "tools", "publish.sh"), encoding="utf-8").read()
        commit = script.index('git commit -q -m "Windows $VERSION')
        self.assertIn("-- worker/public/_redirects", script[commit:script.index("\n", commit)])
        self.assertIn("git push", script[commit:], "il commit di _redirects va pushato")


class SiteHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


class SyncPublishedTests(unittest.TestCase):
    """Sito finto su 127.0.0.1 (una cartella servita via HTTP) e worker/public in una cartella temporanea."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.site = os.path.join(self.tmp, "site")
        self.public = os.path.join(self.tmp, "public")
        handler = functools.partial(SiteHandler, directory=self.site)
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        appcast = (f'<enclosure url="{self.base}/downloads/Cornetta-1.0.0.dmg"/>'
                   f'<enclosure url="{self.base}/downloads/Cornetta1.0.0-0.9.0.delta"/>')
        files = {"appcast.xml": appcast, "downloads/latest.json": '{"mac": {"version": "1.0.0"}}',
                 "downloads/Cornetta-1.0.0.dmg": "dmg" * 100, "downloads/Cornetta1.0.0-0.9.0.delta": "delta",
                 "windows/releases.win.json": '{"Assets": []}', "windows/RELEASES": "r", "windows/assets.win.json": "[]",
                 "windows/CornettaSetup.exe": "exe" * 100}
        for root in (self.site, self.public):
            for path, text in files.items():
                self.write(root, path, text)
        self.write(self.public, "_redirects", "/download /downloads/Cornetta-1.0.0.dmg 302\n")
        spec = importlib.util.spec_from_file_location("sync_published_rilascio", SYNC)
        self.sync = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.sync)
        self.patches = [mock.patch.object(self.sync, "BASE_URL", self.base), mock.patch.object(self.sync, "PUBLIC", self.public),
                        mock.patch.object(self.sync, "tags", return_value=[])]
        self.recover = os.path.join(self.tmp, "cornetta-recover.json")
        if hasattr(self.sync, "recover_path"):
            self.patches.append(mock.patch.object(self.sync, "recover_path", return_value=self.recover))
        for patch in self.patches:
            patch.start()

    def tearDown(self):
        for patch in self.patches:
            patch.stop()
        self.server.shutdown()
        self.server.server_close()
        shutil.rmtree(self.tmp)

    def write(self, root, path, text):
        target = os.path.join(root, *path.split("/"))
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w") as f:
            f.write(text)

    def main(self, *argv):
        out = io.TextIOWrapper(io.BytesIO(), encoding="utf-8")  # main() chiama reconfigure, che StringIO non ha
        with mock.patch.object(sys, "argv", ["sync-published.py", *argv]), contextlib.redirect_stdout(out):
            self.sync.main()
        out.flush()
        return out.buffer.getvalue().decode("utf-8")

    def test_file_lost_by_the_site_but_kept_locally_does_not_block(self):
        # #3451: la versione vecchia si fermava, e nessun deploy poteva rimettere online il file.
        os.remove(os.path.join(self.site, "downloads", "Cornetta-1.0.0.dmg"))
        out = self.main()
        self.assertIn("solo in locale", out)
        self.assertTrue(os.path.exists(os.path.join(self.public, "downloads", "Cornetta-1.0.0.dmg")))
        self.main("--check")

    def test_lost_feed_kept_locally_keeps_its_own_signature(self):
        # Il sito ha la firma nuova ma ha perso il feed: la coppia locale deve restare coerente.
        self.write(self.public, "windows/releases.win.json.sig", "firma locale")
        self.write(self.site, "windows/releases.win.json.sig", "firma del sito")
        os.remove(os.path.join(self.site, "windows", "releases.win.json"))
        self.main("--recover")
        self.main()
        with open(os.path.join(self.public, "windows", "releases.win.json.sig")) as f:
            self.assertEqual(f.read(), "firma locale")

    def test_lost_unversioned_file_stops_until_recover(self):
        # La copia locale di un file senza versione può essere vecchia: la sync si ferma, e i tre script di deploy
        # con lei, finché la persona non conferma la copia con --recover.
        os.remove(os.path.join(self.site, "windows", "releases.win.json"))
        with self.assertRaises(SystemExit) as stop:
            self.main()
        self.assertIn("--recover", str(stop.exception.code))
        self.assertIn("windows/releases.win.json", str(stop.exception.code))
        self.assertIn("confermate", self.main("--recover"))
        self.main()
        self.main()  # la conferma resta finché il sito non serve di nuovo il file: un deploy fallito si riprende
        # Una copia locale cambiata dopo la conferma va controllata di nuovo.
        self.write(self.public, "windows/releases.win.json", '{"Assets": [], "x": 1}')
        with self.assertRaises(SystemExit):
            self.main()

    def test_confirmation_is_dropped_when_the_site_serves_the_file_again(self):
        os.remove(os.path.join(self.site, "windows", "CornettaSetup.exe"))
        self.main("--recover")
        self.assertTrue(os.path.exists(self.recover))
        self.write(self.site, "windows/CornettaSetup.exe", "exe" * 100)
        self.main()
        self.assertFalse(os.path.exists(self.recover))
        # Il sito lo perde di nuovo: la conferma vecchia non vale più.
        os.remove(os.path.join(self.site, "windows", "CornettaSetup.exe"))
        with self.assertRaises(SystemExit):
            self.main()

    def test_file_lost_everywhere_stops_and_says_where_to_recover_it(self):
        os.remove(os.path.join(self.site, "downloads", "Cornetta-1.0.0.dmg"))
        os.remove(os.path.join(self.public, "downloads", "Cornetta-1.0.0.dmg"))
        with self.assertRaises(SystemExit) as stop:
            self.main()
        self.assertIn("gh release download", str(stop.exception.code))

    def test_lost_delta_is_optional(self):
        os.remove(os.path.join(self.site, "downloads", "Cornetta1.0.0-0.9.0.delta"))
        os.remove(os.path.join(self.public, "downloads", "Cornetta1.0.0-0.9.0.delta"))
        self.main()
        self.main("--check")

    def test_verify_passes_when_the_site_serves_the_same_files(self):
        self.assertIn("uguali", self.main("--verify"))

    def test_verify_stops_on_a_big_file_with_another_length(self):
        self.write(self.site, "windows/CornettaSetup.exe", "vecchio")
        with self.assertRaises(SystemExit):
            self.main("--verify")

    def test_verify_stops_on_a_small_file_with_other_bytes(self):
        self.write(self.site, "windows/RELEASES", "x")
        with self.assertRaises(SystemExit):
            self.main("--verify")

    def test_not_older_than_the_published_version(self):
        for version, refused in (("0.9.9", True), ("1.0.0-beta.1", True), ("1.0.0", False), ("1.0.1", False), ("1.1.0-rc.1", False)):
            with self.subTest(version=version):
                if refused:
                    with self.assertRaises(SystemExit):
                        self.main("--not-older", "mac", version)
                else:
                    self.main("--not-older", "mac", version)
        self.main("--not-older", "windows", "0.1.0")  # nessuna versione windows pubblicata


if __name__ == "__main__":
    unittest.main()
