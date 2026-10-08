"""Isolated tests for first-run setup and the local browser-auth boundary."""

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch


CONTROLLER_PATH = Path(__file__).resolve().parents[1] / "controller/deepseekHarness.py"


def load_controller(environment: dict[str, str], *, npm_root: str | None = None,
                    global_dsh: str | None = None, no_node: bool = False):
    temporary = tempfile.TemporaryDirectory()
    env = {
        "DSH_SETTINGS": str(Path(temporary.name) / "settings.json"),
        "DSH_HOME": temporary.name,
        **environment,
    }
    spec = importlib.util.spec_from_file_location(
        f"controller_{id(temporary)}", CONTROLLER_PATH
    )
    controller = importlib.util.module_from_spec(spec)
    which = lambda name: global_dsh if name == "dsh" else None
    output = npm_root or str(Path(temporary.name) / "npm-root")
    patches = [
        patch.dict(os.environ, env, clear=True),
        patch("shutil.which", side_effect=which),
        patch("subprocess.check_output", return_value=output),
    ]
    if no_node:
        patches.append(patch.object(Path, "is_file", autospec=True, return_value=False))
    with contextlib.ExitStack() as stack:
        for context in patches:
            stack.enter_context(context)
        spec.loader.exec_module(controller)
    controller._test_temporary = temporary
    return controller


class FirstRunBootstrapTests(unittest.TestCase):
    def test_import_without_node_is_safe_and_install_error_is_actionable(self):
        controller = load_controller({"PATH": ""}, no_node=True)
        self.addCleanup(controller._test_temporary.cleanup)
        self.assertIsNone(controller.NODE_BIN)
        with patch.object(Path, "is_file", autospec=True, return_value=False), \
             patch.object(controller.shutil, "which", return_value=None), \
             self.assertRaises(controller.HarnessError) as raised:
            controller._require_node_bin()
        self.assertIn("Node.js", str(raised.exception))
        self.assertIn("nodejs.org", str(raised.exception))

    def test_fresh_install_uses_private_prefix(self):
        controller = load_controller({"PATH": "", "DSH_NODE_BIN": sys.executable})
        self.addCleanup(controller._test_temporary.cleanup)
        self.assertEqual(
            controller.INSTALL_PREFIX,
            Path.home() / ".local/share/deepseek-harness/runtime",
        )

    def test_fresh_cli_install_and_version_probe_share_the_private_prefix(self):
        with tempfile.TemporaryDirectory() as prefix:
            controller = load_controller({
                "PATH": "",
                "DSH_NODE_BIN": sys.executable,
                "DSH_INSTALL_PREFIX": prefix,
            })
            self.addCleanup(controller._test_temporary.cleanup)
            controller.DSH_BIN_PATH = None
            installed_cli = controller.DSH_BIN_PREFIX / "dsh"

            def fake_install(spec, progress_file=None):
                installed_cli.parent.mkdir(parents=True, exist_ok=True)
                installed_cli.touch()

            with patch.object(controller, "npm_install_global", side_effect=fake_install) as install, \
                 patch.object(controller, "dsh_version_string", return_value="0.2.0"):
                result = controller.install_dsh()
            self.assertEqual(install.call_args.args[0], controller.PACKAGE_NAME)
            self.assertEqual(result["version"], "0.2.0")
            self.assertEqual(controller._dsh_bin(), installed_cli)

    def test_existing_cli_is_kept_without_reinstalling_or_upgrading(self):
        with tempfile.TemporaryDirectory() as prefix:
            controller = load_controller({
                "PATH": "",
                "DSH_NODE_BIN": sys.executable,
                "DSH_INSTALL_PREFIX": prefix,
            })
            self.addCleanup(controller._test_temporary.cleanup)
            installed_cli = controller.DSH_BIN_PREFIX / "dsh"
            installed_cli.parent.mkdir(parents=True)
            installed_cli.touch()
            with patch.object(controller, "npm_install_global") as install, \
                 patch.object(controller, "dsh_version_string", return_value="0.1.9"):
                result = controller.install_dsh()
            install.assert_not_called()
            self.assertEqual(result["status"], "already_installed")
            self.assertEqual(result["version"], "0.1.9")

    def test_failed_fresh_install_removes_only_its_new_cli_artifacts(self):
        with tempfile.TemporaryDirectory() as prefix:
            controller = load_controller({
                "PATH": "",
                "DSH_NODE_BIN": sys.executable,
                "DSH_INSTALL_PREFIX": prefix,
            })
            self.addCleanup(controller._test_temporary.cleanup)
            binary = controller.DSH_BIN_PREFIX / "dsh"
            package_dir = controller.DSH_INSTALL_DIR
            unrelated = Path(prefix) / "bin/other-tool"
            unrelated.parent.mkdir(parents=True)
            unrelated.touch()

            def partial_install(spec, progress_file=None):
                binary.touch()
                package_dir.mkdir(parents=True)
                raise controller.HarnessError("network failed")

            with patch.object(controller, "npm_install_global", side_effect=partial_install), \
                 self.assertRaisesRegex(controller.HarnessError, "network failed"):
                controller.install_dsh()
            self.assertFalse(binary.exists())
            self.assertFalse(package_dir.exists())
            self.assertTrue(unrelated.is_file())

    def test_existing_global_cli_keeps_its_prefix(self):
        controller = load_controller(
            {"PATH": "", "DSH_NODE_BIN": sys.executable},
            global_dsh="/opt/homebrew/bin/dsh",
        )
        self.addCleanup(controller._test_temporary.cleanup)
        self.assertEqual(controller.INSTALL_PREFIX, Path("/opt/homebrew"))

    def test_legacy_keychain_lookup_is_optional_and_noninteractive(self):
        controller = load_controller({"PATH": "", "DSH_NODE_BIN": sys.executable})
        self.addCleanup(controller._test_temporary.cleanup)
        with patch.object(controller, "_read_keychain_noninteractive", return_value=None) as read:
            self.assertIsNone(controller.keychain_secret())
            read.assert_called_once_with(controller.KEYCHAIN_SERVICE, controller.KEYCHAIN_ACCOUNT)
        with patch.object(controller, "_read_keychain_noninteractive", return_value="fixture-secret"):
            self.assertEqual(controller.keychain_secret(), "fixture-secret")

    def test_start_passes_no_api_key_to_harness_when_legacy_item_is_absent(self):
        with tempfile.TemporaryDirectory() as root:
            controller = load_controller({
                "PATH": "",
                "DSH_NODE_BIN": sys.executable,
                "DSH_HOME": str(Path(root) / ".dsh"),
                "DSH_WORKSPACE": str(Path(root) / "workspace"),
                "DSH_INSTALL_PREFIX": str(Path(root) / "runtime"),
            })
            self.addCleanup(controller._test_temporary.cleanup)
            dsh_path = Path(root) / "runtime/bin/dsh"
            dsh_path.parent.mkdir(parents=True)
            dsh_path.touch()
            child = type("Child", (), {"pid": 321, "poll": lambda self: None})()
            captured = {}

            def launch(args, **kwargs):
                captured.update(args=args, env=kwargs["env"])
                return child

            with patch.dict(os.environ, {"PATH": ""}, clear=True), \
                 patch.object(controller, "_dsh_bin", return_value=dsh_path), \
                 patch.object(controller, "read_state", return_value=None), \
                 patch.object(controller, "state_process", return_value=None), \
                 patch.object(controller, "port_open", return_value=False), \
                 patch.object(controller, "keychain_secret", return_value=None), \
                 patch.object(controller, "dsh_version_key", return_value=None), \
                 patch.object(controller, "http_ready", return_value=True), \
                 patch.object(controller, "write_state"), \
                 patch.object(controller.os, "open", return_value=41), \
                 patch.object(controller.os, "close"), \
                 patch.object(controller.os, "getpgid", return_value=321), \
                 patch.object(controller.subprocess, "Popen", side_effect=launch), \
                 redirect_stdout(io.StringIO()):
                self.assertTrue(controller.start(json_output=True))
            self.assertNotIn("DEEPSEEK_API_KEY", captured["env"])
            self.assertIn("DSH_HOME", captured["env"])

    def test_officially_managed_key_takes_precedence_over_legacy_keychain(self):
        with tempfile.TemporaryDirectory() as root:
            dsh_home = Path(root) / ".dsh"
            dsh_home.mkdir()
            # The value is deliberately a fixture; the adapter must only use
            # the presence of this upstream ref and never export an old key.
            (dsh_home / ".credentials.yaml").write_text(
                "version: 1\nrefs:\n  DEEPSEEK_API_KEY: {provider: local}\n",
                encoding="utf-8",
            )
            controller = load_controller({
                "PATH": "",
                "DSH_NODE_BIN": sys.executable,
                "DSH_HOME": str(dsh_home),
                "DSH_WORKSPACE": str(Path(root) / "workspace"),
                "DSH_INSTALL_PREFIX": str(Path(root) / "runtime"),
            })
            self.addCleanup(controller._test_temporary.cleanup)
            dsh_path = Path(root) / "runtime/bin/dsh"
            dsh_path.parent.mkdir(parents=True)
            dsh_path.touch()
            child = type("Child", (), {"pid": 321, "poll": lambda self: None})()
            captured = {}

            def launch(args, **kwargs):
                captured.update(args=args, env=kwargs["env"])
                return child

            with patch.dict(os.environ, {"PATH": ""}, clear=True), \
                 patch.object(controller, "_dsh_bin", return_value=dsh_path), \
                 patch.object(controller, "read_state", return_value=None), \
                 patch.object(controller, "state_process", return_value=None), \
                 patch.object(controller, "port_open", return_value=False), \
                 patch.object(controller, "keychain_secret", return_value="legacy-fixture-secret") as keychain, \
                 patch.object(controller, "dsh_version_key", return_value=None), \
                 patch.object(controller, "http_ready", return_value=True), \
                 patch.object(controller, "write_state"), \
                 patch.object(controller.os, "open", return_value=41), \
                 patch.object(controller.os, "close"), \
                 patch.object(controller.os, "getpgid", return_value=321), \
                 patch.object(controller.subprocess, "Popen", side_effect=launch), \
                 redirect_stdout(io.StringIO()):
                self.assertTrue(controller.start(json_output=True))
            keychain.assert_not_called()
            self.assertNotIn("DEEPSEEK_API_KEY", captured["env"])


class LocalAuthURLTests(unittest.TestCase):
    def setUp(self):
        self.controller = load_controller({"PATH": "", "DSH_NODE_BIN": sys.executable})
        self.addCleanup(self.controller._test_temporary.cleanup)

    def test_accepts_only_local_server_auth_urls(self):
        validate = self.controller._validated_auth_url
        self.assertEqual(
            validate("http://localhost:3080/?token=fixture"),
            "http://localhost:3080/?token=fixture",
        )
        self.assertEqual(
            validate("http://127.0.0.1:3080/?token=fixture"),
            "http://127.0.0.1:3080/?token=fixture",
        )
        for value in (
            "http://attacker.example:3080/?token=fixture",
            "http://localhost:3081/?token=fixture",
            "https://localhost:3080/?token=fixture",
            "http://user@localhost:3080/?token=fixture",
            "http://localhost:3080/",
            "http://localhost:3080/?token=one&token=two",
            "http://localhost:3080/?token=fixture#fragment",
        ):
            with self.subTest(value=value):
                self.assertIsNone(validate(value))

    def test_state_and_log_paths_both_validate_before_returning_url(self):
        controller = self.controller
        self.assertIsNone(controller.auth_url_from_state({
            "auth_url": "http://attacker.example:3080/?token=fixture"
        }))
        with tempfile.TemporaryDirectory() as temporary:
            log_path = Path(temporary) / "web.log"
            log_path.write_text(
                "dsh web: http://attacker.example:3080/?token=bad\n"
                "dsh web: http://localhost:3080/?token=good\n",
                encoding="utf-8",
            )
            with patch.object(controller, "LOG_FILE", log_path):
                self.assertEqual(
                    controller.authenticated_url_from_log(),
                    "http://localhost:3080/?token=good",
                )


if __name__ == "__main__":
    unittest.main()
