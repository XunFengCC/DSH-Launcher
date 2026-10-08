#!/usr/bin/env python3
"""Safe, on-demand controller for the local DeepSeek Harness Web UI.

Configuration (environment variables, all optional):
  DSH_HOME               Data dir (default ~/.dsh)
  DSH_NODE_BIN           Node binary (default: probe /opt/homebrew/bin/node,
                         /usr/local/bin/node, then PATH)
  DSH_WORKSPACE          Default workspace cwd (default ~/DeepSeekHarnessWorkspace)
  DSH_BACKUP_DIR         Pre-upgrade backup storage (default ~/.local/share/deepseek-harness/backups)
  DSH_KEYCHAIN_SERVICE   macOS Keychain service for the provider API key
                         (default deepseek-harness/deepseek-api)
  DSH_KEYCHAIN_ACCOUNT   Keychain account (default deepseek-api)
  DSH_PORT               Web UI port (default 3080)
"""

from __future__ import annotations

import argparse
import contextlib
import http.cookiejar
import json
import os
import queue
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path


SETTINGS_PATH = Path(
    os.environ.get("DSH_SETTINGS")
    or str(Path.home() / ".config" / "deepseek-harness-launcher" / "settings.json")
).expanduser()


def _load_settings() -> dict[str, object]:
    try:
        data = json.loads(SETTINGS_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"设置文件 {SETTINGS_PATH} 无法解析：{exc}") from exc
    if not isinstance(data, dict):
        raise RuntimeError(f"设置文件 {SETTINGS_PATH} 必须是 JSON 对象。")
    return data


_SETTINGS = _load_settings()


def _cfg_str(setting_key: str, env_key: str, default: str) -> str:
    """Precedence: environment variable > settings.json > default."""
    value = os.environ.get(env_key)
    if value:
        return value
    raw = _SETTINGS.get(setting_key)
    if isinstance(raw, str) and raw:
        return raw
    return default


class HarnessError(RuntimeError):
    """A user-actionable Harness controller failure."""


def _probe_node_bin() -> Path:
    override = _cfg_str("node_bin", "DSH_NODE_BIN", "")
    if override:
        return Path(override).expanduser()
    for candidate in (Path("/opt/homebrew/bin/node"), Path("/usr/local/bin/node")):
        if candidate.is_file():
            return candidate
    found = shutil.which("node")
    if found:
        return Path(found)
    raise HarnessError(
        "找不到 Node.js，无法安装或启动 DeepSeek Harness。"
        "请先从 https://nodejs.org/ 安装 Node.js（含 npm），然后重新打开 Launcher；"
        "也可以在 settings.json 中设置 node_bin 或设置 DSH_NODE_BIN。"
    )


def _probe_node_bin_optional() -> Path | None:
    """Keep controller import usable on a clean Mac before Node is installed."""
    try:
        return _probe_node_bin()
    except HarnessError:
        return None


def _require_node_bin() -> Path:
    node = NODE_BIN or _probe_node_bin()
    if not node.is_file():
        raise HarnessError(
            f"找不到 Node.js：{node}。请安装 Node.js（含 npm），或修正 DSH_NODE_BIN / node_bin。"
        )
    return node


DSH_BIN_PATH: Path | None = None  # resolved lazily (npm global bindir varies)


def _dsh_bin() -> Path:
    global DSH_BIN_PATH
    if DSH_BIN_PATH is None:
        override = _cfg_str("dsh_bin", "DSH_BIN", "")
        if override:
            DSH_BIN_PATH = Path(override).expanduser()
        else:
            # Resolve against the same prefix npm install/update use. This also
            # remains a valid absent path before first install and when Node is
            # unavailable, so importing the controller stays side-effect free.
            DSH_BIN_PATH = DSH_BIN_PREFIX / "dsh"
    return DSH_BIN_PATH


NODE_BIN = _probe_node_bin_optional()
NPM_BIN = NODE_BIN.parent / "npm" if NODE_BIN is not None else None
DSH_HOME = Path(_cfg_str("dsh_home", "DSH_HOME", str(Path.home() / ".dsh"))).expanduser()
RUNTIME_DIR = DSH_HOME / "launcher"
STATE_FILE = RUNTIME_DIR / "web.json"
LOG_FILE = RUNTIME_DIR / "web.log"
PLAYGROUND = Path(
    _cfg_str("workspace", "DSH_WORKSPACE", str(Path.home() / "DeepSeekHarnessWorkspace"))
).expanduser()
HOST = "127.0.0.1"  # literal loopback required by the harness security gate
PORT = int(_cfg_str("port", "DSH_PORT", "3080"))
BROWSER_HOST = "localhost"
BROWSER_AUTHORITY = f"{BROWSER_HOST}:{PORT}"
CONTROL_URL = f"http://{HOST}:{PORT}/"
URL = f"http://{BROWSER_AUTHORITY}/"
# 0.1.2-rc.1 起 / 与 /api 需要一次性 token 换取浏览器 cookie，
# session.list 端点也从 /api/session.list 改为 /api/session/list。
NEW_BROWSER_AUTH_VERSION = (0, 1, 2, 4, 1)
KEYCHAIN_SERVICE = _cfg_str(
    "keychain_service", "DSH_KEYCHAIN_SERVICE", "deepseek-harness/deepseek-api"
)
KEYCHAIN_ACCOUNT = _cfg_str(
    "keychain_account", "DSH_KEYCHAIN_ACCOUNT", "deepseek-api"
)

REGISTRY_INFO_URL = "https://registry.npmjs.org/@deepseek-ai%2Fdsh"
PACKAGE_NAME = "@deepseek-ai/dsh"
BACKUP_DIR = Path(
    _cfg_str(
        "backup_dir",
        "DSH_BACKUP_DIR",
        str(Path.home() / ".local" / "share" / "deepseek-harness" / "backups"),
    )
).expanduser()
DEPLOYMENT_DIR = BACKUP_DIR / "deployments"


def tool_env() -> dict[str, str]:
    """Child environment for npm/dsh tooling.

    A Finder/LaunchServices launch inherits a minimal PATH, while the npm and dsh
    entry points start with `#!/usr/bin/env node`; running them against that PATH
    dies with `env: node: No such file or directory` (reproduced in the launcher's
    update check on 2026-09-11, where it surfaced as a failed "DeepSeek Harness"
    version query, and it would equally break an install). Prepending the resolved
    Node directory keeps every tool call independent of the inherited PATH.
    """
    env = os.environ.copy()
    inherited = env.get("PATH", "")
    node = NODE_BIN or _require_node_bin()
    env["PATH"] = os.pathsep.join(
        part for part in (str(node.parent), inherited) if part
    )
    return env


def _npm_global_root() -> Path | None:
    if NODE_BIN is None or NPM_BIN is None:
        return None
    try:
        out = subprocess.check_output(
            [str(NPM_BIN), "root", "-g"],
            text=True,
            timeout=15,
            env=tool_env(),
            stderr=subprocess.DEVNULL,
        )
        root = Path(out.strip())
        if root.is_dir():
            return root
    except (OSError, subprocess.SubprocessError):
        pass
    return NODE_BIN.parent.parent / "lib" / "node_modules"


def _default_install_prefix() -> Path:
    """Reuse an existing global dsh installation; otherwise keep bootstrap private.

    A fresh macOS user's npm prefix may be system-owned and unwritable. The
    launcher can safely bootstrap into its own user prefix, while an existing
    global CLI remains the update target to avoid splitting installs.
    """
    configured = _cfg_str("install_prefix", "DSH_INSTALL_PREFIX", "")
    if configured:
        return Path(configured).expanduser()

    root = _npm_global_root()
    if root is not None:
        package_dir = root / "@deepseek-ai" / "dsh"
        if package_dir.is_dir():
            return root.parent.parent

    command = shutil.which("dsh")
    if command:
        # Keep the npm bin symlink path intact; resolving it lands under
        # node_modules/@deepseek-ai/dsh/lib and loses the package-manager prefix.
        binary = Path(command).expanduser().absolute()
        if binary.parent.name == "bin":
            return binary.parent.parent

    return Path.home() / ".local" / "share" / "deepseek-harness" / "runtime"


# Installation target: explicit overrides win; an already installed global dsh
# keeps its current npm prefix; a fresh install uses a user-owned private prefix.
# This avoids requiring admin permissions for first-run while keeping later
# update/rollback operations attached to the same dsh tree.
INSTALL_PREFIX = _default_install_prefix()
DSH_INSTALL_DIR = INSTALL_PREFIX / "lib" / "node_modules" / "@deepseek-ai" / "dsh"
DSH_BIN_PREFIX = INSTALL_PREFIX / "bin"
KEEP_BACKUPS = 1  # 历史保留 1 份（加上当前运行/当前数据，共 2 份状态）
# npm's allow-scripts allowlist for the packages that carry lifecycle
# scripts under the dsh tree (escaped so a rewrite npm-run never prompts).
ALLOW_SCRIPT_PACKAGES = (
    "node-pty",
    "koffi",
    "protobufjs",
    "@google/genai",
    "@deepseek-ai/dsh-subprocess-local",
)


def private_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)


def read_state() -> dict[str, object] | None:
    try:
        value = json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError) as exc:
        raise HarnessError(f"无法读取 Harness 状态文件：{exc}") from exc
    if not isinstance(value, dict):
        raise HarnessError("Harness 状态文件格式无效。")
    return value


def write_state(pid: int, pgid: int, auth_url: str | None = None) -> None:
    private_dir(RUNTIME_DIR)
    payload = {
        "schema": 1,
        "pid": pid,
        "pgid": pgid,
        "url": URL,
        "auth_url": auth_url,
        "workspace": str(PLAYGROUND),
        "started_at": datetime.now(timezone.utc).isoformat(),
    }
    temporary = STATE_FILE.with_suffix(".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.chmod(0o600)
    temporary.replace(STATE_FILE)


def clear_state() -> None:
    try:
        STATE_FILE.unlink()
    except FileNotFoundError:
        pass


def process_command(pid: int) -> str | None:
    completed = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "command="],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=3,
        check=False,
    )
    command = completed.stdout.strip()
    return command or None


def state_process(state: dict[str, object] | None) -> tuple[int, int, str] | None:
    if not state:
        return None
    try:
        pid = int(state["pid"])
        pgid = int(state["pgid"])
    except (KeyError, TypeError, ValueError):
        return None
    command = process_command(pid)
    if command is None:
        return None
    expected = (
        ("dsh" in command or "@deepseek-ai/dsh/lib/bin.js" in command)
        and "--profile web" in command
        and f"--host {HOST}" in command
        and f"--port {PORT}" in command
    )
    if not expected:
        raise HarnessError(
            f"状态文件 PID {pid} 属于另一进程，拒绝接管或终止。"
        )
    if os.getpgid(pid) != pgid:
        raise HarnessError(f"Harness PID {pid} 的进程组已变化，拒绝接管。")
    return pid, pgid, command


def http_ready(timeout: float = 1.0) -> bool:
    try:
        with urllib.request.urlopen(CONTROL_URL, timeout=timeout) as response:
            return 200 <= response.status < 400
    except urllib.error.HTTPError as exc:
        # 新版 dsh web 对未认证根路径返回 401，但服务本身已经就绪。
        return exc.code == 401
    except (OSError, urllib.error.URLError):
        return False


def _validated_auth_url(value: object) -> str | None:
    """Accept only the one-time loopback URL emitted for this local server."""
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = urllib.parse.urlsplit(value)
        port = parsed.port
        pairs = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    except ValueError:
        return None
    if (
        parsed.scheme != "http"
        or parsed.hostname not in {"localhost", "127.0.0.1"}
        or port != PORT
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in {"", "/"}
        or parsed.fragment
    ):
        return None
    tokens = [item for key, item in pairs if key == "token"]
    if len(tokens) != 1 or not tokens[0]:
        return None
    return value


def auth_url_from_state(state: dict[str, object] | None) -> str | None:
    if not state:
        return None
    return _validated_auth_url(state.get("auth_url"))


def authenticated_url_from_log(offset: int | None = None) -> str | None:
    """取 dsh web 本次启动打印的带 token 认证地址，不把 token 落到输出。"""
    try:
        content = LOG_FILE.read_text(encoding="utf-8")
    except OSError:
        return None
    if offset is not None:
        if offset > len(content):
            offset = 0
        content = content[offset:]
    candidates = re.findall(r"dsh web: (https?://\S+)", content)
    for candidate in reversed(candidates):
        validated = _validated_auth_url(candidate)
        if validated is not None:
            return validated
    return None


def port_open() -> bool:
    try:
        with socket.create_connection((HOST, PORT), timeout=0.5):
            return True
    except OSError:
        return False


_VERSION_RE = re.compile(
    r"(\d+)\.(\d+)\.(\d+)(?:-(rc|pre|alpha|beta)\.(\d+))?"
)
_PRERELEASE_RANK = {"alpha": 1, "beta": 2, "pre": 3, "rc": 4}
_STABLE_RANK = 5


def parse_version_key(text: str) -> tuple[int, int, int, int, int] | None:
    """Parse `major.minor.patch[-kind.N]` into a comparable 5-tuple.

    Stable releases rank above every prerelease of the same patch level;
    prerelease kinds rank alpha < beta < pre < rc.
    """
    match = _VERSION_RE.search(text)
    if match is None:
        return None
    major, minor, patch = (int(part) for part in match.groups()[:3])
    kind = match.group(4)
    if kind is None:
        return (major, minor, patch, _STABLE_RANK, 0)
    return (major, minor, patch, _PRERELEASE_RANK[kind], int(match.group(5)))


def dsh_version_key() -> tuple[int, int, int, int, int] | None:
    """Parse `dsh --version` into a comparable key; stable releases rank above rc."""
    if NODE_BIN is None:
        return None
    try:
        completed = subprocess.run(
            [str(NODE_BIN), str(_dsh_bin().resolve()), "--version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return parse_version_key(completed.stdout)


def dsh_version_string() -> str | None:
    """Return the installed version as printed by `dsh --version`."""
    if NODE_BIN is None:
        return None
    try:
        completed = subprocess.run(
            [str(NODE_BIN), str(_dsh_bin().resolve()), "--version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0:
        return None
    return completed.stdout.strip() or None


_DISPLAY_VERSION_LINE_RE = re.compile(
    r"(?:dsh\s+)?v?((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)"
    r"(?:-(?:rc|pre|alpha|beta)\.(?:0|[1-9]\d*))?)",
    re.IGNORECASE,
)


def dsh_version_info() -> dict[str, object]:
    """Read only the CLI this controller is configured to run.

    The About panel needs an offline answer that shares the same DSH_BIN and
    Node resolution as start/update. It must not search another global copy or
    expose arbitrary stdout/stderr, which could contain unrelated diagnostics.
    """
    cli = _dsh_bin()
    if not cli.is_file():
        return {"status": "not-installed", "installed": False, "version": None}

    if NODE_BIN is None or not NODE_BIN.is_file():
        return {
            "status": "unavailable", "installed": True, "version": None,
            "reason": "node-unavailable",
        }

    try:
        completed = subprocess.run(
            [str(NODE_BIN), str(cli.resolve()), "--version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=10,
            check=False,
            env=tool_env(),
        )
    except (OSError, subprocess.SubprocessError, UnicodeError, RuntimeError):
        return {
            "status": "unavailable", "installed": True, "version": None,
            "reason": "version-unreadable",
        }

    # Accept a plain semantic version or the conventional `dsh <version>` line
    # only. Never echo tool output, even when it contains a recognizable number.
    line = completed.stdout.strip()
    match = _DISPLAY_VERSION_LINE_RE.fullmatch(line)
    if completed.returncode != 0 or match is None:
        return {
            "status": "unavailable", "installed": True, "version": None,
            "reason": "version-unreadable",
        }
    return {"status": "installed", "installed": True, "version": match.group(1)}


def process_group_children(pgid: int, root_pid: int) -> list[int]:
    """Return other live members of the controller-owned process group."""
    completed = subprocess.run(
        ["/bin/ps", "-axo", "pid=,pgid="],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=3,
        check=False,
    )
    if completed.returncode != 0:
        raise HarnessError("无法检查 Harness 后台任务进程。")
    children: list[int] = []
    for line in completed.stdout.splitlines():
        fields = line.split()
        if len(fields) != 2:
            continue
        try:
            pid, member_pgid = map(int, fields)
        except ValueError:
            continue
        if member_pgid == pgid and pid != root_pid:
            children.append(pid)
    return children


def session_activity_dict() -> dict[str, object]:
    """Return machine-readable service and task activity."""
    state = read_state()
    running = state_process(state)
    if not running:
        if state:
            clear_state()
        return {
            "service_running": False,
            "busy": False,
            "running_session_ids": [],
            "child_process_ids": [],
        }

    pid, pgid, _ = running
    rpc_id = str(uuid.uuid4())
    version_key = dsh_version_key()
    uses_browser_auth = version_key is not None and version_key >= NEW_BROWSER_AUTH_VERSION
    opener = None
    auth_url = auth_url_from_state(state)
    if auth_url is None:
        auth_url = authenticated_url_from_log()
    if uses_browser_auth:
        if auth_url is None:
            raise HarnessError("未能取得 Harness 本次启动的认证地址；无法查询会话活动。")
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor())
        try:
            with opener.open(auth_url, timeout=3):
                pass
        except urllib.error.HTTPError as exc:
            raise HarnessError(
                f"Harness 浏览器认证失败（HTTP {exc.code}）。"
            ) from exc
        except (OSError, urllib.error.URLError) as exc:
            raise HarnessError(f"无法完成 Harness 浏览器认证：{exc}") from exc

    api_path = "/api/session.list"
    rpc_method = "session.list"
    rpc_payload: dict[str, object] = {}
    if uses_browser_auth:
        api_path = "/api/session/list"
        rpc_method = "session/list"
        rpc_payload = {"args": {"_request": {}}}
    body = json.dumps(
        {
            "type": "client-request",
            "rpcId": rpc_id,
            "method": rpc_method,
            "payload": rpc_payload,
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        f"{CONTROL_URL.rstrip('/')}{api_path}",
        data=body,
        headers={
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        if opener is not None:
            with opener.open(request, timeout=3) as response:
                envelope = json.load(response)
        else:
            with urllib.request.urlopen(request, timeout=3) as response:
                envelope = json.load(response)
    except urllib.error.HTTPError as exc:
        raise HarnessError(f"Harness 会话活动查询被拒绝（HTTP {exc.code}）。") from exc
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
        raise HarnessError(f"无法读取 Harness 会话活动：{exc}") from exc

    try:
        if envelope["rpcId"] != rpc_id:
            raise KeyError("rpcId")
        result = envelope["result"]
        if result["ok"] is not True:
            message = result.get("error", {}).get("message", "未知错误")
            raise HarnessError(f"Harness 拒绝会话活动查询：{message}")
        items = result["value"]["items"]
        if not isinstance(items, list):
            raise TypeError("items")
        running_session_ids = []
        for item in items:
            if not isinstance(item, dict) or not isinstance(item.get("running"), bool):
                raise TypeError("session summary")
            if item["running"]:
                session_id = item.get("sessionId")
                if not isinstance(session_id, str) or not session_id:
                    raise TypeError("sessionId")
                running_session_ids.append(session_id)
    except (KeyError, TypeError) as exc:
        raise HarnessError("Harness 会话活动响应格式无效。") from exc

    child_process_ids = process_group_children(pgid, pid)
    return {
        "service_running": True,
        "busy": bool(running_session_ids or child_process_ids),
        "running_session_ids": running_session_ids,
        "child_process_ids": child_process_ids,
    }


def session_activity() -> None:
    """Print machine-readable service and task activity for the native launcher."""
    print(json.dumps(session_activity_dict(), ensure_ascii=False))


def restart_guard(yes: bool) -> str | None:
    """Return a message when a restart must not proceed, else None.

    Busy sessions/blocks refuse unless `yes` is explicit; an unavailable
    activity probe also refuses (fail closed) unless `yes`.
    """
    state = read_state()
    if state_process(state) is None:
        return None
    try:
        activity = session_activity_dict()
    except (HarnessError, OSError, subprocess.SubprocessError) as exc:
        if yes:
            return None
        return (
            f"无法确认 Harness 活动状态（{exc}）；为避免误停任务拒绝重启。"
            "确认安全时可加 --yes。"
        )
    if activity["busy"] and not yes:
        sessions = len(activity.get("running_session_ids") or [])
        children = len(activity.get("child_process_ids") or [])
        return (
            f"检测到 {sessions} 个运行会话、{children} 个后台子进程；"
            "重启会停止它们。请先等任务结束，或确认后加 --yes。"
        )
    return None


def keychain_secret() -> str | None:
    """Best-effort legacy key lookup; a missing item never blocks Web setup.

    Disable Security framework interaction at the API boundary: quiet output and
    closed stdin alone do not suppress Keychain Access prompts. New keys belong
    in upstream Settings → Models.
    """
    try:
        return _read_keychain_noninteractive(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT)
    except Exception:
        return None


def _managed_deepseek_key_present() -> bool:
    """Check the upstream credentials refs map without returning any values.

    Web Settings → Models writes `DEEPSEEK_API_KEY` into this file. Since the
    upstream resolver gives inherited environment variables higher priority,
    injecting a legacy Keychain key after the user saves a new one would make
    the official editor appear ineffective. The generated file has a versioned
    YAML `refs` mapping; scan only for the exact key name and retain no value.
    """
    path = DSH_HOME / ".credentials.yaml"
    in_refs = False
    try:
        with path.open("r", encoding="utf-8") as stream:
            for line in stream:
                if line and not line[0].isspace():
                    in_refs = line.strip() == "refs:"
                    continue
                if in_refs and re.match(
                    r"^\s+(?:DEEPSEEK_API_KEY|'DEEPSEEK_API_KEY'|\"DEEPSEEK_API_KEY\")\s*:",
                    line,
                ):
                    return True
    except (OSError, UnicodeError):
        return False
    return False


def _read_keychain_noninteractive(service: str, account: str) -> str | None:
    """Read one legacy generic-password item without allowing UI authorization."""
    import ctypes

    security = ctypes.CDLL(
        "/System/Library/Frameworks/Security.framework/Security"
    )
    core_foundation = ctypes.CDLL(
        "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
    )
    get_interaction = security.SecKeychainGetUserInteractionAllowed
    get_interaction.argtypes = [ctypes.POINTER(ctypes.c_bool)]
    get_interaction.restype = ctypes.c_int32
    set_interaction = security.SecKeychainSetUserInteractionAllowed
    set_interaction.argtypes = [ctypes.c_bool]
    set_interaction.restype = ctypes.c_int32
    find_password = security.SecKeychainFindGenericPassword
    find_password.argtypes = [
        ctypes.c_void_p, ctypes.c_uint32, ctypes.c_char_p,
        ctypes.c_uint32, ctypes.c_char_p,
        ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_void_p),
        ctypes.POINTER(ctypes.c_void_p),
    ]
    find_password.restype = ctypes.c_int32
    free_content = security.SecKeychainItemFreeContent
    free_content.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    free_content.restype = ctypes.c_int32
    release = core_foundation.CFRelease
    release.argtypes = [ctypes.c_void_p]
    release.restype = None

    old_interaction = ctypes.c_bool()
    if get_interaction(ctypes.byref(old_interaction)) != 0:
        return None
    if set_interaction(False) != 0:
        return None

    service_bytes = service.encode("utf-8")
    account_bytes = account.encode("utf-8")
    password_length = ctypes.c_uint32()
    password_data = ctypes.c_void_p()
    item = ctypes.c_void_p()
    try:
        status = find_password(
            None,
            len(service_bytes), service_bytes,
            len(account_bytes), account_bytes,
            ctypes.byref(password_length), ctypes.byref(password_data),
            ctypes.byref(item),
        )
        if status != 0 or not password_data.value or not password_length.value:
            return None
        raw = ctypes.string_at(password_data, password_length.value)
        secret = raw.decode("utf-8").rstrip("\r\n")
        return secret or None
    finally:
        if password_data.value:
            free_content(None, password_data)
        if item.value:
            release(item)
        set_interaction(old_interaction.value)


def ensure_playground() -> None:
    private_dir(PLAYGROUND)


def start(json_output: bool = False) -> bool:
    if not _dsh_bin().is_file():
        raise HarnessError(
            "未检测到 DeepSeek Harness（dsh CLI）。"
            "请先运行 install-dsh 一键安装，或 npm install -g @deepseek-ai/dsh。"
        )
    node_bin = _require_node_bin()
    state = read_state()
    running = state_process(state)
    if running:
        pid, _, _ = running
        if http_ready():
            auth_url = auth_url_from_state(state) or authenticated_url_from_log()
            if json_output:
                print(
                    json.dumps(
                        {
                            "status": "already_running",
                            "pid": pid,
                            "url": URL,
                            "auth_url": auth_url,
                        },
                        ensure_ascii=False,
                    )
                )
            else:
                print(f"DeepSeek Harness 已在运行（PID {pid}）：{URL}")
            return False
        raise HarnessError(f"Harness 进程 {pid} 存活，但 Web UI 尚不可用；请查看 {LOG_FILE}")
    if state:
        clear_state()
    if port_open():
        raise HarnessError(f"{HOST}:{PORT} 已由未知进程占用；拒绝覆盖。")

    ensure_playground()
    private_dir(DSH_HOME)
    private_dir(RUNTIME_DIR)
    try:
        log_offset = LOG_FILE.stat().st_size
    except OSError:
        log_offset = 0
    child_env = os.environ.copy()
    # The legacy item is a fallback only. An explicit launch env keeps its
    # documented upstream precedence, and a key entered in Models takes effect
    # without deleting or exporting the former Keychain value.
    secret = None
    if "DEEPSEEK_API_KEY" not in child_env and not _managed_deepseek_key_present():
        secret = keychain_secret()
    inherited_path = child_env.get("PATH", "")
    child_env["PATH"] = os.pathsep.join(
        part for part in (str(node_bin.parent), inherited_path) if part
    )
    child_env.update(
        {
            "DSH_HOME": str(DSH_HOME),
            "DSH_PERMISSION_MODE": "workspace-write",
            "DSH_TELEMETRY_MODE": "DISABLED",
        }
    )
    if secret is not None:
        # Keep existing Keychain users working. Fresh users configure a key in
        # the official Web UI; no key is required just to launch it.
        child_env["DEEPSEEK_API_KEY"] = secret
    log_fd = os.open(LOG_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        web_args = [
            "--profile",
            "web",
            "--host",
            HOST,
            "--port",
            str(PORT),
        ]
        version_key = dsh_version_key()
        if version_key is not None and version_key >= (0, 1, 0, 4, 8):
            # rc.8 起 `dsh web` 会在非 SSH 环境下自动打开默认浏览器；
            # 壳子已有自己的 WKWebView 窗口，重复弹出 Safari 标签没有意义。
            web_args.append("--no-open")
        process = subprocess.Popen(
            [str(node_bin), str(_dsh_bin().resolve()), *web_args],
            cwd=PLAYGROUND,
            env=child_env,
            stdin=subprocess.DEVNULL,
            stdout=log_fd,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    finally:
        os.close(log_fd)
        if secret is not None:
            child_env.pop("DEEPSEEK_API_KEY", None)
        secret = ""

    pgid = os.getpgid(process.pid)
    write_state(process.pid, pgid)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        code = process.poll()
        if code is not None:
            clear_state()
            raise HarnessError(
                f"Harness 启动失败（退出码 {code}）；请查看 {LOG_FILE}"
            )
        if http_ready(timeout=0.8):
            auth_url = None
            if version_key is not None and version_key >= NEW_BROWSER_AUTH_VERSION:
                auth_deadline = time.monotonic() + 10
                while time.monotonic() < auth_deadline:
                    auth_url = authenticated_url_from_log(log_offset)
                    if auth_url is not None:
                        break
                    if process.poll() is not None:
                        break
                    time.sleep(0.1)
                if auth_url is None:
                    os.killpg(pgid, signal.SIGTERM)
                    clear_state()
                    raise HarnessError(
                        "Harness 已就绪但未打印认证地址；请查看 "
                        f"{LOG_FILE}"
                    )
            write_state(process.pid, pgid, auth_url)
            if json_output:
                print(
                    json.dumps(
                        {
                            "status": "started",
                            "pid": process.pid,
                            "url": URL,
                            "auth_url": auth_url,
                        },
                        ensure_ascii=False,
                    )
                )
            else:
                print(f"DeepSeek Harness 已启动（PID {process.pid}）：{URL}")
                print(f"默认试玩目录：{PLAYGROUND}")
            return True
        time.sleep(0.25)

    os.killpg(pgid, signal.SIGTERM)
    clear_state()
    raise HarnessError(f"Harness 30 秒内未就绪；已终止，请查看 {LOG_FILE}")


def stop() -> None:
    state = read_state()
    running = state_process(state)
    if not running:
        clear_state()
        print("DeepSeek Harness 当前没有运行。")
        return
    pid, pgid, _ = running
    os.killpg(pgid, signal.SIGTERM)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process_command(pid) is None:
            clear_state()
            print("DeepSeek Harness 已停止。")
            return
        time.sleep(0.2)
    os.killpg(pgid, signal.SIGKILL)
    clear_state()
    print("DeepSeek Harness 未在宽限期退出，已终止其专属进程组。")


def restart(yes: bool = False, json_output: bool = False) -> None:
    guard = restart_guard(yes)
    if guard:
        raise HarnessError(guard)
    # The launcher decodes all of stdout as one StartResult. A stop status line
    # before the JSON makes it discard auth_url and load an unauthenticated page
    # after updates. Keep diagnostics on stderr only in machine-readable mode.
    with contextlib.redirect_stdout(sys.stderr if json_output else sys.stdout):
        stop()
    start(json_output=json_output)
    if not json_output:
        print("DeepSeek Harness 已重启。")


def status() -> int:
    state = read_state()
    running = state_process(state)
    if not running:
        if state:
            clear_state()
        print("DeepSeek Harness：未运行")
        if port_open():
            print(f"警告：{HOST}:{PORT} 由其他进程占用")
            return 2
        return 1
    pid, _, _ = running
    health = "Web UI 可用" if http_ready() else "进程存活，但 Web UI 不可用"
    print(f"DeepSeek Harness：{health}（PID {pid}）")
    print(URL)
    print(f"日志：{LOG_FILE}")
    return 0 if health == "Web UI 可用" else 2


def registry_info() -> dict[str, object]:
    """Fetch dist-tags from the npm registry (read-only)."""
    request = urllib.request.Request(
        REGISTRY_INFO_URL,
        headers={"User-Agent": "deepseek-harness-ctl/1"},
    )
    # The TLS handshake through this Mac's transparent proxy fails
    # intermittently (`EOF occurred in violation of protocol`), measured as
    # 1 of 5 attempts on 2026-09-11, so a bounded retry cycle keeps a healthy
    # registry from looking broken.
    data = None
    last_error = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                data = json.load(response)
            break
        except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
            last_error = exc
            if attempt < 2:
                time.sleep(1.5 * (attempt + 1))
    if data is None:
        raise HarnessError(f"无法查询 npm registry：{last_error}") from last_error
    dist_tags = data.get("dist-tags")
    times = data.get("time")
    if not isinstance(dist_tags, dict) or not isinstance(times, dict):
        raise HarnessError("npm registry 返回的 dist-tags 格式无效。")
    tags: dict[str, dict[str, str]] = {}
    for tag in ("latest", "next", "alpha"):
        version = dist_tags.get(tag)
        if isinstance(version, str) and version:
            tags[tag] = {
                "version": version,
                "published": times.get(version, "") if isinstance(times.get(version), str) else "",
            }
    return tags


def check_update() -> dict[str, object]:
    local = dsh_version_string()
    local_key = parse_version_key(local or "")
    tags = registry_info()
    entry = tags.get("latest")
    if entry is None:
        raise HarnessError("npm registry 未返回 latest dist-tag；拒绝自动选择 next/alpha。")
    candidate_key = parse_version_key(entry["version"])
    if candidate_key is None:
        raise HarnessError(
            f"npm registry 的 latest 标签不是可识别的版本：{entry['version']!r}。"
        )
    recommended: dict[str, str] | None = None
    if local_key is None or candidate_key > local_key:
        recommended = {"tag": "latest", **entry}
    return {
        "local_version": local,
        "registry": tags,
        "update_available": recommended is not None,
        "recommended": recommended,
    }


def prune_backups() -> list[str]:
    """Delete the oldest upgrade backups beyond KEEP_BACKUPS; return removals."""
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    entries = sorted(
        path for path in BACKUP_DIR.iterdir()
        if path.is_dir() and re.match(r"^\d{8}T\d{6}", path.name)
    )
    removed: list[str] = []
    for path in entries[: max(0, len(entries) - KEEP_BACKUPS)]:
        shutil.rmtree(path, ignore_errors=True)
        removed.append(path.name)
    return removed


def backup_dsh() -> Path:
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().astimezone().strftime("%Y%m%dT%H%M%S%z")
    destination = BACKUP_DIR / f"{timestamp}-{uuid.uuid4().hex[:8]}"
    shutil.copytree(DSH_HOME, destination, symlinks=True)
    return destination


def newest_backup_dir() -> Path | None:
    """Return the most recent pre-upgrade backup directory, if any."""
    if not BACKUP_DIR.is_dir():
        return None
    entries = sorted(
        path for path in BACKUP_DIR.iterdir()
        if path.is_dir() and re.match(r"^\d{8}T\d{6}", path.name)
    )
    return entries[-1] if entries else None


def _deployment_manifest_path(snapshot: Path) -> Path:
    return snapshot.with_name(snapshot.name + ".manifest.json")


def deployment_snapshot_path(version: str | None = None) -> Path | None:
    """Find a complete code/data restore point; unpaired snapshots are unusable."""
    if not DEPLOYMENT_DIR.is_dir():
        return None
    entries = sorted(path for path in DEPLOYMENT_DIR.iterdir() if path.is_dir())
    for path in reversed(entries):
        try:
            manifest = json.loads(_deployment_manifest_path(path).read_text(encoding="utf-8"))
            backup = Path(manifest["data_backup"])
            # Validate the package version from the snapshot itself. The manifest
            # binds that exact tree to its data backup, avoiding independent
            # "newest" selection that can pair unrelated user state.
            package = json.loads((path / "package.json").read_text(encoding="utf-8"))
            valid = (
                manifest.get("schema") == 1
                and manifest.get("deployment_snapshot") == path.name
                and manifest.get("version") == package.get("version")
                and backup.is_dir()
            )
        except (OSError, KeyError, TypeError, json.JSONDecodeError):
            continue
        if valid and (version is None or manifest["version"] == version):
            return path
    return None


def backup_deployment(data_backup: Path) -> Path:
    """Snapshot code and atomically record its matching data backup."""
    version = dsh_version_string() or "unknown"
    timestamp = datetime.now().astimezone().strftime("%Y%m%dT%H%M%S%z")
    destination = DEPLOYMENT_DIR / f"{timestamp}-{uuid.uuid4().hex[:8]}-{version}"
    DEPLOYMENT_DIR.mkdir(parents=True, exist_ok=True)
    shutil.copytree(DSH_INSTALL_DIR, destination, symlinks=True)
    manifest = {
        "schema": 1,
        "deployment_snapshot": destination.name,
        "version": version,
        "data_backup": str(data_backup.resolve()),
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    temporary = _deployment_manifest_path(destination).with_suffix(".tmp")
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(_deployment_manifest_path(destination))
    return destination


def restore_deployment_snapshot(snapshot: Path, expected_version: str) -> None:
    """Restore the installed dsh tree from a local snapshot (offline rollback)."""
    if not snapshot.is_dir():
        raise HarnessError(f"部署快照不存在：{snapshot}")
    try:
        manifest = json.loads((snapshot / "package.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise HarnessError(f"部署快照损坏：{exc}") from exc
    if manifest.get("version") != expected_version:
        raise HarnessError(
            f"快照版本 {manifest.get('version')!r} 与期望 {expected_version!r} 不一致。"
        )
    staging = DSH_INSTALL_DIR.parent / f".dsh-restore-staging-{uuid.uuid4().hex[:8]}"
    sidecar = DSH_INSTALL_DIR.parent / (
        f".dsh-replaced-{datetime.now().astimezone().strftime('%Y%m%dT%H%M%S%z')}"
        f"-{uuid.uuid4().hex[:8]}"
    )
    moved = False
    try:
        shutil.copytree(snapshot, staging, symlinks=True, ignore=shutil.ignore_patterns("*.manifest.json"))
        if DSH_INSTALL_DIR.exists():
            DSH_INSTALL_DIR.rename(sidecar)
            moved = True
        staging.rename(DSH_INSTALL_DIR)
    except (OSError, shutil.Error) as exc:
        shutil.rmtree(staging, ignore_errors=True)
        if moved and sidecar.exists() and not DSH_INSTALL_DIR.exists():
            sidecar.rename(DSH_INSTALL_DIR)
        raise HarnessError(f"恢复部署快照失败：{exc}") from exc


def restore_dsh_from_backup(backup: Path) -> Path:
    """Move the current ~/.dsh aside, restore the pre-upgrade backup, and
    return the moved-aside path (the rollback point is the pre-upgrade state;
    no new sessions are created between restart and rollback)."""
    if not backup.is_dir():
        raise HarnessError(f"升级前备份不存在：{backup}")
    sidecar = BACKUP_DIR / (
        f"pre-rollback-{datetime.now().astimezone().strftime('%Y%m%dT%H%M%S%z')}"
        f"-{uuid.uuid4().hex[:8]}"
    )
    staging = DSH_HOME.parent / f".dsh-restore-staging-{uuid.uuid4().hex[:8]}"
    moved = False
    try:
        shutil.copytree(backup, staging, symlinks=True)
        if DSH_HOME.exists():
            DSH_HOME.rename(sidecar)
            moved = True
        staging.rename(DSH_HOME)
    except (OSError, shutil.Error) as exc:
        shutil.rmtree(staging, ignore_errors=True)
        if moved and sidecar.exists():
            try:
                if not DSH_HOME.exists():
                    sidecar.rename(DSH_HOME)
            except OSError:
                pass
        raise HarnessError(f"恢复升级前备份失败：{exc}") from exc
    return sidecar


_SIZE_RE = re.compile(r"\((\d+(?:\.\d+)?)\s*(kB|MB|KB)\)")


def _progress_file_write(path: Path, payload: dict[str, object]) -> None:
    private_dir(path.parent)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    temporary.chmod(0o600)
    temporary.replace(path)


def npm_install_global(spec: str, progress_file: Path | None = None) -> None:
    node = _require_node_bin()
    npm = NPM_BIN or node.parent / "npm"
    if not npm.is_file():
        raise HarnessError(
            f"找不到 npm：{npm}。请重新安装包含 npm 的 Node.js，然后重试。"
        )
    args = [
        str(npm), "install", "--prefix", str(INSTALL_PREFIX), "-g",
        spec, "--no-audit", "--no-fund", "--loglevel=http",
    ]
    for package in ALLOW_SCRIPT_PACKAGES:
        args.append(f"--allow-scripts={package}")
    if progress_file is not None:
        _progress_file_write(progress_file, {"stage": "starting", "received_bytes": 0})
    try:
        process = subprocess.Popen(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=tool_env(),
            start_new_session=True,
        )
    except OSError as exc:
        raise HarnessError(f"无法启动 npm：{exc}") from exc

    output_lines: list[str] = []
    received = 0
    assert process.stdout is not None
    # Reading stdout directly can block forever before wait(timeout) is reached.
    # A reader queue keeps progress streaming while enforcing the whole install
    # deadline, including stalled downloads and lifecycle scripts.
    lines: queue.Queue[str | None] = queue.Queue()
    def read_output() -> None:
        try:
            for line in process.stdout:
                lines.put(line)
        finally:
            lines.put(None)
    reader = threading.Thread(target=read_output, daemon=True)
    reader.start()
    install_deadline = time.monotonic() + 600
    try:
        while True:
            remaining = install_deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(args, 600)
            try:
                line = lines.get(timeout=remaining)
            except queue.Empty:
                raise subprocess.TimeoutExpired(args, 600)
            if line is None:
                break
            output_lines.append(line)
            if progress_file is not None:
                match = _SIZE_RE.search(line)
                stage = "installing"
                if "http" in line.lower() and "fetch" in line.lower():
                    stage = "downloading"
                    if match:
                        amount = float(match.group(1))
                        unit = match.group(2).lower()
                        received += int(amount * (1_000_000 if unit == "mb" else 1_000))
                _progress_file_write(
                    progress_file,
                    {"stage": stage, "received_bytes": received},
                )
        process.wait(timeout=max(0.1, install_deadline - time.monotonic()))
    except subprocess.TimeoutExpired as exc:
        # npm's lifecycle children can keep the pipe/process tree alive; kill
        # only this controller-created group, never a shared Node service.
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        raise HarnessError("npm 安装超时（10 分钟）；请检查网络与 npm 状态。") from exc
    if progress_file is not None:
        _progress_file_write(progress_file, {"stage": "done", "received_bytes": received})

    output = "".join(output_lines).strip()
    if process.returncode != 0:
        detail = output[-800:] or "无输出"
        raise HarnessError(f"npm 安装失败（退出码 {process.returncode}）：{detail}")
    for package in ALLOW_SCRIPT_PACKAGES:
        # 即使 allow-scripts 白名单传了，也要确认脚本真的被执行过；
        # 静默跳过脚本会让原生依赖在 require 时失败。
        if package.split("/")[-1] not in output:
            if "added" not in output and "up to date" not in output:
                raise HarnessError(
                    f"npm 输出异常（未提及 {package}）；请人工核对。"
                )


def _restart_and_smoke(
    from_version: str, target: str, backup: Path, snapshot: Path
) -> dict[str, object]:
    """Start and probe the new deployment, restoring its paired old state on failure."""
    try:
        start()
        session_activity_dict()  # smoke: version-aware auth + session API both work
    except Exception as exc:
        sidecar: Path | None = None
        try:
            stop()
            if snapshot is None:
                raise HarnessError(f"找不到 {from_version} 的本地代码/数据配对快照；拒绝联网假回滚。")
            manifest = json.loads(_deployment_manifest_path(snapshot).read_text(encoding="utf-8"))
            old_data = Path(manifest["data_backup"])
            restore_deployment_snapshot(snapshot, from_version)
            if dsh_version_string() != from_version:
                raise HarnessError("回滚安装后版本校验失败。")
            sidecar = restore_dsh_from_backup(old_data)
            start()
            session_activity_dict()
        except Exception as rollback_exc:
            stopped = False
            stop_error: Exception | None = None
            try:
                stop()
                stopped = True
            except Exception as exc:
                stop_error = exc
            service_state = "服务已停止" if stopped else f"停止服务也失败（{stop_error}），请立即检查服务状态"
            return {
                "status": "rollback_failed",
                "message": (
                    f"新版 {target} 重启后无法访问（{exc}），自动回滚到 {from_version} 也失败"
                    f"（{rollback_exc}）。{service_state}；可查看运行日志 {LOG_FILE} 和本地快照，"
                    f"或从升级前备份 {backup} 恢复（升级前原样备份已移至 "
                    f"{sidecar or 'pre-rollback-* 目录'}）。"
                ),
            }
        return {
            "status": "rolled_back",
            "message": (
                f"新版 {target} 重启后无法访问（{exc}），已自动回滚到 {from_version}、"
                f"恢复升级前数据并重启服务。升级前备份保留于 {backup}。"
            ),
        }
    return {
        "status": "installed_restarted",
        "message": f"已升级到 {target} 并重启；活动检查正常。",
    }


def _stop_for_transaction() -> None:
    """Keep lifecycle diagnostics off stdout, which may carry one JSON result."""
    with contextlib.redirect_stdout(sys.stderr):
        stop()


def update_harness(restart: bool = False, yes: bool = False) -> dict[str, object]:
    info = check_update()
    if not info["update_available"]:
        return {
            "status": "up_to_date",
            "local_version": info["local_version"],
            "latest": (info["registry"].get("latest") or {}).get("version"),
            "message": "已是最新版本。",
        }
    target = info["recommended"]
    assert target is not None
    from_version = info["local_version"]
    guard = restart_guard(yes)
    if guard:
        return {"status": "update_pending", "message": f"更新被守卫拦下：{guard}"}
    was_running = state_process(read_state()) is not None
    backup: Path | None = None
    snapshot: Path | None = None
    install_started = False
    try:
        # npm may remove files from the live package tree while replacing it.
        # Stop before copying data too: this yields a consistent data snapshot.
        _stop_for_transaction()
        backup = backup_dsh()
        snapshot = backup_deployment(backup)
        install_started = True
        npm_install_global(f"{PACKAGE_NAME}@{target['version']}")
        new_version = dsh_version_string()
        if parse_version_key(new_version or "") != parse_version_key(target["version"]):
            raise HarnessError(
                f"安装后版本 {new_version!r} 与目标 {target['version']!r} 不一致。"
            )
    except Exception as install_exc:
        recovery_error: Exception | None = None
        try:
            _stop_for_transaction()
            if install_started:
                assert backup is not None and snapshot is not None
                restore_deployment_snapshot(snapshot, from_version)
                restore_dsh_from_backup(backup)
                if dsh_version_string() != from_version:
                    raise HarnessError("恢复后版本校验失败。")
            if was_running:
                start()
                session_activity_dict()
        except Exception as exc:
            recovery_error = exc
        if recovery_error is not None:
            return {
                "status": "rollback_failed",
                "backup": str(backup) if backup else None,
                "deployment_snapshot": str(snapshot) if snapshot else None,
                "message": f"更新失败（{install_exc}），恢复原状态也失败（{recovery_error}）；"
                           f"已有数据备份 {backup or '无'}、部署快照 {snapshot or '无'} 均予以保留。",
            }
        return {
            "status": "rolled_back" if install_started else "update_failed",
            "from": from_version,
            "backup": str(backup) if backup else None,
            "deployment_snapshot": str(snapshot) if snapshot else None,
            "message": (
                f"更新失败（{install_exc}），已恢复 {from_version} 的代码与数据。"
                if install_started else f"更新未安装：准备一致快照失败（{install_exc}）；未触碰部署文件。"
            ),
        }
    if not restart:
        return {
            "status": "installed_pending_restart",
            "from": from_version,
            "to": target["version"],
            "backup": str(backup),
            "deployment_snapshot": str(snapshot),
            "message": (
                f"已安装 {target['version']}。服务已停止以保护安装文件；"
                "关闭并重新打开 DeepSeek Harness App 后生效。"
            ),
        }
    return _restart_and_smoke(from_version, target["version"], backup, snapshot)


def rollback_harness(to_version: str, yes: bool = False) -> dict[str, object]:
    current = dsh_version_string() or "未知"
    snapshot = deployment_snapshot_path(version=to_version)
    guard = restart_guard(yes)
    if guard:
        return {
            "status": "rollback_pending",
            "to": to_version,
            "message": f"回滚被守卫拦下，未写入任何文件：{guard}",
        }
    if snapshot is None:
        return {
            "status": "rollback_unavailable",
            "to": to_version,
            "message": f"没有与 {to_version} 配对且完整的本地代码/数据快照；拒绝联网安装或猜测数据备份。",
        }
    try:
        manifest = json.loads(_deployment_manifest_path(snapshot).read_text(encoding="utf-8"))
        target_data = Path(manifest["data_backup"])
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as exc:
        return {"status": "rollback_unavailable", "to": to_version, "message": f"回滚快照清单无效：{exc}"}
    was_running = state_process(read_state()) is not None
    current_data: Path | None = None
    current_snapshot: Path | None = None
    try:
        _stop_for_transaction()
        current_data = backup_dsh()
        current_snapshot = backup_deployment(current_data)
    except Exception as snapshot_exc:
        restart_error: Exception | None = None
        if was_running:
            try:
                start()
                session_activity_dict()
            except Exception as exc:
                restart_error = exc
        return {
            "status": "rollback_failed",
            "to": to_version,
            "message": f"回滚前无法创建一致的当前状态快照（{snapshot_exc}）；未写入目标部署。"
                       + (f"原服务恢复也失败（{restart_error}）。" if restart_error else ""),
        }
    try:
        restore_deployment_snapshot(snapshot, to_version)
        restore_dsh_from_backup(target_data)
        if dsh_version_string() != to_version:
            raise HarnessError(f"回滚安装后版本不是 {to_version}。")
        start()
        session_activity_dict()
    except Exception as exc:
        try:
            _stop_for_transaction()
            assert current_snapshot is not None and current_data is not None
            current_manifest = json.loads(_deployment_manifest_path(current_snapshot).read_text(encoding="utf-8"))
            restore_deployment_snapshot(current_snapshot, current)
            restore_dsh_from_backup(Path(current_manifest["data_backup"]))
            if was_running:
                start()
                session_activity_dict()
        except Exception as recovery_exc:
            return {
                "status": "rollback_failed",
                "to": to_version,
                "message": f"回滚失败（{exc}），恢复原状态也失败（{recovery_exc}）；"
                           f"原代码快照 {current_snapshot}、数据备份 {current_data} 均已保留。",
            }
        return {
            "status": "rollback_failed",
            "to": to_version,
            "message": f"回滚失败（{exc}），已恢复原版本 {current} 与原数据。",
        }
    return {
        "status": "rolled_back",
        "to": to_version,
        "restored_from": str(target_data),
        "message": (
            f"已从本地快照回滚到 {to_version} 并恢复配对数据 {target_data}。"
        ),
    }


def open_ui() -> None:
    start()
    completed = subprocess.run(["/usr/bin/open", URL], check=False)
    if completed.returncode != 0:
        raise HarnessError(f"浏览器未能打开；请手动访问 {URL}")


def install_dsh(progress_file: Path | None = None) -> dict[str, object]:
    """One-click bootstrap: install a fresh @deepseek-ai/dsh with the same
    allow-scripts allowlist used by the update path (no interactive prompts)."""
    binary = _dsh_bin()
    if binary.is_file():
        return {
            "status": "already_installed",
            "version": dsh_version_string(),
            "message": "DeepSeek Harness 已安装。",
        }
    binary_existed = binary.exists() or binary.is_symlink()
    package_existed = DSH_INSTALL_DIR.exists() or DSH_INSTALL_DIR.is_symlink()
    try:
        npm_install_global(PACKAGE_NAME, progress_file=progress_file)
        version = dsh_version_string()
        if version is None:
            raise HarnessError("安装完成但无法读取版本；请检查 npm 输出。")
    except BaseException:
        # npm can leave a partial package or entry point after a network/build
        # failure. Since this path began without a CLI, clear only artifacts
        # that were absent before the attempt so first-run can be retried.
        if not binary_existed and (binary.is_file() or binary.is_symlink()):
            binary.unlink(missing_ok=True)
        if not package_existed:
            if DSH_INSTALL_DIR.is_symlink():
                DSH_INSTALL_DIR.unlink(missing_ok=True)
            elif DSH_INSTALL_DIR.is_dir():
                shutil.rmtree(DSH_INSTALL_DIR)
        raise
    return {
        "status": "installed",
        "version": version,
        "message": f"已安装 DeepSeek Harness {version}。",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="控制本机 DeepSeek Harness Web UI")
    parser.add_argument(
        "action",
        choices=(
            "open",
            "start",
            "stop",
            "restart",
            "status",
            "activity",
            "version",
            "log-path",
            "check-update",
            "update",
            "rollback",
            "install-dsh",
        ),
        nargs="?",
        default="open",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="以 JSON 输出 check-update / update / activity / version 的结果",
    )
    parser.add_argument(
        "--restart",
        action="store_true",
        help="update：安装后守卫式重启并冒烟，失败自动回滚",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="跳过活动线程守卫（仅在确认安全时使用）",
    )
    parser.add_argument(
        "--to",
        metavar="VERSION",
        help="rollback：回滚到的版本",
    )
    parser.add_argument(
        "--progress-file",
        metavar="PATH",
        help="install-dsh：安装进度写入的文件（供前端轮询）",
    )
    args = parser.parse_args()
    try:
        if args.action == "open":
            open_ui()
        elif args.action == "start":
            start(json_output=args.json)
        elif args.action == "stop":
            stop()
        elif args.action == "restart":
            restart(yes=args.yes, json_output=args.json)
        elif args.action == "status":
            return status()
        elif args.action == "activity":
            session_activity()
        elif args.action == "version":
            info = dsh_version_info()
            if args.json:
                print(json.dumps(info, ensure_ascii=False, indent=2))
            elif info["status"] == "installed":
                print(f"DeepSeek Harness {info['version']}")
            elif info["status"] == "not-installed":
                print("DeepSeek Harness 尚未安装。")
            else:
                print("DeepSeek Harness 已安装，但暂时无法读取版本。")
        elif args.action == "check-update":
            info = check_update()
            if args.json:
                print(json.dumps(info, ensure_ascii=False, indent=2))
            else:
                local = info["local_version"] or "未知"
                print(f"本地版本：{local}")
                for tag, entry in (info["registry"] or {}).items():
                    print(f"{tag}：{entry['version']}")
                if info["update_available"]:
                    recommended = info["recommended"]
                    print(f"可更新到 {recommended['version']}（{recommended['tag']} tag）")
                else:
                    print("已是最新版本。")
        elif args.action == "update":
            # A successful restart prints lifecycle/browser-entry diagnostics.
            # Keep the *entire* transaction off machine-readable stdout, not
            # just its initial stop: otherwise npm succeeds but the native UI
            # reports a JSON parse failure. This also covers recovery branches.
            with contextlib.redirect_stdout(sys.stderr) if args.json else contextlib.nullcontext():
                result = update_harness(restart=args.restart, yes=args.yes)
            if args.json:
                print(json.dumps(result, ensure_ascii=False, indent=2))
            else:
                print(result["message"])
                if result.get("backup"):
                    print(f"升级前备份：{result['backup']}")
        elif args.action == "rollback":
            if not args.to:
                raise HarnessError("rollback 需要 --to <版本>。")
            with contextlib.redirect_stdout(sys.stderr) if args.json else contextlib.nullcontext():
                result = rollback_harness(args.to, yes=args.yes)
            if args.json:
                print(json.dumps(result, ensure_ascii=False, indent=2))
            else:
                print(result["message"])
        elif args.action == "install-dsh":
            progress_file = None
            if args.progress_file:
                progress_file = Path(args.progress_file).expanduser()
            result = install_dsh(progress_file=progress_file)
            if args.json:
                print(json.dumps(result, ensure_ascii=False, indent=2))
            else:
                print(result["message"])
        elif args.action == "log-path":
            print(LOG_FILE)
    except (HarnessError, OSError, subprocess.SubprocessError) as exc:
        print(f"DeepSeek Harness：{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
