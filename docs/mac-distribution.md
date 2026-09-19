# Mac distribution

The public download is a universal **Developer ID Application signed, notarized
and stapled** app for macOS 14 or later, on Apple silicon and Intel. It requires
an existing Hermes installation or a reachable compatible gateway. This guide
covers direct Mac distribution; iOS and App Store distribution are separate work.

Run commands from the repository root. The
[packaging script](../scripts/package_macos_release.py) requires Python 3.9 or
later and Xcode command-line tools. Start with an existing universal **Release**
app containing [LICENSE](../LICENSE) and
[ThirdPartyNotices.md](../ThirdPartyNotices.md). See
[contributor setup](../CONTRIBUTING.md) for building the app.

The examples use version `0.1.2`, build `3`. Substitute the intended release
values and app paths. Each output directory must be new. Packaging does not
change the source bundle or project version, overwrite an existing release, or
upload anything.

## Package an Xcode export

Use Xcode's Apple Account sign-in and Organizer distribution flow with the
publisher's authorized Developer ID team. Wait for notarization acceptance and
export the stapled `Talaria.app`. This route does not require a separate Terminal
credential or `notarytool` Keychain profile.

```sh
python3 scripts/package_macos_release.py \
  --app /tmp/talaria-xcode-export/Talaria.app \
  --version 0.1.2 --build 3 \
  --package-verified \
  --output-dir build/releases/0.1.2
```

`--package-verified` validates and archives the original app without modifying
its version, stripping symbols, signing it again or submitting it to Apple. Its
existing version/build must match the arguments, and the bundle must be named
`Talaria.app`. Do not pass signing identities or Keychain profiles in this mode.

The original app and a fresh ZIP extraction must pass contents and private-path
checks, Developer ID signature verification, secure timestamp and hardened-runtime
checks, stapled-ticket validation and Gatekeeper assessment. An unsigned, merely
signed or unstapled candidate produces no public archive.

## Sign and notarize from the command line

Install the publisher's **Developer ID Application** certificate with its private
key and configure a `notarytool` Keychain profile for that Apple Developer team.
Keep credentials outside the repository using Apple's Keychain workflow.

```sh
python3 scripts/package_macos_release.py \
  --app /tmp/talaria-mac-release/Build/Products/Release/Talaria.app \
  --version 0.1.2 --build 3 \
  --identity 'Developer ID Application: Publisher Name (TEAMID)' \
  --notary-profile 'talaria-release' \
  --output-dir build/releases/0.1.2
```

Identity/profile names above are placeholders. The script copies the app into
private staging without source filesystem metadata, removes old signatures,
strips debug symbols while preserving universal slices, sets staged version
fields and checks the bundled notices. It rejects known debug-fixture code and
remaining home-directory path markers without printing their contents.

It signs nested code before its parent, enables hardened runtime and secure
timestamps, submits a temporary ZIP to Apple and waits for acceptance. It then
staples the ticket, checks Gatekeeper acceptance, and verifies the final ZIP after
fresh extraction. Failed notarization or a missing ticket produces no public
archive; there is no ad hoc signing fallback.

## Prepare without distribution credentials

```sh
python3 scripts/package_macos_release.py \
  --app /tmp/talaria-mac-release/Build/Products/Release/Talaria.app \
  --version 0.1.2 --build 3 \
  --prepare-only \
  --output-dir /tmp/talaria-0.1.2-prepared
```

This performs staging checks and produces
`Talaria-0.1.2-UNSIGNED-STAGING.app` plus a staging notice. It is for local
inspection only and must not be published as a download. Run the signing flow
again with the original Release app when credentials are available.

## Publish and verify

Successful public packaging produces:

- `Talaria-0.1.2-macOS-universal.zip`, containing only `Talaria.app`.
- `SHA256SUMS`, containing the ZIP's SHA-256 digest.

Upload both files to the matching [GitHub release](https://github.com/howhowdg/talaria/releases).
Keep the source tag, project version, release notes and website download link
aligned. Download the published archive through a browser and verify it on a
clean Mac so quarantine and first-launch behaviour are exercised. Packaging
checks complement source review and testing on supported macOS versions.

Never include passwords, API keys, private keys or notarization credentials in
source, command examples or release assets. The current targets need no custom
signing entitlements; review this flow before adding entitlements, embedded
helpers or different architectures. A simulator build is not an installable
iPhone release.

## Apple references

- [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
- [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Developer ID](https://developer.apple.com/developer-id/)
