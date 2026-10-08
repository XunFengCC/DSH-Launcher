"""Regression coverage for the launcher's full-stdout StartResult contract."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import unittest
from unittest.mock import patch


with tempfile.TemporaryDirectory() as temporary:
    # Import without reading personal settings or invoking a real npm probe.
    with patch.dict(os.environ, {
        "DSH_SETTINGS": str(Path(temporary) / "settings.json"),
        "DSH_NODE_BIN": sys.executable,
        "DSH_HOME": temporary,
    }), patch("subprocess.check_output", return_value=temporary):
        spec = importlib.util.spec_from_file_location(
            "controller", Path(__file__).resolve().parents[1] / "controller/deepseekHarness.py"
        )
        controller = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(controller)


class RestartOutputTests(unittest.TestCase):
    def invoke_restart(self, running=None, forced=False, json_output=True):
        stdout, stderr = io.StringIO(), io.StringIO()
        result = {
            "status": "started", "pid": 456,
            "auth_url": "http://localhost:3080/?token=TEST_ONLY",
        }

        def start(*, json_output=False):
            print(json.dumps(result) if json_output else "Started test service")

        with patch.object(controller, "restart_guard", return_value=None), \
             patch.object(controller, "read_state", return_value={"pid": 123}), \
             patch.object(controller, "state_process", return_value=running), \
             patch.object(controller, "clear_state"), \
             patch.object(controller, "process_command", return_value=None), \
             patch.object(controller.os, "killpg") as killpg, \
             patch.object(controller.time, "monotonic", side_effect=[0, 11 if forced else 1]), \
             patch.object(controller, "start", side_effect=start), \
             contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            controller.restart(json_output=json_output)
        return stdout.getvalue(), stderr.getvalue(), result, killpg.call_args_list

    def test_json_is_one_document_for_every_stop_outcome(self):
        for running, forced in [(None, False), ((123, 123, "dsh"), False),
                                ((123, 123, "dsh"), True)]:
            with self.subTest(running=running, forced=forced):
                stdout, stderr, result, signals = self.invoke_restart(running, forced)
                self.assertEqual(json.loads(stdout), result)
                self.assertIn("DeepSeek Harness", stderr)
                if forced:
                    self.assertEqual(signals[-1].args, (123, signal.SIGKILL))

    def test_human_output_keeps_stop_and_restart_messages(self):
        stdout, stderr, _, _ = self.invoke_restart(json_output=False)
        self.assertIn("DeepSeek Harness 当前没有运行。", stdout)
        self.assertIn("DeepSeek Harness 已重启。", stdout)
        self.assertEqual(stderr, "")

    def test_activity_guard_still_prevents_stop(self):
        with patch.object(controller, "restart_guard", return_value="busy"), \
             patch.object(controller, "stop") as stop:
            with self.assertRaisesRegex(controller.HarnessError, "busy"):
                controller.restart(json_output=True)
            stop.assert_not_called()

    def test_stop_failure_does_not_emit_success_json(self):
        stdout = io.StringIO()
        with patch.object(controller, "restart_guard", return_value=None), \
             patch.object(controller, "stop", side_effect=OSError("stop failed")), \
             patch.object(controller, "start") as start, contextlib.redirect_stdout(stdout):
            with self.assertRaisesRegex(OSError, "stop failed"):
                controller.restart(json_output=True)
            start.assert_not_called()
        self.assertEqual(stdout.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
