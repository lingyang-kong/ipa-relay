#!/bin/bash
set -euo pipefail

with_tests=false
if [[ ${1:-} == --with-tests ]]; then
	with_tests=true
	shift
fi
if (($# != 1)); then
	echo 'Usage: build-store.sh [--with-tests] BIN_DIR' >&2
	exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd -P)
mkdir -p "$1"
bin_dir=$(cd "$1" && pwd -P)
sdk="$bin_dir/ipa-relay-store-sdk"
stamp="$bin_dir/ipa-relay-store.sha256"
sources=$(cd "$script_dir" && shasum -a 256 build-store.sh store/*.go)

if [[ $with_tests == true || ! -x $sdk || ! -f $stamp || $(<"$stamp") != "$sources" ]]; then
	work=$(mktemp -d)
	trap 'rm -rf "$work"' EXIT
	gh release download --repo majd/ipatool --archive tar.gz --output "$work/source.tar.gz"
	mkdir "$work/source"
	tar -xzf "$work/source.tar.gz" --strip-components 1 -C "$work/source"
	cp -R "$script_dir/store" "$work/source/ipa-relay-store"

	if command -v go >/dev/null; then
		go_command=(go)
	elif command -v pixi >/dev/null; then
		go_command=(pixi exec --spec go go)
	else
		brew install go
		go_command=(go)
	fi

	# Isolated Go environments may default to a compiler outside their PATH.
	export CC=${CC:-/usr/bin/clang}
	export CXX=${CXX:-/usr/bin/clang++}
	(
		cd "$work/source"
		if [[ $with_tests == true ]]; then
			"${go_command[@]}" test ./ipa-relay-store
		fi
		"${go_command[@]}" build -o "$work/ipa-relay-store-sdk" ./ipa-relay-store
	)
	install -m 755 "$work/ipa-relay-store-sdk" "$sdk"
	printf '%s\n' "$sources" >"$work/store.sha256"
	mv "$work/store.sha256" "$stamp"
fi
install -C -m 755 "$script_dir/store.sh" "$bin_dir/ipa-relay-store"
