"""Versioni fissate: wrangler a una versione esatta e uguale ovunque, GitHub Actions a uno SHA (#3501).

  python3 -m unittest discover -s scripts/tests
Un «wrangler@4» o un «actions/checkout@v7» seguono l'ultima versione pubblicata: chi la controlla esegue
codice sulla macchina che pubblica o nella CI che impacchetta l'installer.
"""
import os
import re
import subprocess
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.environ.get("CORNETTA_REPO", os.path.abspath(os.path.join(HERE, "..", "..")))


def tracked_text():
    files = subprocess.run(["git", "ls-files"], cwd=REPO, capture_output=True, text=True, check=True).stdout.split()
    if not files:  # copia senza .git (prova sul codice vecchio): tutti i file
        files = [os.path.relpath(os.path.join(d, f), REPO) for d, _, fs in os.walk(REPO) for f in fs]
    for name in files:
        if name.endswith((".sh", ".py", ".md", ".yml", ".toml", ".js")) and not name.startswith("scripts/tests/"):
            path = os.path.join(REPO, name)
            if os.path.isfile(path):
                yield name, open(path, encoding="utf-8", errors="replace").read()


class PinTests(unittest.TestCase):
    def test_wrangler_has_one_exact_version(self):
        versions = {}
        for name, text in tracked_text():
            for match in re.finditer(r"wrangler@([^\s\"']+)", text):
                versions.setdefault(match.group(1), []).append(name)
        self.assertTrue(versions, "nessun wrangler@ trovato")
        for version, names in versions.items():
            self.assertRegex(version, r"^\d+\.\d+\.\d+$", f"wrangler@{version} non è una versione esatta ({sorted(set(names))})")
        self.assertEqual(len(versions), 1, f"versioni diverse di wrangler: {versions}")

    def test_actions_are_pinned_to_a_sha_with_the_version_in_a_comment(self):
        uses = [(name, line.strip()) for name, text in tracked_text() if name.startswith(".github/")
                for line in text.splitlines() if re.match(r"\s*(-\s*)?uses:", line)]
        self.assertTrue(uses)
        for name, line in uses:
            self.assertRegex(line, r"uses:\s*[\w.-]+/[\w.-]+@[0-9a-f]{40}\s+#\s*v\d+\.\d+\.\d+$", f"{name}: {line}")


if __name__ == "__main__":
    unittest.main()
