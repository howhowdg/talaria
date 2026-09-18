# Contributing to Talaria

Talaria has two native applications in one repository: Mac and iPhone/iPad. Shared Swift packages hold the protocol, transport, state and SwiftUI views; platform entry points stay in `Apps/`. Start with [the implementation status](IMPLEMENTATION_STATUS.md) and [the feature roadmap](HERMES_NATIVE_PLAN.md).

## Build locally

Use a Mac with Xcode 27 / Swift 6.4 and its iOS simulator support installed. The checked-in Xcode project is sufficient for normal development; there are no external Swift package dependencies. Python 3 is needed only for contract verification and integration scripts. The gateway itself runs separately on a Hermes host.

The runtime deployment targets are macOS 14 and iOS 17; they are separate from Xcode's host requirements. The tested Xcode 27 installation requires macOS 26.6 or later. Confirm `xcode-select -p` points into full Xcode, rather than only Command Line Tools. Select the intended Xcode installation in Xcode Settings → Locations if needed.

Open `Talaria.xcodeproj` and choose `TalariaMac` or `TalariaIOS`. For iOS development, select an installed simulator. To run on a physical device, choose your own development team and unique bundle identifier locally. Do not commit personal signing settings or provisioning files.

From the repository root:

```sh
python3 scripts/generate-contracts.py --check
swift test --scratch-path /tmp/talaria-swift-build
swift build --scratch-path /tmp/talaria-swift-build --product hermes-smoke

xcodebuild -project Talaria.xcodeproj -scheme TalariaMac \
  -configuration Debug -derivedDataPath /tmp/talaria-native-build \
  CODE_SIGN_IDENTITY=- build

xcodebuild -project Talaria.xcodeproj -scheme TalariaIOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/talaria-ios-build CODE_SIGNING_ALLOWED=NO build
```

The Mac command creates a local ad hoc development build. It does not create a notarized release. `/tmp` build paths also avoid code-signing problems from metadata added by some synced folders.

## Build the universal Mac preview

```sh
xcodebuild -project Talaria.xcodeproj -scheme TalariaMac \
  -configuration Release -derivedDataPath /tmp/talaria-mac-release \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- build
```

Archive `/tmp/talaria-mac-release/Build/Products/Release/Talaria.app` with `ditto -c -k --keepParent` and publish its SHA-256 checksum with the download. This produces the ad hoc signed preview, not a notarized distribution.

## Change the project

`project.yml` is the source of truth for targets and build settings. If those change, use XcodeGen 2.44.1 or later and run `xcodegen generate`; include the regenerated `Talaria.xcodeproj` with the YAML change. Preserve the explicit `.icon` resource entries, which also work with XcodeGen versions predating automatic Icon Composer support.

Keep network and gateway state out of SwiftUI views. Preserve connection/profile/session ownership when adding asynchronous operations, and never automatically resend a prompt whose delivery is uncertain. UI changes should retain the older macOS 14 / iOS 17 fallback paths and semantic accessibility labels. Keep Liquid Glass on controls; see [the design notes](Design/Brand/README.md).

The protocol catalog is generated. Change the reviewed schema and provenance in `Contracts/` first, then run `python3 scripts/generate-contracts.py`. Do not hand-edit `GatewayContract.generated.swift` or silently update the upstream pin.

## Test a real gateway

Ordinary Swift tests and contract checks do not need Hermes installed or any provider credentials. The optional integration harness requires the exact pinned Hermes checkout and a Python environment containing its dependencies. Follow [the fixture setup](scripts/fixtures/README.md), and pass the Swift executable explicitly when using the scratch path above:

```sh
TALARIA_SMOKE_BIN="$(swift build --scratch-path /tmp/talaria-swift-build --show-bin-path)/hermes-smoke"
python3 scripts/smoke-real-gateway.py \
  --repo upstream/hermes-agent \
  --python upstream/hermes-agent/.venv/bin/python \
  --smoke "$TALARIA_SMOKE_BIN" \
  --native-runtime --extended --timeout 180
```

The harness uses synthetic inference and disposable settings. A normal app connection uses the connected Hermes installation and its configured model provider, so sending a prompt there can incur provider charges.

## Contributions and reports

Keep changes focused and describe the user-visible behavior, relevant tests, and any compatibility limits. Check both platform builds when changing shared UI. Include a screenshot for visual changes and test narrow iPhone layouts, larger text, and light/dark appearances when relevant.

Use synthetic conversations, endpoints and files in tests and screenshots. Never include gateway tokens, provider keys, Keychain exports, private conversation history, signing identities, or your Hermes home directory. Report ordinary bugs with OS/Xcode versions, reproduction steps and redacted diagnostics. Follow [SECURITY.md](SECURITY.md) for private vulnerability reports.

Contributions are accepted under the project's [MIT license](LICENSE). Preserve [third-party notices](ThirdPartyNotices.md) for the pinned Hermes contract and generated code.
