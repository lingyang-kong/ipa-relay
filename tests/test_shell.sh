#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/package/Payload/Test.app" "$work/output"
cat >"$work/main.c" <<'C'
void stub(void) __asm__("dyld_stub_binder");
void stub(void) {}
int main(void) { return 0; }
C
cat >"$work/libSystem.tbd" <<'TBD'
--- !tapi-tbd
tbd-version: 4
targets: [ arm64-ios ]
install-name: '/usr/lib/libSystem.B.dylib'
exports:
  - targets: [ arm64-ios ]
    symbols: [ dyld_stub_binder ]
...
TBD
xcrun clang -target arm64-apple-ios13.0 -ffreestanding -c "$work/main.c" -o "$work/main.o"
xcrun ld -arch arm64 -platform_version ios 13.0 18.0 -e _main -o "$work/package/Payload/Test.app/Test" "$work/main.o" "$work/libSystem.tbd"
cat >"$work/package/Payload/Test.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>test.app</string>
<key>CFBundleShortVersionString</key><string>2.0</string>
<key>CFBundleVersion</key><string>9</string>
<key>CFBundleExecutable</key><string>Test</string>
<key>MinimumOSVersion</key><string>13.0</string>
<key>NSCameraUsageDescription</key><string>Camera</string>
</dict></plist>
PLIST
cat >"$work/main-entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>test.main</key><true/></dict></plist>
PLIST
cat >"$work/ext-entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>test.extension</key><true/></dict></plist>
PLIST
codesign --force --sign - --entitlements "$work/main-entitlements.plist" "$work/package/Payload/Test.app/Test"
mkdir -p "$work/package/Payload/Test.app/PlugIns/Share.appex"
cp "$work/package/Payload/Test.app/Test" "$work/package/Payload/Test.app/PlugIns/Share.appex/Share"
codesign --force --sign - --entitlements "$work/ext-entitlements.plist" "$work/package/Payload/Test.app/PlugIns/Share.appex/Share"
cat >"$work/package/Payload/Test.app/PlugIns/Share.appex/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Share</string>
<key>NSPhotoLibraryUsageDescription</key><string>Photos</string>
<key>NSCameraUsageDescription</key><string>Extension camera</string>
</dict></plist>
PLIST
mkdir -p "$work/package/Payload/Test.app/Resources"
for ((index = 0; index < 1500; index++)); do
	printf 'payload-%s' "$index" >"$work/package/Payload/Test.app/Resources/$index.txt"
done
(cd "$work/package" && zip -qr "$work/fixture.ipa" Payload)
cat >"$work/bin/curl" <<'STUB'
#!/bin/bash
set -eu
if [[ " $* " == *" --get "* ]]; then
	[[ " $* " == *" s=143444 "* ]]
	if [[ -n ${TEST_LOOKUP_CALLS:-} ]]; then
		for arg in "$@"; do
			if [[ $arg == id=* ]]; then
				printf '%s\n' "$arg" >>"$TEST_LOOKUP_CALLS"
				jq --arg ids "${arg#id=}" '
                  ($ids | split(",") | map(tonumber)) as $wanted |
                  .results |= map(select(.trackId as $id | $wanted | index($id)))
                ' "$TEST_STORE"
				exit
			fi
		done
	fi
	cat "$TEST_STORE"
else
	while [[ $1 != --output ]]; do shift; done
	[[ $2 == /* ]]
	if [[ ${TEST_STATUS:-200} == 200 ]]; then
		cp "$TEST_SOURCE" "$2"
	fi
	printf '%s' "${TEST_STATUS:-200}"
fi
STUB
cat >"$work/bin/ipsw" <<'STUB'
#!/bin/bash
set -eu
[[ $# == 7 && $1 == macho && $2 == decrypt-ipa && $4 == --auth && $6 == --output ]]
[[ $5 == "${IPSW_AUTHORIZATION_FILE:-$HOME/.config/ipsw/fairplay/authorization.fpauth}" ]]
read -r app_id <"$3"
mkdir "$7"
case "$app_id" in
123) cp "$TEST_IPA" "$7/repacked.ipa" ;;
456) cp "$TEST_SECOND_IPA" "$7/repacked.ipa" ;;
*) exit 1 ;;
esac
STUB
cat >"$work/bin/ipa-relay-store" <<'STUB'
#!/bin/bash
set -eu
[[ $# == 3 && $1 == download-stream ]]
[[ $2 == "$APPLE_STORE_CONTEXT_FILE" ]]
[[ $(jq -r .credential "$2") == session-fixture ]]
printf '%s\n' session >>"$TEST_CALLS"
while IFS= read -r app_id; do
	[[ ! -e $3 ]]
	printf 'download %s\n' "$app_id" >>"$TEST_CALLS"
	if [[ ${TEST_REJECT_APP:-} == "$app_id" ]]; then
		echo 'sanitized store download diagnostic' >&2
		exit 1
	fi
	printf '%s\n' "$app_id" >"$3"
	printf '%s\n' ready
done
STUB
chmod +x "$work/bin/curl" "$work/bin/ipsw" "$work/bin/ipa-relay-store"
printf '%s\n' '{"account":{"storefront":"143444-1,29"},"credential":"session-fixture"}' >"$work/context.json"
export APPLE_STORE_CONTEXT_FILE="$work/context.json"
export PATH="$work/bin:$PATH" TEST_IPA="$work/fixture.ipa" TEST_STORE="$work/store.json" TEST_SOURCE="$work/output/source.json" TEST_CALLS="$work/calls"
printf '%s\n' '123' >"$work/catalog.yml"
jq -Rsr -f "$root/scripts/app-ids.jq" "$root/.github/workflows/publish.yml" | jq -e 'type == "array" and length > 0' >/dev/null
for invalid_workflow in $'env:\n  OTHER: |\n    123' $'env:\n  APP_IDS: |\n    bad'; do
	if printf '%s\n' "$invalid_workflow" | jq -Rsr -f "$root/scripts/app-ids.jq" >/dev/null 2>&1; then
		echo 'Invalid workflow catalog accepted' >&2
		exit 1
	fi
done
for invalid_catalog in '' '0' '-1' '1.5' 'abc' $'123\n123'; do
	printf '%s' "$invalid_catalog" >"$work/invalid-catalog.yml"
	if bash "$root/scripts/catalog.sh" https://example.com "$work/invalid-catalog.yml" "$work/invalid-listings" 143444 >/dev/null 2>&1; then
		echo 'Invalid catalog accepted' >&2
		exit 1
	fi
done
printf '%s\n' '{"results":[{"kind":"software","trackId":123,"trackName":"Test","bundleId":"test.app","artistName":"Tester","description":"Test","artworkUrl512":"https://example.com/icon","version":"2.0","currentVersionReleaseDate":"2026-01-01T00:00:00Z"}]}' >"$TEST_STORE"
# Hand the checked storefront snapshot to the macOS phase without another lookup.
[[ $(bash "$root/scripts/catalog.sh" https://example.com "$work/catalog.yml" "$work/listings") == true ]]
for storefront in '143444' '143444,29' '143444-1,29'; do
	jq -n --arg storefront "$storefront" '{account: {storefront: $storefront}, country: "us"}' >"$work/old-context.json"
	[[ $(jq -ers -f "$root/scripts/storefront.jq" "$work/old-context.json") == 143444 ]]
done
APPLE_STORE_CONTEXT_FILE="$work/no-session" bash "$root/scripts/catalog.sh" https://example.com "$work/catalog.yml" "$work/ci-listings" 143444 >/dev/null
cmp "$work/listings" "$work/ci-listings"
jq -nr 'range(1; 52)' >"$work/batch-catalog.yml"
jq -n '{results: [range(51; 0; -1) | {kind: "software", trackId: ., trackName: tostring}]}' >"$work/batch-store.json"
TEST_STORE="$work/batch-store.json" TEST_LOOKUP_CALLS="$work/lookup-calls" \
	bash "$root/scripts/catalog.sh" https://example.com "$work/batch-catalog.yml" "$work/batch-listings" 143444 >/dev/null
[[ $(wc -l <"$work/lookup-calls") -eq 2 ]]
[[ $(tail -n 1 "$work/lookup-calls") == id=51 ]]
jq -s -e '[.[]._appID] == [range(1; 52)]' "$work/batch-listings" >/dev/null
jq '.results |= map(select(.trackId != 22))' "$work/batch-store.json" >"$work/missing-store.json"
if TEST_STORE="$work/missing-store.json" bash "$root/scripts/catalog.sh" https://example.com "$work/batch-catalog.yml" "$work/missing-listings" 143444 2>"$work/missing-error"; then
	echo 'Accepted a missing batched listing' >&2
	exit 1
fi
grep -q 'App Store ID 22 in storefront 143444' "$work/missing-error"
if printf '%s\n' '{"country":"gb"}' | jq -ers -f "$root/scripts/storefront.jq" >/dev/null 2>&1; then
	echo 'Accepted a session without an account storefront' >&2
	exit 1
fi
IPSW_AUTHORIZATION_FILE="$work/test authorization.fpauth" TEST_STORE="$work/no-such-listing" LISTINGS_FILE=/dev/stdin \
	bash "$root/scripts/publish.sh" https://example.com "$work/output" "$work/catalog.yml" <"$work/listings"
jq -e '
    (.apps[0] | has("_appID") | not) and
    (.apps[0] |
        .versions[0].version == "2.0" and
        .appPermissions.privacy.NSCameraUsageDescription == "Camera" and
        .appPermissions.privacy.NSPhotoLibraryUsageDescription == "Photos" and
        (.appPermissions.entitlements | index("test.main") != null and index("test.extension") != null))
' "$TEST_SOURCE" >/dev/null
digest=$(shasum -a 256 "$TEST_IPA")
asset=$(jq -r '.apps[0].versions[0].downloadURL | split("/") | last' "$TEST_SOURCE")
[[ $asset == "${digest%% *}.ipa" ]]
jq -e --argjson bytes "$(stat -f %z "$TEST_IPA")" '.apps[0].versions[0].size == $bytes' "$TEST_SOURCE" >/dev/null
cmp "$TEST_IPA" "$work/output/$asset"
published_files=("$work/output/"*)
[[ ${#published_files[@]} == 2 ]]
printf '%s\n' 'private purchase data' >"$work/package/iTunesMetadata.plist"
(cd "$work/package" && zip -q "$TEST_IPA" iTunesMetadata.plist)
LISTINGS_FILE="$work/listings" bash "$root/scripts/publish.sh" https://example.com "$work/output" "$work/catalog.yml"
asset=$(jq -r '.apps[0].versions[0].downloadURL | split("/") | last' "$TEST_SOURCE")
if unzip -Z1 "$work/output/$asset" | grep -Fx 'iTunesMetadata.plist'; then
	echo 'Private purchase metadata appeared in published IPA' >&2
	exit 1
fi
[[ $(shasum -a 256 "$work/output/$asset" | cut -d ' ' -f 1) == "${asset%.ipa}" ]]
zip -d "$TEST_IPA" iTunesMetadata.plist >/dev/null
[[ $(stat -f %Lp "$TEST_SOURCE") == 644 ]]
cp "$TEST_SOURCE" "$work/before.json"
if grep -q 'session-fixture' "$TEST_SOURCE"; then
	echo 'Store session leaked into source' >&2
	exit 1
fi
if bash "$root/scripts/catalog.sh" https://example.com "$work/catalog.yml" "$work/invalid-listings" invalid >/dev/null 2>&1; then
	echo 'Invalid storefront accepted' >&2
	exit 1
fi
printf '%s\n' '{"results":[]}' >"$work/unavailable.json"
if TEST_STORE="$work/unavailable.json" bash "$root/scripts/publish.sh" https://example.com "$work/output" "$work/catalog.yml"; then
	echo 'Unavailable app accepted' >&2
	exit 1
fi
cmp "$work/before.json" "$TEST_SOURCE"
if TEST_REJECT_APP=123 bash "$root/scripts/publish.sh" https://example.com "$work/output" "$work/catalog.yml" >"$work/failure.log" 2>&1; then
	echo 'Expected rejected Store context to stop publication' >&2
	exit 1
fi
if ! grep -q 'sanitized store download diagnostic' "$work/failure.log"; then
	echo 'Sanitized Store diagnostic missing from publisher log' >&2
	exit 1
fi
if grep -q 'session-fixture' "$work/failure.log"; then
	echo 'Store session leaked into publisher log' >&2
	exit 1
fi
cmp "$work/before.json" "$TEST_SOURCE"
[[ $(PUBLISHED_SOURCE_URL=https://example.com/source.json bash "$root/scripts/catalog.sh" https://example.com "$work/catalog.yml" "$work/listings") == false ]]
[[ $(TEST_STATUS=404 PUBLISHED_SOURCE_URL=https://example.com/source.json bash "$root/scripts/catalog.sh" https://example.com "$work/catalog.yml" "$work/listings") == true ]]
if TEST_STATUS=503 PUBLISHED_SOURCE_URL=https://example.com/source.json bash "$root/scripts/catalog.sh" https://example.com "$work/catalog.yml" "$work/listings"; then
	echo 'Expected failed source fetch' >&2
	exit 1
fi
printf 'invalid' >"$work/invalid.json"
if TEST_SOURCE="$work/invalid.json" PUBLISHED_SOURCE_URL=https://example.com/source.json bash "$root/scripts/catalog.sh" https://example.com "$work/catalog.yml" "$work/listings"; then
	echo 'Expected invalid source to fail' >&2
	exit 1
fi
: >"$TEST_CALLS"
PUBLISHED_SOURCE_URL=https://example.com/source.json bash "$root/scripts/publish.sh" https://example.com "$work/output" "$work/catalog.yml"
if [[ -s $TEST_CALLS ]]; then
	echo 'Current source unexpectedly downloaded an IPA' >&2
	exit 1
fi
jq '.results[0].version = "3.0"' "$TEST_STORE" >"$work/changed.json"
cp "$TEST_STORE" "$work/original-store.json"
mv "$work/changed.json" "$TEST_STORE"
[[ $(PUBLISHED_SOURCE_URL=https://example.com/source.json bash "$root/scripts/catalog.sh" https://example.com "$work/catalog.yml" "$work/listings") == true ]]
if bash "$root/scripts/publish.sh" https://example.com "$work/output" "$work/catalog.yml"; then
	echo 'Expected version mismatch to fail' >&2
	exit 1
fi
cmp "$work/before.json" "$TEST_SOURCE"
# The streaming extractor can read the payload even if the ZIP trailer is lost.
# Subscribers also need an intact directory to open the downloaded IPA.
mv "$work/original-store.json" "$TEST_STORE"
cp "$TEST_IPA" "$work/intact.ipa"
perl -e 'truncate $ARGV[0], (-s $ARGV[0]) - 22 or die $!' "$TEST_IPA"
if bash "$root/scripts/publish.sh" https://example.com "$work/output" "$work/catalog.yml"; then
	echo 'Expected truncated ZIP to fail' >&2
	exit 1
fi
cmp "$work/before.json" "$TEST_SOURCE"
mv "$work/intact.ipa" "$TEST_IPA"
# Change a stored ZIP member without updating its CRC.
perl -pi -e 's/payload-0/PAYLOAD-0/' "$TEST_IPA"
if bash "$root/scripts/publish.sh" https://example.com "$work/output" "$work/catalog.yml"; then
	echo 'Expected corrupted IPA to fail' >&2
	exit 1
fi
cmp "$work/before.json" "$TEST_SOURCE"
bash "$root/tests/test_store.sh"

# A single session serves both requests. Each licensed IPA is removed before
# the next request, and the first app stays staged if the second download fails.
cp "$work/output/$asset" "$TEST_IPA"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier test.second' "$work/package/Payload/Test.app/Info.plist"
(cd "$work/package" && zip -qr "$work/second.ipa" Payload)
jq -c '. + {_appID: 456, bundleIdentifier: "test.second"}' "$work/ci-listings" >"$work/second-listing"
cat "$work/ci-listings" "$work/second-listing" >"$work/two-listings"
export TEST_SECOND_IPA="$work/second.ipa"
: >"$TEST_CALLS"
if LISTINGS_FILE="$work/two-listings" TEST_REJECT_APP=456 \
	bash "$root/scripts/publish.sh" https://example.com "$work/failed-output" >"$work/failure.log" 2>&1; then
	echo 'Expected the second failed download to stop publication' >&2
	exit 1
fi
if ! grep -q 'App Store download failed for app 456' "$work/failure.log"; then
	cat "$work/failure.log" >&2
	exit 1
fi
[[ $(cat "$TEST_CALLS") == $'session\ndownload 123\ndownload 456' ]]
[[ -z $(ls -A "$work/failed-output") ]]

: >"$TEST_CALLS"
LISTINGS_FILE="$work/two-listings" bash "$root/scripts/publish.sh" https://example.com "$work/two-output"
[[ $(cat "$TEST_CALLS") == $'session\ndownload 123\ndownload 456' ]]
jq -e '[.apps[].bundleIdentifier] == ["test.app", "test.second"]' "$work/two-output/source.json" >/dev/null
echo 'Shell publisher fixture passed'
