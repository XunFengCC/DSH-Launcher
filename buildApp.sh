#!/bin/zsh

set -euo pipefail

# Profile: release (default) or dev. Dev gets its own bundle id suffix and
# display name, drops the URL scheme (so the release keeps deepseek-harness://),
# and runs on its own settings file / port via the Swift-side -dev detection.
launcher_profile="release"
if [[ "${1:-}" == "--profile" && "${2:-}" != "" ]]; then
  launcher_profile="$2"
fi

launcher_source_dir=${0:A:h}
launcher_arch="${DSH_BUILD_ARCH:-$(/usr/bin/uname -m)}"
[[ "$launcher_arch" == arm64 || "$launcher_arch" == x86_64 ]] || { print -u2 'DSH_BUILD_ARCH must be arm64 or x86_64'; exit 64; }
launcher_build_root=$(/usr/bin/mktemp -d /private/tmp/deepseek-harness-launcher.XXXXXX)
if [[ "$launcher_profile" == "dev" ]]; then
  launcher_app_name="DSH Launcher Dev"
else
  launcher_app_name="DSH Launcher"
fi
launcher_app_path="$launcher_build_root/$launcher_app_name.app"
launcher_contents_path="$launcher_app_path/Contents"
launcher_macos_path="$launcher_contents_path/MacOS"
launcher_resources_path="$launcher_contents_path/Resources"
# Locate the official DSH web-frontend favicon: explicit override, then the
# npm global tree (wherever `npm root -g` points).
launcher_icon_source="${DSH_LAUNCHER_FAVICON:-}"
if [[ -z "$launcher_icon_source" ]]; then
  launcher_npm_root="$(npm root -g 2>/dev/null || true)"
  launcher_icon_source="$launcher_npm_root/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-web-frontend/dist/favicon.svg"
  [[ -f "$launcher_icon_source" ]] || launcher_icon_source=""
fi
if [[ -z "$launcher_icon_source" ]]; then
  /usr/bin/printf '无法定位官方 favicon；请安装 @deepseek-ai/dsh 或设置 DSH_LAUNCHER_FAVICON 指向 dsh-web-frontend/dist/favicon.svg\n' >&2
  exit 1
fi

/bin/mkdir -p "$launcher_macos_path" "$launcher_resources_path"
/usr/bin/xcrun swiftc \
  -O \
  -parse-as-library \
  -target "$launcher_arch-apple-macosx14.0" \
  -module-cache-path "$launcher_build_root/ModuleCache" \
  -framework AppKit \
  -framework WebKit \
  "$launcher_source_dir/Sources/main.swift" \
  "$launcher_source_dir/Sources/AccountLogin.swift" \
  "$launcher_source_dir/Sources/FeedbackCore.swift" \
  "$launcher_source_dir/Sources/FeedbackWindow.swift" \
  "$launcher_source_dir/Sources/LauncherUpdates.swift" \
  "$launcher_source_dir/Sources/RuntimeBootstrap.swift" \
  -o "$launcher_macos_path/DeepSeekHarness"
/bin/cp "$launcher_source_dir/Info.plist" "$launcher_contents_path/Info.plist"
# The controller is part of the signed product, not a per-machine installation
# prerequisite. Overrides remain useful for isolated tests and developers.
/bin/cp "$launcher_source_dir/controller/deepseekHarness.py" "$launcher_resources_path/deepseekHarness.py"
/bin/cp "$launcher_source_dir/LICENSE" "$launcher_resources_path/LICENSE"
/bin/cp "$launcher_source_dir/THIRD_PARTY_NOTICES.md" "$launcher_resources_path/THIRD_PARTY_NOTICES.md"
# Auto-derived build number (monotonic git commit count) so every build is
# distinguishable, independent of the marketing version string.
# A clean public initial snapshot has a new Git history. Release builds may
# explicitly preserve the monotonic build number from the private development
# line; record that value with the public source revision in release receipts.
launcher_build_number="${DSH_BUILD_NUMBER:-$(git -C "$launcher_source_dir" rev-list --count HEAD 2>/dev/null || true)}"
[[ "$launcher_build_number" == <-> && "$launcher_build_number" -gt 0 ]] || {
  print -u2 'DSH_BUILD_NUMBER must be a positive integer'; exit 64
}
launcher_source_revision="$(git -C "$launcher_source_dir" rev-parse HEAD 2>/dev/null || true)"
if [[ "$launcher_build_number" != "" ]]; then
  /usr/bin/python3 - "$launcher_contents_path/Info.plist" "$launcher_build_number" "$launcher_source_revision" <<'PYEOF'
import plistlib, sys

path, build, revision = sys.argv[1:]
with open(path, "rb") as f:
    data = plistlib.load(f)
data["CFBundleVersion"] = str(build)
data["DSHSourceRevision"] = revision
with open(path, "wb") as f:
    plistlib.dump(data, f, sort_keys=False)
PYEOF
fi
if [[ "$launcher_profile" == "dev" ]]; then
  /usr/bin/python3 - "$launcher_contents_path/Info.plist" <<'PYEOF'
import plistlib, sys

path = sys.argv[1]
with open(path, "rb") as f:
    data = plistlib.load(f)
data["CFBundleIdentifier"] = data["CFBundleIdentifier"] + "-dev"
data["CFBundleDisplayName"] = "DSH Launcher Dev"
data["CFBundleName"] = "DSH Launcher Dev"
data.pop("CFBundleURLTypes", None)  # keep the release owning deepseek-harness://
with open(path, "wb") as f:
    plistlib.dump(data, f, sort_keys=False)
PYEOF
fi

launcher_icon_work="$launcher_build_root/icon-work"
launcher_iconset="$launcher_icon_work/AppIcon.iconset"
/bin/mkdir -p "$launcher_iconset"

# The official favicon adapts its path color through prefers-color-scheme.
# Quick Look can bake its white dark-mode path onto a white icon canvas, which
# produces a genuinely blank Dock icon. Preserve the official whale geometry,
# but give the non-adaptive .icns a fixed high-contrast black/white treatment.
launcher_icon_svg="$launcher_icon_work/AppIcon.svg"
launcher_icon_png="$launcher_icon_work/AppIcon.png"
/bin/cp "$launcher_icon_source" "$launcher_icon_svg"
/usr/bin/perl -0pi -e '
  s{<style>.*?</style>}{}s;
  s{<svg[^>]*>}{<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><rect x="64" y="64" width="896" height="896" rx="208" fill="#0B0B0D"/><rect x="70" y="70" width="884" height="884" rx="202" fill="none" stroke="#2B2B30" stroke-width="12"/><g transform="translate(152 152) scale(14.4)">};
  s{fill="#000"}{fill="#FFFFFF"};
  s{</svg>}{</g></svg>};
' "$launcher_icon_svg"
if ! /usr/bin/grep -q 'fill="#FFFFFF"' "$launcher_icon_svg"; then
  /usr/bin/printf 'Unable to prepare the official DSH whale icon: %s\n' "$launcher_icon_source" >&2
  exit 1
fi
/usr/bin/sips -s format png -z 1024 1024 "$launcher_icon_svg" \
  --out "$launcher_icon_png" >/dev/null
for launcher_icon_spec in \
  '16 icon_16x16.png' \
  '32 icon_16x16@2x.png' \
  '32 icon_32x32.png' \
  '64 icon_32x32@2x.png' \
  '128 icon_128x128.png' \
  '256 icon_128x128@2x.png' \
  '256 icon_256x256.png' \
  '512 icon_256x256@2x.png' \
  '512 icon_512x512.png' \
  '1024 icon_512x512@2x.png'; do
  launcher_icon_size=${launcher_icon_spec%% *}
  launcher_icon_name=${launcher_icon_spec#* }
  /usr/bin/sips -z "$launcher_icon_size" "$launcher_icon_size" "$launcher_icon_png" \
    --out "$launcher_iconset/$launcher_icon_name" >/dev/null
done
/usr/bin/iconutil -c icns "$launcher_iconset" -o "$launcher_resources_path/AppIcon.icns"

# 代码签名身份解析。默认 auto：登录钥匙串里有 Developer ID Application 就用它
# （带 Hardened Runtime 与安全时间戳，可公证），否则保持 ad-hoc（离线可用）。
# 可用 DSH_SIGNING_IDENTITY 指定完整身份名或 40 位 SHA-1（指定即必须可用），
# 或用 DSH_SIGNING_MODE=adhoc|developer-id|auto 强制某一档。身份存在但不可用时
# fail closed，不静默退回 ad-hoc。
_dsh_list_identities() {
  /usr/bin/security find-identity -v -p codesigning "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null
}
# 用 zsh 字符串匹配而不是 `security ... | grep -q`：buildApp.sh 开着
# `set -o pipefail`，下游命中即退出会让 security 收到 SIGPIPE，管道整体被判失败，
# 把有效身份误判成不可用。
_dsh_identity_usable() {
  local candidate="$1" text
  [[ "$candidate" == "-" ]] && return 0
  text="$(_dsh_list_identities)"
  if [[ ${#candidate} == 40 && "$candidate" != *[^0-9A-Fa-f]* ]]; then
    [[ "${text:u}" == *"${candidate:u}"* ]]
  else
    [[ "$text" == *"\"$candidate\""* ]]
  fi
}
_dsh_find_developer_id() {
  local line
  for line in "${(@f)$(_dsh_list_identities)}"; do
    if [[ "$line" == *'"Developer ID Application: '*'"'* ]]; then
      line="${line#*\"}"
      /usr/bin/printf '%s\n' "${line%%\"*}"
      return 0
    fi
  done
  return 0
}
launcher_signing_mode="${DSH_SIGNING_MODE:-auto}"
launcher_signing_identity="${DSH_SIGNING_IDENTITY:-}"
launcher_signing_kind="adhoc"
if [[ -n "$launcher_signing_identity" ]]; then
  _dsh_identity_usable "$launcher_signing_identity" || {
    /usr/bin/printf 'DSH_SIGNING_IDENTITY 不可用：%s\n' "$launcher_signing_identity" >&2
    exit 70
  }
  [[ "$launcher_signing_identity" == "-" ]] || launcher_signing_kind="signed"
elif [[ "$launcher_signing_mode" == "developer-id" ]]; then
  launcher_signing_identity="$(_dsh_find_developer_id)"
  [[ -n "$launcher_signing_identity" ]] || {
    /usr/bin/printf 'DSH_SIGNING_MODE=developer-id，但钥匙串里没有 Developer ID Application 证书。\n' >&2
    exit 70
  }
  launcher_signing_kind="signed"
elif [[ "$launcher_signing_mode" == "auto" ]]; then
  launcher_signing_identity="$(_dsh_find_developer_id)"
  [[ -z "$launcher_signing_identity" ]] || launcher_signing_kind="signed"
elif [[ "$launcher_signing_mode" != "adhoc" ]]; then
  /usr/bin/printf '未知 DSH_SIGNING_MODE：%s（可用 adhoc/developer-id/auto）\n' "$launcher_signing_mode" >&2
  exit 64
fi

if [[ "$launcher_signing_kind" == "signed" ]]; then
  /usr/bin/codesign --force --options runtime --timestamp \
    --sign "$launcher_signing_identity" "$launcher_app_path" >/dev/null
else
  launcher_signing_identity="-"
  /usr/bin/codesign --force --sign - --timestamp=none "$launcher_app_path" >/dev/null
fi

/bin/chmod -R go-w "$launcher_app_path"
/usr/bin/printf '%s\n' "$launcher_app_path"
