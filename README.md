# IPA Relay

IPA Relay publishes verified IPAs and an AltStore Classic source for LiveContainer from a configurable catalog of licensed iOS apps. It downloads each app with `ipatool` and decrypts it with `ipsw`.

## Prepare the credentials

Prepare the App Store session and FairPlay authorization on an Apple Silicon Mac running macOS 26 or later. Install Apple's Command Line Tools, `jq`, `ipsw`, and `gh`. Use the same Apple account for both credentials. It must own every app listed in the publish workflow in its storefront.

Run the Store helper from the repository checkout in Terminal. The helper builds the downloader with Go, using `pixi` or Homebrew if needed. Enter your Apple account, password, and any verification code.

```sh
bash scripts/authorize-store.sh
```

The helper reopens the session and reads the first catalog app's `Info.plist` to verify download access. On success, it saves `~/.config/ipa-relay/store-context.json` with owner-only permissions. Rerun the command to retry a failed check. Use `--renew` for a fresh sign-in. [Upstream metadata check](https://github.com/majd/ipatool/blob/main/pkg/appstore/appstore_get_version_metadata.go)

Sign in to the Mac App Store with the same account, run `ipsw macho export-auth`, and approve the `sudo` prompt. The export saves `~/.config/ipsw/fairplay/authorization.fpauth` for offline decryption. Keep both credential files private. [ipsw export guide](https://blacktop.github.io/ipsw/docs/guides/offline-ipa/#export-the-authorization)

## Publish with GitHub Actions

The workflow runs entirely on GitHub-hosted runners. The `macos-latest` job builds the downloader against the latest `ipatool` release, verifies the `ipsw` archive checksum, and uploads the verified IPAs and `source.json` for deployment.

In **Settings → Pages**, choose **GitHub Actions** as the build and deployment source. Sign in to `gh` and set both repository secrets from the checkout.

```sh
gzip -c <"$HOME/.config/ipa-relay/store-context.json" | base64 | gh secret set APPLE_STORE_CONTEXT_B64
base64 <"$HOME/.config/ipsw/fairplay/authorization.fpauth" | gh secret set IPSW_AUTHORIZATION_B64
```

Run **Publish source** from the Actions tab to force a build and check that Apple accepts the session on the hosted runner. If Apple asks you to sign in again, run `bash scripts/authorize-store.sh --renew` and update `APPLE_STORE_CONTEXT_B64`. A failed build leaves the previous deployment live.

Every Monday at 00:17 UTC (08:17 Shanghai time), `ubuntu-slim` compares storefront listings for the default branch's catalog with the deployed source. A missing source or changed listings triggers the Mac build. A final `ubuntu-slim` job deploys the artifact to Pages. [GitHub runner specifications](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)

## Add the source

Add the published `source.json` URL under **Sources** in LiveContainer. AltStore Classic accepts the same URL. For Pages, append `/source.json` to the deployment URL in the `github-pages` environment. Refresh the source if a cached IPA URL returns 404 after redeployment.

## Publish from your Mac

With both credentials prepared, make sure `curl`, `bsdtar`, `zip`, and `zipinfo` are available. Build the downloader, then run the publisher with your public base URL and web root.

```sh
bash scripts/build-store.sh .tools
export PATH="$PWD/.tools:$PATH"
export APPLE_STORE_CONTEXT_FILE="$HOME/.config/ipa-relay/store-context.json"
bash scripts/publish.sh https://apps.example.org/ipa /srv/www/ipa
```

Set `PUBLISHED_SOURCE_URL` to the deployed `source.json` URL to skip downloads when listings match. Set `IPSW_AUTHORIZATION_FILE` if you exported `authorization.fpauth` to a custom path.

For cron or launchd, use absolute paths and run with access to both credentials. For a remote host, upload the IPAs before replacing `source.json`. Local output directories retain earlier IPAs.

## Catalog and validation

Add apps under `APP_IDS` in `.github/workflows/publish.yml`. Use one positive integer App Store ID per line, with no duplicates. Each app must be available in the storefront from the saved session.

The current catalog contains one entry, 乐刻运动 (`1116555378`). [App Store listing](https://apps.apple.com/app/id1116555378)

The publisher removes Store purchase metadata and checks ZIP integrity. It verifies that the main executable is unencrypted and supports arm64 iOS, and that the bundle ID and version match the listing. The source records the build number, package size, minimum OS when present, and entitlements and privacy descriptions from the app and its extensions. IPAs are named by SHA-256 hash. Launch the app on a device to confirm LiveContainer compatibility.

## Tests

- `bash tests/test_shell.sh` runs the publisher and Store wrapper fixtures on macOS.
- `bash scripts/build-store.sh --with-tests .tools` tests the Go adapter against the latest `ipatool` release and builds the downloader.

## Design references

- Release polling and Pages deployment ([bcd_ipa_source](https://github.com/gilma0/bcd_ipa_source), [apt-rustup](https://github.com/lingyang-kong/apt-rustup/blob/main/.github/workflows/publish.yml), [apt-pixi](https://github.com/lingyang-kong/apt-pixi/blob/main/.github/workflows/publish.yml))
- Catalog and source metadata ([AltGallery](https://github.com/bebound/AltGallery), [AltGen](https://github.com/bebound/AltGen), [LiveContainer source updater](https://github.com/LiveContainer/LiveContainer/blob/main/.github/update_json.py), [AltStore source format](https://faq.altstore.io/developers/make-a-source))
