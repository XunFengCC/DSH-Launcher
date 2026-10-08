#!/bin/zsh
# Build from the current source, notarize/staple App before wrapping it, then
# notarize/staple DMG. No install, public upload, key creation or secret argv.
set -euo pipefail
source_dir=${0:A:h:h}
release_dir="${DSH_RELEASE_DIR:-$source_dir/build/release-candidate}"
# DSHSourceRevision is useful only when the packaged source exactly matches its
# checkpoint. Ordinary dev builds may be dirty; release packaging must not emit
# a signed App that claims the previous commit while containing later edits.
[[ -z "$(git -C "$source_dir" status --porcelain)" ]] || {
  print -u2 '源码尚未保存为干净的 Git checkpoint，拒绝生成发行来源不一致的包。'
  exit 65
}
[[ ! -e "$release_dir" ]] || { print -u2 "产物目录已存在，拒绝覆盖：$release_dir"; exit 73; }
[[ -n "${DSH_NOTARY_PROFILE:-}" ]] || { print -u2 '设置现有钥匙串公证配置名 DSH_NOTARY_PROFILE'; exit 64; }
export DSH_SIGNING_MODE=developer-id
app_path=$(zsh "$source_dir/buildApp.sh" | tail -1)
mkdir -p "$release_dir"
ditto "$app_path" "$release_dir/DSH Launcher.app"
app_path="$release_dir/DSH Launcher.app"
zsh "$source_dir/scripts/notarizeDSH.sh" "$app_path"
version=$(/usr/libexec/PlistBuddy -c 'Print :DSHReleaseVersion' "$app_path/Contents/Info.plist")
arch="${DSH_BUILD_ARCH:-$(/usr/bin/uname -m)}"
base="DSH-Launcher-$version-macOS-$arch"
ditto -c -k --keepParent "$app_path" "$release_dir/$base.zip"
stage=$(mktemp -d /private/tmp/dsh-dmg.XXXXXX)
trap 'rm -rf -- "$stage"' EXIT INT TERM
ditto "$app_path" "$stage/DSH Launcher.app"
ln -s /Applications "$stage/Applications"
cp "$source_dir/README.md" "$stage/使用说明.md"
hdiutil create -volname 'DSH Launcher' -srcfolder "$stage" -ov -format UDZO "$release_dir/$base.dmg"
identity="${DSH_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)}"
[[ -n "$identity" ]] || { print -u2 '没有可用的 Developer ID 身份'; exit 70; }
codesign --sign "$identity" --timestamp "$release_dir/$base.dmg"
zsh "$source_dir/scripts/notarizeDSH.sh" "$release_dir/$base.dmg"
(cd "$release_dir" && shasum -a 256 "$base.zip" "$base.dmg" > SHA256SUMS)
print "发行候选已准备：$release_dir"
