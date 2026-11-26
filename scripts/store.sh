#!/bin/bash
set -euo pipefail

usage() {
	echo 'Usage: ipa-relay-store login CONTEXT | check CONTEXT APP_ID | download CONTEXT APP_ID DEST | download-stream CONTEXT DEST' >&2
	exit 2
}

case "${1:-}:$#" in
login:2 | login:3 | check:3 | download:4 | download-stream:3) ;;
*) usage ;;
esac
operation=$1
context=$2
if (($# >= 3)) && [[ $operation != download-stream ]]; then
	# Older login callers can also supply an app ID.
	if [[ ! $3 =~ ^\+?0*([1-9][0-9]*)$ ]]; then
		usage
	fi
	digits=${BASH_REMATCH[1]}
	if ! printf -v app_id '%d' "$digits" 2>/dev/null || [[ $app_id != "$digits" ]]; then
		echo 'Invalid App Store ID.' >&2
		exit 2
	fi
fi
case "$operation" in
login) new_file=$context ;;
download) new_file=$4 ;;
download-stream) new_file=$3 ;;
esac
if [[ $operation != check && (-e $new_file || -L $new_file) ]]; then
	echo 'The requested output already exists.' >&2
	exit 1
fi
umask 077
sdk="$(cd "$(dirname "$0")" && pwd -P)/ipa-relay-store-sdk"
context_dir=$(dirname "$context")
staging_dir=$context_dir
if [[ $operation == download-stream ]]; then
	staging_dir=$(dirname "$new_file")
fi
work=$(mktemp -d "$staging_dir/.store.XXXXXXXX")
ipa_work=''
cleanup() {
	rm -rf "$work"
	if [[ -n $ipa_work ]]; then
		rm -rf "$ipa_work"
	fi
}
trap cleanup EXIT

if [[ $operation == login ]]; then
	"$sdk" login "$work"
	link "$work/context.json" "$context"
	echo 'Apple sign-in completed.' >&2
	exit 0
fi

# Give the SDK a private working copy and its native cookie jar.
cat "$context" >"$work/context.json"
jq -c 'if has("cookies") and (.cookies | type == "array" or type == "null")
       then .cookies else error("Invalid Store context") end' "$work/context.json" >"$work/cookies.json"
case "$operation" in
download)
	ipa_work=$(mktemp -d "$(dirname "$new_file")/.licensed.XXXXXXXX")
	"$sdk" download "$work" "$app_id" "$ipa_work/download.ipa"
	chmod 600 "$ipa_work/download.ipa"
	;;
download-stream)
	"$sdk" download-stream "$work" "$new_file"
	exit 0
	;;
check) "$sdk" check "$work" "$app_id" ;;
esac
# Target the parent so a directory at the context path causes an error.
updated="$work/updated/$(basename "$context")"
mkdir "$work/updated"
mv "$work/context.json" "$updated"
mv -f "$updated" "$context_dir/"
case "$operation" in
download) link "$ipa_work/download.ipa" "$new_file" ;;
check) echo "Licensed download verified from the app's Info.plist." >&2 ;;
esac
