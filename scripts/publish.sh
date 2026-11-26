#!/bin/bash
# Usage: bash scripts/publish.sh BASE_URL OUTPUT [CATALOG]
set -euo pipefail
shopt -s nullglob
script_dir=$(cd "$(dirname "$0")" && pwd -P)
source "$script_dir/inspect.sh"

if (($# < 2 || $# > 3)); then
	echo 'Usage: publish.sh BASE_URL OUTPUT [CATALOG]' >&2
	exit 2
fi
base=${1%/}
output=${2:?supply the static site directory}
catalog=${3:-"$script_dir/../.github/workflows/publish.yml"}
if [[ ! $base =~ ^https?://[^/?#@[:space:]]+(/[^?#[:space:]]*)?$ ]]; then
	echo 'Supply an absolute HTTP(S) base URL for the published directory' >&2
	exit 2
fi

mkdir -p "$output"
# Stage beside the output so each rename is atomic.
output=$(cd "$output" && pwd -P)
umask 077
stage=$(mktemp -d "$(dirname "$output")/.ipa-relay.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT

listings=${LISTINGS_FILE:-"$stage/listings"}
if [[ -z ${LISTINGS_FILE:-} ]]; then
	build=$(bash "$script_dir/catalog.sh" "$base" "$catalog" "$listings")
	if [[ $build == false ]]; then
		echo 'Source is current.'
		exit 0
	fi
fi

: "${APPLE_STORE_CONTEXT_FILE:?Set APPLE_STORE_CONTEXT_FILE}"
if [[ ! -f $APPLE_STORE_CONTEXT_FILE || ! -r $APPLE_STORE_CONTEXT_FILE ]]; then
	echo 'The saved App Store context is unreadable.' >&2
	exit 1
fi
process_app() {
	local listing=$1 work ipa zip_status digest asset
	work=$(mktemp -d "$stage/app.XXXXXXXX")
	ipsw macho decrypt-ipa "$licensed" --auth "${IPSW_AUTHORIZATION_FILE:-$HOME/.config/ipsw/fairplay/authorization.fpauth}" --output "$work/decrypted" </dev/null
	rm "$licensed"
	ipa="$work/decrypted/repacked.ipa"
	# zip returns 12 if there is no purchase metadata to remove.
	zip_status=0
	zip -qd "$ipa" iTunesMetadata.plist >/dev/null 2>&1 || zip_status=$?
	if ((zip_status != 0 && zip_status != 12)); then
		echo 'Could not remove Store purchase metadata from the IPA.' >&2
		exit 1
	fi
	inspect_ipa "$ipa" "$work" >"$work/package.json"

	read -r digest _ <"$work/hash"
	asset="$digest.ipa"
	jq -ce --argjson listing "$listing" --arg url "$base/$asset" '
        if .bundleIdentifier != $listing.bundleIdentifier or .version != $listing.versions[0].version
        then error("IPA does not match storefront listing") else . end |
        . as $pkg | ($listing | del(._appID)) + {appPermissions: .appPermissions} |
        .versions[0] += ($pkg | del(.appPermissions, .bundleIdentifier)) |
        .versions[0].downloadURL = $url |
        . + (.versions[0] | {version, versionDate: .date, downloadURL, size})
    ' "$work/package.json" >>"$stage/apps"
	chmod 644 "$ipa"
	mv "$ipa" "$stage/$asset"
	rm -rf "$work"
}

process_listings() {
	local listing app_id status
	while IFS= read -r listing <&4; do
		app_id=$(jq -er '._appID | numbers' <<<"$listing")
		printf '%s\n' "$app_id" >&3
		if ! IFS= read -r status || [[ $status != ready ]]; then
			echo "App Store download failed for app $app_id." >&2
			exit 1
		fi
		process_app "$listing"
	done
}

# Process and remove each licensed IPA before requesting the next one.
licensed="$stage/licensed.ipa"
requests="$stage/download-requests"
mkfifo "$requests"
{
	ipa-relay-store download-stream "$APPLE_STORE_CONTEXT_FILE" "$licensed" <"$requests" 4<&- |
		process_listings 3>"$requests"
} 4<"$listings"

jq --slurp --arg base "$base" '
    if (map(.bundleIdentifier) | unique | length) != length then error("duplicate bundles") else
    {
        name: "IPA Relay",
        identifier: (($base | sub("^https?://"; "")) + "/ipa-relay"),
        sourceURL: ($base + "/source.json"),
        apps: .,
        news: []
    } end
' "$stage/apps" >"$stage/source.json"
chmod 644 "$stage/source.json"
mv "$stage/"*.ipa "$output/"
mv "$stage/source.json" "$output/source.json"
