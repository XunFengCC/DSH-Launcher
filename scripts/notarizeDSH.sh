#!/bin/zsh
# notarizeDSH.sh — 用 notarytool 提交 DSH Launcher 公证并 staple。
#
# 用法：scripts/notarizeDSH.sh <DSH Launcher.app|*.dmg> [--profile 钥匙串配置名]
#
# 凭据只存钥匙串，脚本与仓库不保存 Apple ID 密码或 app 专用密码。首次配置：
#   xcrun notarytool store-credentials dsh-notary \
#     --apple-id <你的 Apple ID> --team-id <你的 Team ID>
# 按 notarytool 的安全交互提示填写 app 专用密码，不把密码写进 shell 历史。
# 之后用 --keychain-profile dsh-notary 调用；也可用 DSH_NOTARY_PROFILE 指定配置名。
#
# 为什么 .app 和 DMG 要各自公证：DMG 会继承内部 App 的公证结果，但两者都要自己
# 的 staple 票据，用户离线首次打开时才不依赖在线查询公证状态。
set -euo pipefail

artifact="${1:-}"
profile="${DSH_NOTARY_PROFILE:-}"
if [[ "${2:-}" == "--profile" && -n "${3:-}" ]]; then
  profile="$3"
fi
[[ -n "$artifact" ]] || { /usr/bin/printf '用法：%s <路径.app|路径.dmg> [--profile 配置名]\n' "${0:t}" >&2; exit 64; }
[[ -e "$artifact" ]] || { /usr/bin/printf '产物不存在：%s\n' "$artifact" >&2; exit 66; }
[[ -n "$profile" ]] || { /usr/bin/printf '缺少公证凭据配置名：设置 DSH_NOTARY_PROFILE 或传 --profile。\n' >&2; exit 64; }

artifact="${artifact:A}"
work="$(/usr/bin/mktemp -d /private/tmp/dsh-notary.XXXXXX)"
cleanup() { /bin/rm -rf -- "$work"; }
trap cleanup EXIT INT TERM

case "$artifact" in
  *.app)
    upload="$work/$(/usr/bin/basename "$artifact").zip"
    /usr/bin/ditto -c -k --keepParent "$artifact" "$upload" ;;
  *.dmg|*.pkg|*.zip)
    upload="$artifact" ;;
  *)
    /usr/bin/printf '不支持的公证产物类型（需要 .app/.dmg/.pkg/.zip）：%s\n' "$artifact" >&2
    exit 64 ;;
esac

/usr/bin/printf '提交公证：%s\n' "$artifact"
submit_json="$work/submit.json"
if ! /usr/bin/xcrun notarytool submit "$upload" --keychain-profile "$profile" \
    --wait --output-format json > "$submit_json"; then
  /usr/bin/printf 'notarytool 提交失败；原始输出：\n' >&2
  /bin/cat "$submit_json" >&2 || true
  exit 1
fi

submission_id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$submit_json" 2>/dev/null || true)"
# 不能叫 status：zsh 里 status 是只读特殊参数（等同 $?），赋值会直接报错退出。
notary_status="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$submit_json" 2>/dev/null || true)"
/usr/bin/printf '公证结果：%s（submission %s）\n' "${notary_status:-未知}" "${submission_id:-未知}"

if [[ "$notary_status" != "Accepted" ]]; then
  /usr/bin/printf '公证未通过。Apple 的问题日志：\n' >&2
  if [[ -n "$submission_id" ]]; then
    /usr/bin/xcrun notarytool log "$submission_id" --keychain-profile "$profile" >&2 || true
  fi
  exit 1
fi

/usr/bin/xcrun stapler staple "$artifact"
/usr/bin/xcrun stapler validate "$artifact"
case "$artifact" in
  *.app) /usr/sbin/spctl -a -vvv -t exec "$artifact" ;;
  *.dmg) /usr/sbin/spctl -a -t open --context context:primary-signature -v "$artifact" ;;
esac
/usr/bin/printf '已公证并 staple：%s\n' "$artifact"
