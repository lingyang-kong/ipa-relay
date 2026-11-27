# Inspect the decrypted, repacked IPA.
inspect_ipa() (
	set -euo pipefail
	shopt -s nullglob
	ipa=$1
	work=$2
	exec 3<"$ipa"
	mkdir "$work/unpacked"
	mkfifo "$work/hash-input"
	shasum -a 256 <"$work/hash-input" >"$work/hash" &
	hash_pid=$!
	# bsdtar may stop at the ZIP directory. Drain the stream to hash every byte.
	if ! tee "$work/hash-input" <&3 | (
		bsdtar -xkf - -C "$work/unpacked" || exit 1
		cat >/dev/null
	); then
		wait "$hash_pid" || true
		echo 'Cannot extract IPA' >&2
		exit 1
	fi
	wait "$hash_pid"
	# Streaming extraction reads local headers. Check the ZIP directory on the
	# same descriptor without inflating members again.
	zipinfo -1 /dev/fd/3 | awk '
        seen[$0]++ {
            print "Duplicate ZIP entry: " $0 > "/dev/stderr"
            exit 1
        }
    '
	exec 3<&-
	if [[ -L $work/unpacked/Payload ]]; then
		echo 'Invalid Payload directory' >&2
		exit 1
	fi
	apps=("$work/unpacked/Payload/"*.app)
	if ((${#apps[@]} != 1)); then
		echo 'Expected one app in Payload' >&2
		exit 1
	fi
	app=${apps[0]}
	if [[ -L $app/PlugIns ]]; then
		echo 'Invalid PlugIns directory' >&2
		exit 1
	fi
	: >"$work/components"
	: >"$work/entitlements"
	for component in "$app" "$app"/PlugIns/*.appex; do
		plist="$component/Info.plist"
		if [[ ! -d $component || -L $component || ! -f $plist || -L $plist ]]; then
			echo "Invalid bundle or Info.plist in $component" >&2
			exit 1
		fi
		plutil -convert json -o "$work/component.json" "$plist"
		executable=$(jq -er '.CFBundleExecutable | strings | select(length > 0)' "$work/component.json")
		case "$executable" in
		. | .. | */*)
			echo 'Invalid executable name' >&2
			exit 1
			;;
		esac
		binary="$component/$executable"
		if [[ ! -f $binary || -L $binary ]]; then
			echo "Invalid executable in $component" >&2
			exit 1
		fi

		if [[ $component == "$app" ]]; then
			otool -arch all -hvl "$binary" | awk '
                /^MH_/ {
                    if ($2 == "ARM64") arm64 = 1
                    if ($2 !~ /^ARM(64)?$/ || $5 != "EXECUTE") bad = 1
                }
                $1 == "cryptid" && $2 != 0 { bad = 1 }
                $1 == "platform" && $2 != "IOS" && $2 != 2 { bad = 1 }
                $1 == "cmd" && $2 ~ /^LC_VERSION_MIN_/ && $2 != "LC_VERSION_MIN_IPHONEOS" { bad = 1 }
                END {
                    if (!arm64 || bad) {
                        print "Expected an unencrypted arm64 iOS executable" > "/dev/stderr"
                        exit 1
                    }
                }
            '
		fi
		cat "$work/component.json" >>"$work/components"
		printf '\n' >>"$work/components"
		if codesign -d --entitlements - --xml "$binary" >"$work/signature" 2>"$work/signature.log"; then
			if [[ -s $work/signature ]]; then
				plutil -convert json -o - "$work/signature" >>"$work/entitlements"
				printf '\n' >>"$work/entitlements"
			fi
		elif ! grep -q 'code object is not signed at all' "$work/signature.log"; then
			cat "$work/signature.log" >&2
			exit 1
		fi
	done

	jq -es --argjson size "$(stat -f %z "$ipa")" --slurpfile entitlements "$work/entitlements" '
            . as $components | .[0] |
            if ([.CFBundleIdentifier, .CFBundleShortVersionString, .CFBundleVersion] |
                all(type == "string" and length > 0)) | not then
                error("Missing app metadata")
            elif (.CFBundleSupportedPlatforms // ["iPhoneOS"] | index("iPhoneOS")) == null then
                error("App does not support iPhoneOS")
            else . end |
            {
                bundleIdentifier: .CFBundleIdentifier,
                version: .CFBundleShortVersionString,
                buildVersion: .CFBundleVersion,
                size: $size,
                appPermissions: {
                    privacy: (reduce ($components | reverse[] | to_entries[] | select(
                        (.key | endswith("UsageDescription")) and (.value | type == "string")
                    )) as {$key, $value} ({};
                        if $value == "" then .[$key] //= "No usage description provided in Info.plist."
                        else .[$key] = $value end
                    )),
                    entitlements: ([$entitlements[] | keys[]] | unique)
                }
            }
            + (if .MinimumOSVersion then {minOSVersion: .MinimumOSVersion} else {} end)' "$work/components"
)
