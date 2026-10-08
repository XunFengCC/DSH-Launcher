"""Isolated, offline tests for the configured CLI version action."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


CONTROLLER_PATH = Path(__file__).resolve().parents[1] / "controller/deepseekHarness.py"


class ConfiguredCLIVersionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.cli = self.root / "configured-prefix/bin/dsh"
        self.other_cli = self.root / "other-global/bin/dsh"
        self.node = self.root / "private-runtime/bin/node"
        for path in (self.cli, self.other_cli, self.node):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()

        environment = {
            "PATH": "",
            "DSH_SETTINGS": str(self.root / "settings.json"),
            "DSH_HOME": str(self.root / "home"),
            "DSH_INSTALL_PREFIX": str(self.root / "configured-prefix"),
            "DSH_BIN": str(self.cli),
            "DSH_NODE_BIN": str(self.node),
        }
        self.spec = importlib.util.spec_from_file_location("controller_cli_version", CONTROLLER_PATH)
        self.controller = importlib.util.module_from_spec(self.spec)
        with patch.dict(os.environ, environment, clear=True), \
             patch("shutil.which", return_value=None), \
             patch("subprocess.check_output", return_value=str(self.root / "npm-root")):
            self.spec.loader.exec_module(self.controller)

    def tearDown(self):
        self.temporary.cleanup()

    def test_reads_only_the_configured_cli_with_the_configured_node(self):
        completed = subprocess.CompletedProcess([], 0, "v1.2.3-rc.4\n", "")
        with patch.object(self.controller.subprocess, "run", return_value=completed) as run:
            result = self.controller.dsh_version_info()

        self.assertEqual(result, {"status": "installed", "installed": True, "version": "1.2.3-rc.4"})
        self.assertEqual(
            run.call_args.args[0],
            [str(self.node), str(self.cli.resolve()), "--version"],
        )
        self.assertNotIn(str(self.other_cli), run.call_args.args[0])

    def test_missing_configured_cli_is_not_installed_without_probing_elsewhere(self):
        self.cli.unlink()
        with patch.object(self.controller.subprocess, "run") as run:
            result = self.controller.dsh_version_info()

        self.assertEqual(result, {"status": "not-installed", "installed": False, "version": None})
        run.assert_not_called()

    def test_installed_cli_without_its_configured_node_is_unavailable(self):
        self.node.unlink()
        result = self.controller.dsh_version_info()

        self.assertEqual(result["status"], "unavailable")
        self.assertTrue(result["installed"])
        self.assertIsNone(result["version"])
        self.assertEqual(result["reason"], "node-unavailable")

    def test_read_failure_and_non_version_output_are_unavailable_without_echoing_output(self):
        with patch.object(
            self.controller.subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired("dsh --version", 10),
        ):
            failed = self.controller.dsh_version_info()
        self.assertEqual(failed["reason"], "version-unreadable")

        with patch.object(
            self.controller.subprocess,
            "run",
            return_value=subprocess.CompletedProcess([], 0, "1.2.3\nAPI_KEY=do-not-return\n", ""),
        ):
            malformed = self.controller.dsh_version_info()
        self.assertEqual(malformed["status"], "unavailable")
        self.assertIsNone(malformed["version"])
        self.assertNotIn("do-not-return", json.dumps(malformed))

    def test_version_json_action_has_a_machine_readable_stdout(self):
        with patch.object(
            self.controller,
            "dsh_version_info",
            return_value={"status": "installed", "installed": True, "version": "1.2.3"},
        ), patch.object(sys, "argv", [str(CONTROLLER_PATH), "version", "--json"]), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            status = self.controller.main()

        self.assertEqual(status, 0)
        self.assertEqual(json.loads(output.getvalue()), {
            "status": "installed", "installed": True, "version": "1.2.3",
        })


if __name__ == "__main__":
    unittest.main()
