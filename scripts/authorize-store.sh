#!/bin/bash
set -euo pipefail

renew=false
if [[ ${1:-} == --renew ]]; then
	renew=true
	shift
fi
if (($# > 1)); then
	echo 'Usage: authorize-store.sh [--renew] [OUTPUT_FILE]' >&2
	exit 2
fi
output=${1:-"$HOME/.config/ipa-relay/store-context.json"}
pending="$output.pending"
if [[ -d $output || -d $pending ]]; then
	echo 'Choose a file path for the saved Store context.' >&2
	exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd -P)
tools_dir="$script_dir/../.tools"
app_id=$(jq -Rsr -f "$script_dir/app-ids.jq" "$script_dir/../.github/workflows/publish.yml" | jq -er '.[0]')

umask 077
mkdir -p "$(dirname "$output")"
work=$(mktemp -d "$(dirname "$output")/.session.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
if ! shlock -f "$output.lock" -p "$$"; then
	echo 'Another authorization is using this output, or its lock file could not be created.' >&2
	exit 1
fi
trap 'rm -rf "$work"; rm -f "$output.lock"' EXIT
bash "$script_dir/build-store.sh" "$tools_dir"
if [[ $renew == true || ! -f $pending ]]; then
	if [[ ! -t 0 ]]; then
		echo 'Run this command in an interactive terminal for sign-in.' >&2
		exit 2
	fi
	"$tools_dir/ipa-relay-store" login "$work/context.json"
	# Keep the pending session so a failed check can be retried.
	mv -f "$work/context.json" "$pending"
else
	echo 'Retrying the saved pending session.' >&2
fi

echo "Checking download authorization for App Store ID $app_id…" >&2
if ! "$tools_dir/ipa-relay-store" check "$pending" "$app_id"; then
	echo 'The pending session was kept privately. Rerun to recheck it, or use --renew to sign in again.' >&2
	exit 1
fi
mv -f "$pending" "$output"
echo "Saved verified download context to $output"
