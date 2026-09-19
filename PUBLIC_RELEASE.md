# Talaria source release

The intended distribution is an open-source native Mac application and iPhone/iPad companion, maintained together in one repository because they share their protocol, state and UI packages.

## Repository and license

- Repository: [howhowdg/talaria](https://github.com/howhowdg/talaria).
- License: [MIT](LICENSE) for Talaria's original code and artwork, retaining Hermes attribution in [ThirdPartyNotices.md](ThirdPartyNotices.md).
- Private vulnerability reports: [reporting instructions](SECURITY.md).

## Initial release scope

Publish the existing native client as a development preview. Keep the [implemented features and remaining work](IMPLEMENTATION_STATUS.md) visible. Mac and iOS build from the same source; the iOS client connects to a Hermes host and does not run Python on the device.

The public source includes the Swift packages, app targets, generated Xcode project, pinned contract, tests, isolated integration fixtures, original logo, native icon and documentation. The downloaded upstream checkout, local runtime state, provider credentials, signing material and build products stay outside version control.

The v0.1.2 Mac preview is a universal Apple silicon/Intel application with Developer ID signing, Apple notarization and a stapled ticket. The final ZIP is verified after extraction, including Gatekeeper acceptance, and published with its SHA-256 checksum. It requires macOS 14 or later and an existing Hermes host. The earlier v0.1.1 download remains a historical ad hoc preview.

The [repeatable Mac distribution process](research/MAC_DISTRIBUTION.md) requires signing, notarization, a stapled ticket and Gatekeeper verification before producing public output. Both the package script and Xcode Organizer workflow keep credentials outside the repository. Mac distribution is direct through GitHub Releases and the landing page, with no App Store submission. An installable iOS release needs a separate distribution plan; no iOS binary is published.

## Evidence and remaining release work

- Initial publication verification: a clean copy of the staged source passes all 84 Swift tests, contract drift verification, and both platform builds with Xcode 27. Both built apps contain the MIT license and Hermes notices.
- The clean-copy smoke client also passed the extended real Hermes integration using synthetic inference: local runtime launch/shutdown, reconnect, session-only model changes, profile isolation and document/image delivery.
- Real gateway integration and native Mac conversation flow have passed against isolated synthetic inference. iOS light/dark welcome screens were inspected in the simulator.
- Contributor build instructions and local credential/signing exclusions are included.
- Publication-content review found no actual credentials, private keys, private conversation data, personal paths or signing identities in the source/assets reviewed. Synthetic fixture credentials remain clearly labeled as test data.
- Both apps rebuild successfully after aligning the scheme product names and bundling the exact Hermes third-party notice. Contract drift and credential/signing ignore-rule checks pass.
- The optional integration fixture now documents a pinned source checkout and dedicated Python environment. The fresh Python installation recipe still needs verification; existing integration passes used an already provisioned dependency environment.
- The initial publication was source only, followed by the ad hoc v0.1.1 preview. Version 0.1.2 adds a notarized universal Mac download. Its source passes 219 Swift tests, 35 Python unit tests and contract verification; six optional Hermes ASGI tests require a provisioned upstream environment and were skipped locally. The signed archive contains no debug-fixture controls or local build-path markers; a content scan found no credentials or private gateway configuration.
- Configure CI against an available Xcode 27 runner. Do not add a passing-status badge before that workflow actually runs.

This source release does not claim full Hermes Desktop parity or completed security testing.
