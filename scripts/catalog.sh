#!/bin/bash
set -euo pipefail
base=${1:?base URL required}
catalog=${2:?catalog required}
listings=${3:?listings path required}
storefront_id=${4:-}
if [[ -z $storefront_id ]]; then
	storefront_id=$(jq -ers -f "$(dirname "$0")/storefront.jq" "${APPLE_STORE_CONTEXT_FILE:?Supply the storefront ID or APPLE_STORE_CONTEXT_FILE}")
elif [[ ! $storefront_id =~ ^[1-9][0-9]*$ ]]; then
	echo 'Expected a numeric App Store storefront ID.' >&2
	exit 1
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
batches="$work/batches"
live="$work/live"
build=true
: >"$listings"

jq -Rsr -f "$(dirname "$0")/app-ids.jq" "$catalog" |
  jq -r '50 as $batch_size | range(0; length; $batch_size) as $start | .[$start:$start + $batch_size] | join(",")' >"$batches"

# Look up apps in the same storefront used for downloads.
while IFS= read -r batch; do
	curl --fail --silent --show-error --max-time 90 --get 'https://itunes.apple.com/lookup' \
		--data-urlencode "id=$batch" --data-urlencode "s=$storefront_id" |
		jq -ce --argjson ids "[$batch]" --arg storefront "$storefront_id" '
        .results as $results | $ids[] as $id |
        (first($results[] | select(.kind == "software" and .trackId == $id)) //
            error("No software listing for App Store ID \($id) in storefront \($storefront)")) |
        {
            _appID: $id,
            name: .trackName,
            bundleIdentifier: .bundleId,
            developerName: .artistName,
            localizedDescription: .description,
            iconURL: .artworkUrl512,
            versions: [{version, date: .currentVersionReleaseDate} +
                (if (.releaseNotes // "") == "" then {} else {localizedDescription: .releaseNotes} end)]
        }
    ' >>"$listings"
done <"$batches"

# Omit PUBLISHED_SOURCE_URL to rebuild without comparing the published source.
if [[ -n ${PUBLISHED_SOURCE_URL:-} ]]; then
	status=$(curl --silent --show-error --location --max-time 30 --output "$live" --write-out '%{http_code}' "$PUBLISHED_SOURCE_URL")
	case "$status" in
	404) ;; # Build when the source is missing.
	200)
		build=$(jq --exit-status --raw-output --slurpfile wanted "$listings" --arg url "$base/source.json" '
                if (.apps | type) != "array" then error("Invalid published source") else
                    (.apps | map(
                        del(.appPermissions, .version, .versionDate, .downloadURL, .size) |
                        .versions |= map(del(.buildVersion, .downloadURL, .minOSVersion, .size))
                    )) as $published |
                    ((.sourceURL != $url or $published != ($wanted | map(del(._appID)))) | tostring)
                end' "$live")
		;;
	*)
		echo "Published source returned HTTP $status" >&2
		exit 1
		;;
	esac
fi

printf '%s\n' "$build"
