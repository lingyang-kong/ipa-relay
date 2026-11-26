#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cp "$root/scripts/store.sh" "$work/bin/ipa-relay-store"
export TEST_WORK="$work" PATH="$work/bin:$PATH"
cat >"$work/bin/ipa-relay-store-sdk" <<'STUB'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$1" >>"$TEST_WORK/calls"
case "$1" in
login)
	printf '%s\n' '{"account":{"storefront":"143462-1,29"},"cookies":null,"generation":"login"}' >"$2/context.json"
	;;
download-stream)
	[[ $(stat -f %Lp "$2/context.json") == 600 ]]
	[[ $(stat -f %Lp "$2/cookies.json") == 600 ]]
	read -r app_id
	[[ $app_id == 456 ]]
	if read -r app_id; then exit 1; fi
	printf '%s\n' 'staged context' >"$2/context.json"
	printf '%s\n' 'licensed fixture' >"$3"
	printf '%s\n' ready
	;;
check | download)
	[[ $(stat -f %Lp "$2/context.json") == 600 ]]
	[[ $(stat -f %Lp "$2/cookies.json") == 600 ]]
	jq -e 'has("cookies")' "$2/context.json" >/dev/null
	jq -e 'type == "array" or type == "null"' "$2/cookies.json" >/dev/null
	[[ $3 == 123 ]]
	jq '.generation = "rotated" | .cookies = [{"value":"rotated"}]' "$2/context.json" >"$2/next"
	mv "$2/next" "$2/context.json"
	if [[ $1 == download ]]; then printf 'partial' >"$4"; fi
	if [[ -n ${TEST_REPLACE_WITH_DIR:-} ]]; then
		mv "$TEST_REPLACE_WITH_DIR" "$TEST_REPLACE_WITH_DIR.before"
		mkdir "$TEST_REPLACE_WITH_DIR"
	fi
	if [[ ${TEST_FAIL:-0} == 1 ]]; then exit 1; fi
	;;
esac
STUB
chmod +x "$work/bin/ipa-relay-store-sdk"
store="$work/bin/ipa-relay-store"
context="$work/context.json"
reject() {
	if "$@" >"$work/error" 2>&1; then
		printf 'Unexpected success: %s\n' "$*" >&2
		exit 1
	fi
}
bash "$store" login "$context"
jq -e '(has("country") | not) and .generation == "login" and .cookies == null' "$context" >/dev/null
[[ $(stat -f %Lp "$context") == 600 ]]
cp "$context" "$work/original"
reject bash "$store" login "$context"
cmp "$context" "$work/original"
# Legacy callers may still pass an unused app ID.
bash "$store" login "$work/legacy" 123
for id in 0 -1 abc 9223372036854775808; do
	: >"$work/calls"
	reject bash "$store" check "$context" "$id"
	[[ ! -s $work/calls ]]
done
for invalid in 'del(.cookies)' '.cookies = 1' '.cookies = {}'; do
	jq "$invalid" "$work/original" >"$work/invalid.json"
	cp "$work/invalid.json" "$work/invalid-before"
	: >"$work/calls"
	reject bash "$store" check "$work/invalid.json" 123
	[[ ! -s $work/calls ]]
	cmp "$work/invalid-before" "$work/invalid.json"
done
chmod 644 "$context"
export TEST_FAIL=1
reject bash "$store" check "$context" 123
cmp "$context" "$work/original"
reject bash "$store" download "$context" 123 "$work/failed.ipa"
cmp "$context" "$work/original"
[[ ! -e $work/failed.ipa ]]
unset TEST_FAIL
: >"$work/calls"
bash "$store" check "$context" 123
jq -e '(has("country") | not) and .generation == "rotated" and .cookies == [{"value":"rotated"}]' "$context" >/dev/null
[[ $(stat -f %Lp "$context") == 600 ]]
[[ $(cat "$work/calls") == check ]]
printf 'existing' >"$work/existing.ipa"
cp "$context" "$work/before-download"
reject bash "$store" download "$context" 123 "$work/existing.ipa"
cmp "$context" "$work/before-download"
[[ $(cat "$work/existing.ipa") == existing ]]
bash "$store" download "$context" 123 "$work/new.ipa"
[[ $(cat "$work/new.ipa") == partial ]]
[[ $(stat -f %Lp "$work/new.ipa") == 600 ]]
jq -e '.generation == "rotated" and .cookies == [{"value":"rotated"}]' "$context" >/dev/null
[[ $(stat -f %Lp "$context") == 600 ]]
[[ $(bash "$store" download-stream "$context" "$work/stream.ipa" <<<456) == ready ]]
cmp "$context" "$work/before-download"
[[ $(stat -f %Lp "$work/stream.ipa") == 600 ]]
[[ $(cat "$work/stream.ipa") == 'licensed fixture' ]]
cp "$context" "$work/changed"
TEST_REPLACE_WITH_DIR="$work/changed" reject bash "$store" download "$work/changed" 123 "$work/rejected.ipa"
[[ -d $work/changed && -z $(ls -A "$work/changed") && ! -e $work/rejected.ipa ]]
if compgen -G "$work/.store.*" >/dev/null || compgen -G "$work/.licensed.*" >/dev/null; then
	echo 'Temporary store files were not cleaned up' >&2
	exit 1
fi
echo 'Shell store fixture passed'
