# IPA Relay

IPA Relay publishes verified IPAs and an AltStore Classic source for LiveContainer from a configurable catalog of licensed iOS apps. It downloads each app with `ipatool` and decrypts it with UnfairPlay.

## Prepare the credentials

Prepare the App Store session and FairPlay model on an Apple Silicon Mac. Install Apple's Command Line Tools and run `brew install jq gh` if you need those tools. Download the latest UnfairPlay macOS arm64 release, verify its checksum using `SHA256SUMS`, and put `unfairplay` on your PATH. Use the same Apple account for both credentials. It must own every app listed in the publish workflow in its storefront. [UnfairPlay releases](https://github.com/DrWhax/unfairplay/releases/latest)

Run the Store helper from the repository checkout in Terminal. The helper builds the downloader with Go, using `pixi` or Homebrew if needed. Enter your Apple account, password, and any verification code.

```sh
bash scripts/authorize-store.sh
```

The helper reopens the session and reads the first catalog app's `Info.plist` to verify download access. On success, it saves `~/.config/ipa-relay/store-context.json` with owner-only permissions. Rerun the command to retry a failed check. Use `--renew` for a fresh sign-in. [Upstream metadata check](https://github.com/majd/ipatool/blob/main/pkg/appstore/appstore_get_version_metadata.go)

Sign in to the Mac App Store with the same account. If this Mac has no FairPlay enrollment yet, install and open an iPhone or iPad app from the Mac App Store. Obtain a personalized IPA for an app owned by that account, then export the Mac's enrollment and recover a model using the IPA. Run these commands in a private directory and replace `App.ipa` with its path.

```sh
umask 077
mkdir -p "$HOME/.config/ipa-relay/models"
sudo unfairplay export-enrollment --output "$HOME/.config/ipa-relay/enrollment.snapshot"
unfairplay setup --enrollment "$HOME/.config/ipa-relay/enrollment.snapshot" --ipa App.ipa --model-dir "$HOME/.config/ipa-relay/models"
```

Copy the model file reported by setup to `~/.config/ipa-relay/fairplay-enrollment.bin` with mode 600. Remove the enrollment snapshot after setup. Keep the model and Store context private. [UnfairPlay setup](https://github.com/DrWhax/unfairplay#export-enrollment-now-choose-an-ipa-later)

## Publish with GitHub Actions

The workflow runs entirely on GitHub-hosted runners. The `macos-latest` job uses the runner's Go installation or installs Go with Homebrew. It builds the custom session adapter against the latest `ipatool` release, installs the latest UnfairPlay release binary after checking its checksum, and uploads the verified IPAs and `source.json` for deployment.

In **Settings → Pages**, choose **GitHub Actions** as the build and deployment source. Sign in to `gh` and set both repository secrets from the checkout.

```sh
gzip -c <"$HOME/.config/ipa-relay/store-context.json" | base64 | gh secret set APPLE_STORE_CONTEXT_B64
base64 <"$HOME/.config/ipa-relay/fairplay-enrollment.bin" | gh secret set UNFAIRPLAY_MODEL_B64
```

If you already have a working `APPLE_STORE_CONTEXT_B64` secret, add `UNFAIRPLAY_MODEL_B64` and run **Publish source**. After a successful run, remove the old `IPSW_AUTHORIZATION_B64` secret from the repository.

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

Set `PUBLISHED_SOURCE_URL` to the deployed `source.json` URL to skip downloads when listings match. Set `UNFAIRPLAY_MODEL_FILE` if the model is stored at a custom path.

For cron or launchd, use absolute paths and run with access to both credentials. For a remote host, upload the IPAs before replacing `source.json`. Local output directories retain earlier IPAs.

## Catalog and validation

Add apps under `APP_IDS` in `.github/workflows/publish.yml`. Use one positive integer App Store ID per line, with no duplicates. Each app must be available in the storefront from the saved session.

The publisher removes Store license files and purchase metadata and checks ZIP integrity. UnfairPlay checks available pre-encryption page hashes. The publisher verifies that the main executable is unencrypted and supports arm64 iOS, and that the bundle ID and version match the listing. The source records the build number, package size, minimum OS when present, and entitlements and privacy descriptions from the app and its extensions. IPAs are named by SHA-256 hash. Launch the app on a device to confirm LiveContainer compatibility. [AltStore source format](https://faq.altstore.io/developers/make-a-source)

## Tests

- `bash tests/test_shell.sh` runs the publisher and Store wrapper fixtures on macOS.
- `bash scripts/build-store.sh --with-tests .tools` tests the Go adapter against the latest `ipatool` release and builds the downloader.
