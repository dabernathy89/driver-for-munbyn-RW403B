# SPDX-License-Identifier: MIT
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import configure


class ConfigurationTests(unittest.TestCase):
    def test_private_configuration_and_tampering(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root) / "config"
            subprocess.run([
                "python3", str(Path(configure.__file__)), "--directory", str(directory),
                "--uuid", "00000000-0000-4000-8000-000000000001", "--mac", "02:00:00:00:00:01",
            ], check=True, capture_output=True)
            settings = configure.load(directory)
            self.assertEqual(settings["uid"], os.getuid())
            self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
            for name in ("Config.h", "settings.json"):
                self.assertEqual((directory / name).stat().st_mode & 0o777, 0o600)
            settings["mac"] = "02:00:00:00:00:00"
            (directory / "settings.json").write_text(json.dumps(settings))
            with self.assertRaisesRegex(ValueError, "disagree"):
                configure.load(directory)

    def test_reject_invalid_identity(self):
        valid = {"uid": os.getuid(), "uuid": "00000000-0000-4000-8000-000000000001", "mac": "02:00:00:00:00:01"}
        for key, value in (("uid", 0), ("uid", True), ("uid", -1), ("uuid", 'bad"\n'),
                           ("mac", '02:00:00:00:00:01"; invalid'), ("mac", "bad")):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                configure.validate(dict(valid, **{key: value}))


if __name__ == "__main__":
    unittest.main()
