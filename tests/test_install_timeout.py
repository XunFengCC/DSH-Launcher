"""Whole-install timeout must include stdout stalls and lifecycle children."""
import importlib.util
import io
import os
from pathlib import Path
import signal
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

class InstallDeadlineTests(unittest.TestCase):
    def test_deadline_kills_only_the_created_process_group(self):
        with tempfile.TemporaryDirectory() as root:
            env = {"DSH_SETTINGS": root + "/none.json", "DSH_NODE_BIN": sys.executable,
                   "DSH_INSTALL_PREFIX": root + "/runtime"}
            with patch.dict(os.environ, env), patch("subprocess.check_output", return_value=root):
                spec = importlib.util.spec_from_file_location("timeout_controller",
                    Path(__file__).resolve().parents[1] / "controller/deepseekHarness.py")
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
            process = Mock(pid=12345, stdout=io.StringIO(""))
            with patch.object(module, "_require_node_bin", return_value=Path(sys.executable)), \
                 patch.object(Path, "is_file", return_value=True), \
                 patch.object(module.subprocess, "Popen", return_value=process) as spawn, \
                 patch.object(module.time, "monotonic", side_effect=[0, 601]), \
                 patch.object(module.os, "killpg") as kill, \
                 self.assertRaisesRegex(module.HarnessError, "超时"):
                module.npm_install_global(module.PACKAGE_NAME)
            self.assertTrue(spawn.call_args.kwargs["start_new_session"])
            kill.assert_called_once_with(12345, signal.SIGKILL)
            process.wait.assert_called_once()
