"""Firma del feed Windows: windows/tools/sign-feed.py, publish.sh e sync-published.py (#3501).

  python3 -m unittest discover -s scripts/tests
Ogni test genera una chiave di prova usa e getta con openssl in una cartella temporanea.
CORNETTA_REPO punta a un'altra copia del repo, per la prova sul codice vecchio.
"""
import base64
import importlib.util
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.environ.get("CORNETTA_REPO", os.path.abspath(os.path.join(HERE, "..", "..")))
SIGN = os.path.join(REPO, "windows", "tools", "sign-feed.py")
FEED = b'{"Assets":[{"FileName":"Cornetta-0.4.0-full.nupkg","SHA256":"' + b"2" * 64 + b'","Size":1}]}'


def run(*args, env=None):
    return subprocess.run(["python3", SIGN, *args], capture_output=True, text=True, env=env)


class SignFeedTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.key = os.path.join(self.tmp, "feed.pem")
        old = os.umask(0o077)
        try:
            subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", self.key],
                           check=True, capture_output=True)
        finally:
            os.umask(old)
        self.app_info = os.path.join(self.tmp, "AppInfo.cs")
        self.env = dict(os.environ, CORNETTA_FEED_KEY_FILE=self.key, CORNETTA_APP_INFO=self.app_info)
        result = run("--public-key", env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.public = result.stdout.strip()
        self.write_app_info(f'"{self.public}"')
        self.feed = os.path.join(self.tmp, "releases.win.json")
        open(self.feed, "wb").write(FEED)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def write_app_info(self, value):
        open(self.app_info, "w", encoding="utf-8").write(f"        public const string UpdateFeedPublicKey = {value};\n")

    def test_signs_and_verifies(self):
        result = run(self.feed, env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        raw = base64.b64decode(open(self.feed + ".sig", "rb").read().strip(), validate=True)
        self.assertEqual(len(raw), 64, "la firma è r||s di 64 byte, il formato che .NET verifica")
        self.assertEqual(run("--verify", self.feed, self.feed + ".sig", env=self.env).returncode, 0)

    def test_changed_feed_does_not_verify(self):
        run(self.feed, env=self.env)
        open(self.feed, "wb").write(FEED.replace(b'"Size":1', b'"Size":2'))
        result = run("--verify", self.feed, self.feed + ".sig", env=self.env)
        self.assertNotEqual(result.returncode, 0)

    def test_key_must_match_the_app(self):
        self.write_app_info('"' + "ab" * 64 + '"')
        result = run(self.feed, env=self.env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("non corrisponde", result.stderr)
        self.assertFalse(os.path.exists(self.feed + ".sig"))

    def test_placeholder_stops_signing(self):
        self.write_app_info("FeedSignature.Placeholder")
        result = run("--check-key", env=self.env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("segnaposto", result.stderr)

    def test_key_file_rules(self):
        env = dict(self.env)
        del env["CORNETTA_FEED_KEY_FILE"]
        self.assertIn("manca CORNETTA_FEED_KEY_FILE", run("--check-key", env=env).stderr)
        if os.name == "posix":  # su Windows i permessi POSIX non ci sono, e sign-feed.py non li controlla
            os.chmod(self.key, 0o644)
            self.assertIn("chmod 600", run("--check-key", env=self.env).stderr)
            os.chmod(self.key, 0o600)
        inside = tempfile.mkdtemp(dir=REPO)
        try:
            shutil.copy(self.key, os.path.join(inside, "feed.pem"))
            os.chmod(os.path.join(inside, "feed.pem"), 0o600)
            result = run("--check-key", env=dict(self.env, CORNETTA_FEED_KEY_FILE=os.path.join(inside, "feed.pem")))
            self.assertIn("dentro il repo", result.stderr)
        finally:
            shutil.rmtree(inside)

    def test_private_key_never_reaches_the_output(self):
        pem = open(self.key, encoding="ascii").read()
        body = "".join(line for line in pem.splitlines() if "-----" not in line)
        for args in (["--check-key"], ["--public-key"], [self.feed]):
            result = run(*args, env=self.env)
            self.assertNotIn(body[:40], result.stdout + result.stderr)

    def test_csharp_test_vector_is_a_real_signature(self):
        # Il vettore di FeedSignatureTests.cs, verificato da openssl: la firma che l'app verifica in CI è vera.
        source = open(os.path.join(REPO, "windows", "tests", "Cornetta.Core.Tests", "FeedSignatureTests.cs"), encoding="utf-8").read()
        const = {m.group(1): m.group(2) for m in re.finditer(r'const string (\w+) = "((?:[^"\\]|\\.)*)";', source)}
        self.write_app_info(f'"{const["TestPublicKey"]}"')
        open(self.feed, "wb").write(const["TestFeed"].replace('\\"', '"').encode("utf-8"))
        open(self.feed + ".sig", "w").write(const["TestSignature"])
        result = run("--verify", self.feed, self.feed + ".sig", env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)


class PublishFlowTests(unittest.TestCase):
    def test_publish_signs_before_deploy_and_checks_the_served_signature(self):
        script = open(os.path.join(REPO, "windows", "tools", "publish.sh"), encoding="utf-8").read()
        deploy = script.index("wrangler")
        sign = script.find('sign-feed.py "$DEST/releases.win.json"')
        self.assertGreater(sign, 0, "publish.sh non firma il feed")
        self.assertLess(sign, script.index("deploy)", deploy), "la firma va fatta prima del deploy")
        self.assertIn("sign-feed.py --check-key", script)
        self.assertIn("releases.win.json.sig", script[deploy:], "dopo il deploy va verificata la firma servita")

    def test_sync_published_keeps_the_signature(self):
        path = os.path.join(REPO, "scripts", "sync-published.py")
        spec = importlib.util.spec_from_file_location("sync_published_sotto_test", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        site = {"windows/releases.win.json": FEED, "windows/releases.win.json.sig": b"firma\n", "appcast.xml": b""}
        with mock.patch.object(module, "fetch", side_effect=lambda p: site.get(p)), mock.patch.object(module, "tags", return_value=[]):
            required, _ = module.published_files()
        self.assertIn("windows/releases.win.json.sig", required)


if __name__ == "__main__":
    unittest.main()
