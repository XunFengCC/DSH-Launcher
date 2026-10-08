"""Mock-only regression tests for update and rollback transaction boundaries."""

import importlib.util
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


with tempfile.TemporaryDirectory() as temporary:
    with patch.dict(os.environ, {
        "DSH_SETTINGS": str(Path(temporary) / "settings.json"),
        "DSH_NODE_BIN": sys.executable,
        "DSH_HOME": temporary,
        "DSH_BACKUP_DIR": str(Path(temporary) / "backups"),
    }), patch("subprocess.check_output", return_value=temporary):
        spec = importlib.util.spec_from_file_location(
            "controller_transactions",
            Path(__file__).resolve().parents[1] / "controller/deepseekHarness.py",
        )
        controller = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(controller)


class UpdateTransactionTests(unittest.TestCase):
    def test_json_boundary_preserves_one_result_across_lifecycle_output(self):
        # Real start() writes lifecycle text before the transaction returns.
        # Exercise the command boundary, including recovery/rollback statuses,
        # rather than mocking away the stdout that caused the native failure.
        for action, status in (("update", "installed_restarted"),
                               ("update", "rolled_back"),
                               ("update", "rollback_failed"),
                               ("rollback", "rolled_back")):
            output, diagnostics = io.StringIO(), io.StringIO()
            def transaction(*args, **kwargs):
                print("Harness started / lifecycle diagnostic")
                return {"status": status, "message": "test result"}
            method = "update_harness" if action == "update" else "rollback_harness"
            argv = ["controller", action, "--json"]
            argv += ["--restart"] if action == "update" else ["--to", "1.0.0"]
            with self.subTest(action=action, status=status), \
                 patch.object(sys, "argv", argv), \
                 patch.object(controller, method, side_effect=transaction), \
                 contextlib.redirect_stdout(output), contextlib.redirect_stderr(diagnostics):
                self.assertEqual(controller.main(), 0)
                self.assertEqual(json.loads(output.getvalue())["status"], status)
                self.assertIn("lifecycle diagnostic", diagnostics.getvalue())

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.backup = self.root / "data-before"
        self.backup.mkdir()
        self.snapshot = self.root / "deployment-before"
        self.snapshot.mkdir()
        (self.snapshot / "package.json").write_text(
            json.dumps({"version": "1.0.0"}), encoding="utf-8"
        )
        self.snapshot.with_name(self.snapshot.name + ".manifest.json").write_text(
            json.dumps({
                "schema": 1, "deployment_snapshot": self.snapshot.name,
                "version": "1.0.0", "data_backup": str(self.backup),
            }),
            encoding="utf-8",
        )

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def update_info():
        return {
            "update_available": True,
            "local_version": "1.0.0",
            "recommended": {"version": "2.0.0"},
            "registry": {},
        }

    def test_install_failure_restores_code_and_data_and_restarts_old_service(self):
        with patch.object(controller, "check_update", return_value=self.update_info()), \
             patch.object(controller, "restart_guard", return_value=None), \
             patch.object(controller, "read_state", return_value={"pid": 42}), \
             patch.object(controller, "state_process", return_value=(42, 42, "dsh")), \
             patch.object(controller, "backup_dsh", return_value=self.backup), \
             patch.object(controller, "backup_deployment", return_value=self.snapshot), \
             patch.object(controller, "stop") as stop, \
             patch.object(controller, "npm_install_global", side_effect=controller.HarnessError("npm failed")), \
             patch.object(controller, "restore_deployment_snapshot") as restore_code, \
             patch.object(controller, "restore_dsh_from_backup") as restore_data, \
             patch.object(controller, "dsh_version_string", return_value="1.0.0"), \
             patch.object(controller, "start") as start, \
             patch.object(controller, "session_activity_dict", return_value={"busy": False}):
            result = controller.update_harness(restart=False)

        self.assertEqual(result["status"], "rolled_back")
        restore_code.assert_called_once_with(self.snapshot, "1.0.0")
        restore_data.assert_called_once_with(self.backup)
        start.assert_called_once_with()
        self.assertEqual(stop.call_count, 2)  # once before npm; again before restore

    def test_data_backup_happens_after_stop_and_snapshot_failure_restarts_service(self):
        timeline = Mock()
        with patch.object(controller, "check_update", return_value=self.update_info()), \
             patch.object(controller, "restart_guard", return_value=None), \
             patch.object(controller, "read_state", return_value={"pid": 42}), \
             patch.object(controller, "state_process", return_value=(42, 42, "dsh")), \
             patch.object(controller, "stop") as stop, \
             patch.object(controller, "backup_dsh", return_value=self.backup) as backup_data, \
             patch.object(controller, "backup_deployment", side_effect=controller.HarnessError("snapshot failed")), \
             patch.object(controller, "npm_install_global") as install, \
             patch.object(controller, "start") as start, \
             patch.object(controller, "session_activity_dict", return_value={"busy": False}):
            timeline.attach_mock(stop, "stop")
            timeline.attach_mock(backup_data, "backup_data")
            result = controller.update_harness(restart=False)

        self.assertEqual(result["status"], "update_failed")
        self.assertEqual(timeline.mock_calls[:2], [unittest.mock.call.stop(), unittest.mock.call.backup_data()])
        install.assert_not_called()
        start.assert_called_once_with()


    def test_version_verification_failure_restores_old_deployment(self):
        with patch.object(controller, "check_update", return_value=self.update_info()), \
             patch.object(controller, "restart_guard", return_value=None), \
             patch.object(controller, "read_state", return_value=None), \
             patch.object(controller, "state_process", return_value=None), \
             patch.object(controller, "backup_dsh", return_value=self.backup), \
             patch.object(controller, "backup_deployment", return_value=self.snapshot), \
             patch.object(controller, "stop"), \
             patch.object(controller, "npm_install_global"), \
             patch.object(controller, "restore_deployment_snapshot") as restore_code, \
             patch.object(controller, "restore_dsh_from_backup") as restore_data, \
             patch.object(controller, "dsh_version_string", side_effect=["9.0.0", "1.0.0"]):
            result = controller.update_harness(restart=False)

        self.assertEqual(result["status"], "rolled_back")
        restore_code.assert_called_once_with(self.snapshot, "1.0.0")
        restore_data.assert_called_once_with(self.backup)


    def test_start_failure_during_smoke_restores_exact_paired_snapshot(self):
        self.snapshot.rename(self.root / "20261004T100000-1.0.0")
        self.snapshot = self.root / "20261004T100000-1.0.0"
        manifest = self.snapshot.with_name(self.snapshot.name + ".manifest.json")
        manifest.write_text(json.dumps({
            "schema": 1, "deployment_snapshot": self.snapshot.name,
            "version": "1.0.0", "data_backup": str(self.backup),
        }), encoding="utf-8")
        with patch.object(controller, "start", side_effect=[controller.HarnessError("start failed"), None]), \
             patch.object(controller, "stop") as stop, \
             patch.object(controller, "dsh_version_string", return_value="1.0.0"), \
             patch.object(controller, "restore_deployment_snapshot") as restore_code, \
             patch.object(controller, "restore_dsh_from_backup") as restore_data, \
             patch.object(controller, "session_activity_dict", return_value={"busy": False}):
            result = controller._restart_and_smoke("1.0.0", "2.0.0", self.backup, self.snapshot)

        self.assertEqual(result["status"], "rolled_back")
        restore_code.assert_called_once_with(self.snapshot, "1.0.0")
        restore_data.assert_called_once_with(self.backup)
        self.assertEqual(stop.call_count, 1)

    def test_smoke_failure_restores_old_deployment(self):
        manifest = self.snapshot.with_name(self.snapshot.name + ".manifest.json")
        with patch.object(controller, "start") as start, \
             patch.object(controller, "stop"), \
             patch.object(controller, "dsh_version_string", return_value="1.0.0"), \
             patch.object(controller, "restore_deployment_snapshot") as restore_code, \
             patch.object(controller, "restore_dsh_from_backup") as restore_data, \
             patch.object(controller, "session_activity_dict", side_effect=[
                 controller.HarnessError("smoke failed"), {"busy": False},
             ]):
            result = controller._restart_and_smoke("1.0.0", "2.0.0", self.backup, self.snapshot)

        self.assertEqual(result["status"], "rolled_back")
        self.assertTrue(manifest.is_file())
        start.assert_has_calls([unittest.mock.call(), unittest.mock.call()])
        restore_code.assert_called_once_with(self.snapshot, "1.0.0")
        restore_data.assert_called_once_with(self.backup)

    def test_failed_rollback_smoke_stops_service_and_reports_truthfully(self):
        with patch.object(controller, "start"), \
             patch.object(controller, "stop") as stop, \
             patch.object(controller, "dsh_version_string", return_value="1.0.0"), \
             patch.object(controller, "restore_deployment_snapshot"), \
             patch.object(controller, "restore_dsh_from_backup"), \
             patch.object(controller, "session_activity_dict", side_effect=[
                 controller.HarnessError("new smoke failed"),
                 controller.HarnessError("old smoke failed"),
             ]):
            result = controller._restart_and_smoke("1.0.0", "2.0.0", self.backup, self.snapshot)

        self.assertEqual(result["status"], "rollback_failed")
        self.assertIn("服务已停止", result["message"])
        self.assertEqual(stop.call_count, 2)  # stop before restore, then after failed old smoke

    def test_check_update_uses_only_official_latest_dist_tag(self):
        with patch.object(controller, "dsh_version_string", return_value="1.0.0"), \
             patch.object(controller, "registry_info", return_value={
                 "latest": {"version": "1.1.0-rc.2", "published": ""},
                 "alpha": {"version": "9.0.0-alpha.1", "published": ""},
             }):
            result = controller.check_update()
        self.assertEqual(result["recommended"]["tag"], "latest")
        self.assertEqual(result["recommended"]["version"], "1.1.0-rc.2")

        with patch.object(controller, "dsh_version_string", return_value="1.0.0"), \
             patch.object(controller, "registry_info", return_value={
                 "alpha": {"version": "9.0.0-alpha.1", "published": ""},
             }):
            with self.assertRaisesRegex(controller.HarnessError, "latest"):
                controller.check_update()

    def test_snapshot_lookup_rejects_missing_or_unpaired_data(self):
        deployments = self.root / "deployments"
        deployments.mkdir()
        path = deployments / "20261004T100000-1.0.0"
        path.mkdir()
        (path / "package.json").write_text(json.dumps({"version": "1.0.0"}), encoding="utf-8")
        with patch.object(controller, "DEPLOYMENT_DIR", deployments):
            self.assertIsNone(controller.deployment_snapshot_path("1.0.0"))
            manifest = path.with_name(path.name + ".manifest.json")
            manifest.write_text(json.dumps({
                "schema": 1, "deployment_snapshot": path.name,
                "version": "1.0.0", "data_backup": str(self.root / "missing-data"),
            }), encoding="utf-8")
            self.assertIsNone(controller.deployment_snapshot_path("1.0.0"))

    def test_rollback_guard_precedes_every_write(self):
        with patch.object(controller, "restart_guard", return_value="busy"), \
             patch.object(controller, "backup_dsh") as backup_data, \
             patch.object(controller, "backup_deployment") as backup_code, \
             patch.object(controller, "restore_deployment_snapshot") as restore_code, \
             patch.object(controller, "npm_install_global") as install:
            result = controller.rollback_harness("1.0.0")

        self.assertEqual(result["status"], "rollback_pending")
        backup_data.assert_not_called()
        backup_code.assert_not_called()
        restore_code.assert_not_called()
        install.assert_not_called()

    def test_rollback_without_complete_local_pair_refuses_network_fallback(self):
        with patch.object(controller, "restart_guard", return_value=None), \
             patch.object(controller, "dsh_version_string", return_value="2.0.0"), \
             patch.object(controller, "deployment_snapshot_path", return_value=None), \
             patch.object(controller, "npm_install_global") as install, \
             patch.object(controller, "backup_dsh") as backup_data:
            result = controller.rollback_harness("1.0.0")

        self.assertEqual(result["status"], "rollback_unavailable")
        install.assert_not_called()
        backup_data.assert_not_called()


if __name__ == "__main__":
    unittest.main()
