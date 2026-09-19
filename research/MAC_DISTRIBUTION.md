# Public Mac distribution

The landing-page download should be a universal **Developer ID Application signed, notarized, stapled** app. An ad hoc signed development build is not that release. Talaria currently targets macOS 14 or later, on Apple silicon and Intel, and requires an existing Hermes installation or a reachable compatible gateway.

`scripts/package_macos_release.py` uses Python 3.9 or later and Xcode command-line tools to prepare an existing **Release** app without modifying its source bundle or the project version. Supply the intended marketing version and build number explicitly. The app must already contain `LICENSE` and `ThirdPartyNotices.md`.

## Prepare while distribution credentials are unavailable

```sh
python3 scripts/package_macos_release.py \
  --app /tmp/talaria-mac-release/Build/Products/Release/Talaria.app \
  --version 0.1.2 --build 3 \
  --prepare-only \
  --output-dir /tmp/talaria-0.1.2-prepared
```

This produces `Talaria-0.1.2-UNSIGNED-STAGING.app` and an explicit staging notice. It is for local inspection only; do not upload it or link it from the landing page. The output directory must not already exist.

Preparation copies the app into a private temporary directory without source filesystem metadata, removes old signatures, strips source debug symbols from every Mach-O file, preserves the universal slices, updates only the staged version fields, and checks the bundled notices. It rejects known Talaria debug-fixture code and any remaining `/Users/` path markers without printing their contents. This is a focused packaging check, not a replacement for source/privacy review or testing on supported macOS versions.

## Produce the public download

### Export through Xcode Organizer

Use Xcode's Apple Account sign-in and Organizer distribution flow to notarize an archive with the publisher's authorized Developer ID team. Wait for acceptance and export the notarized, stapled `Talaria.app`. This pathway uses the Xcode account and does not need a separate Terminal credential or `notarytool` Keychain profile.

```sh
python3 scripts/package_macos_release.py \
  --app /tmp/talaria-xcode-export/Talaria.app \
  --version 0.1.2 --build 3 \
  --package-verified \
  --output-dir build/releases/0.1.2
```

`--package-verified` checks the original exported app before archiving it directly. It does not copy the app first, change its version, strip symbols, re-sign it, submit it to Apple, or alter its ticket. The existing version and build must exactly match the requested values, and the exported bundle must be named `Talaria.app`. Signing identities and Keychain profiles are not accepted in this mode. The original app and a fresh ZIP extraction must both pass the same contents, privacy, Developer ID signature, secure timestamp, hardened runtime, stapled-ticket, and Gatekeeper checks. An unsigned, merely signed, or unstapled candidate is rejected without a public output.

### Sign and notarize with a Keychain profile

The publisher needs an installed **Developer ID Application** certificate with its private key and a preconfigured `notarytool` Keychain profile authorized for that Apple Developer team. Configure credentials outside the repository using Apple's Keychain workflow. Do not put passwords, API keys, or private keys in command examples, source files, or release assets.

```sh
python3 scripts/package_macos_release.py \
  --app /tmp/talaria-mac-release/Build/Products/Release/Talaria.app \
  --version 0.1.2 --build 3 \
  --identity 'Developer ID Application: Publisher Name (TEAMID)' \
  --notary-profile 'talaria-release' \
  --output-dir build/releases/0.1.2
```

The names above are placeholders. The script signs nested code before its parent, enables hardened runtime and secure timestamps, submits a temporary ZIP to Apple, and waits for acceptance. It staples the ticket, verifies all signatures, and requires Gatekeeper to explicitly accept a notarized Developer ID app. It then creates a clean ZIP and repeats the signature, ticket, and Gatekeeper checks on a fresh extraction. A notarization failure or lost ticket produces no public archive. The script does not offer an ad hoc fallback, overwrite an existing output directory, or upload to GitHub or any website.

Successful output:

- `Talaria-0.1.2-macOS-universal.zip`, containing only `Talaria.app`.
- `SHA256SUMS`, containing the ZIP's SHA-256 digest.

After validation, upload both assets to the corresponding GitHub release and use that release's download URL on the landing page. Verify a browser-downloaded copy on a clean Mac so quarantine and first-launch behavior are exercised. Keep the source tag, published version, release notes, and download link aligned. Do not describe the iOS simulator build as an installable iPhone release; an installable iOS release needs its own signing and distribution plan. The Mac release described here is direct distribution, not an App Store submission.

The existing Talaria targets require no custom signing entitlements. If future code adds entitlements, embedded helpers, or different architectures, update and review this packaging flow before releasing that change.

## Apple references

- [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
- [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Developer ID](https://developer.apple.com/developer-id/)
