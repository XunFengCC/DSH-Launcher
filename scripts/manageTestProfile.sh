#!/bin/zsh
# Generate isolated test settings without replacing a user's real settings.
# Launch a test process with DSH_SETTINGS pointing to the generated file.

set -euo pipefail

test_dir="${1:-}"
[[ -n "$test_dir" && ! -e "$test_dir" ]] || { print -u2 '用法：manageTestProfile.sh <尚不存在的隔离目录>'; exit 64; }
mkdir -p "$test_dir"
chmod 700 "$test_dir"
/usr/bin/python3 - "$test_dir" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
settings = root / 'settings.json'
settings.write_text(json.dumps({
    'dsh_home': str(root / 'data'),
    'workspace': str(root / 'workspace'),
    'backup_dir': str(root / 'backups'),
    'install_prefix': str(root / 'runtime'),
    'dsh_bin': str(root / 'runtime' / 'bin' / 'dsh'),
    'keychain_service': 'DSH-Launcher-isolated-test-no-credential',
    'port': '3082'
}, indent=2) + '\n')
settings.chmod(0o600)
print(f'DSH_SETTINGS={settings}')
PY
