# Contributing to Talaria

Talaria shares its protocol, transport, state and SwiftUI packages between Mac and iPhone. Platform entry points live in `Apps/`. Start with the [architecture](docs/architecture.md) and [current capabilities and limitations](docs/status.md).

## Development requirements

- A Mac with Xcode 27 / Swift 6.4 and iOS simulator support. The tested Xcode installation requires macOS 26.6 or later; this is separate from the app's macOS 14 / iOS 17 deployment targets.
- Full Xcode selected through `xcode-select -p`, rather than Command Line Tools alone.
- Python 3 for contract validation and gateway scripts.
- XcodeGen 2.44.1 or later only when changing targets or project settings. The checked-in Xcode project is sufficient for ordinary development.

There are no external Swift package dependencies. Hermes runs separately; ordinary Swift tests and contract checks do not require it or any model-provider credentials.

Open `Talaria.xcodeproj` and choose `TalariaMac` or `TalariaIOS`. Select an installed simulator for iOS. To run on a physical device, configure your development team and a unique bundle identifier locally; keep personal signing settings and provisioning files out of commits.

## Build and test

Run from the repository root:

```sh
python3 scripts/generate-contracts.py --check
swift test --scratch-path /tmp/talaria-swift-build
python3 -m unittest discover -s scripts/tests

xcodebuild -project Talaria.xcodeproj -scheme TalariaMac \
  -configuration Debug -derivedDataPath /tmp/talaria-native-build \
  CODE_SIGN_IDENTITY=- build

xcodebuild -project Talaria.xcodeproj -scheme TalariaIOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/talaria-ios-build CODE_SIGNING_ALLOWED=NO build
```

The Python suite skips optional Hermes ASGI integration checks when their dependencies are unavailable. The Mac build uses ad hoc signing for local development; public releases follow the [Mac distribution guide](docs/mac-distribution.md). Temporary build directories avoid signing issues caused by metadata from some synced folders.

Check both app builds when changing shared UI. For visual changes, include a screenshot and check narrow layouts, larger text, light/dark appearance and the supported accessibility fallbacks.

## Project and protocol changes

`project.yml` is the source of truth for targets and build settings. After changing it, run `xcodegen generate` and include the regenerated `Talaria.xcodeproj`. Preserve the explicit `.icon` resource entries used for Icon Composer assets.

Keep network and gateway state outside SwiftUI views. Preserve connection, profile and session ownership across asynchronous operations, and never automatically resend a prompt whose delivery is uncertain. Retain macOS 14 / iOS 17 fallback paths and semantic accessibility labels.

The [gateway contract](Contracts/README.md) is pinned in `Contracts/pin.json`. To update it, select a reviewed upstream commit, copy its unmodified schema, update the pin and SHA-256 digest, then run:

```sh
python3 scripts/generate-contracts.py
python3 scripts/generate-contracts.py --check
```

Review the resulting schema and generated-code diff together. Do not hand-edit `GatewayContract.generated.swift` or silently change the upstream baseline. Preserve the Hermes license notice when distributing the schema or generated code. The optional Telegram extension is described in [Telegram topic integration](docs/telegram-topics.md).

## Real gateway integration

The optional smoke harness requires the exact pinned Hermes checkout and a Python environment with its dependencies. Follow [the fixture setup](scripts/fixtures/README.md), then build and pass the Swift executable explicitly:

```sh
swift build --scratch-path /tmp/talaria-swift-build --product hermes-smoke
TALARIA_SMOKE_BIN="$(swift build --scratch-path /tmp/talaria-swift-build --show-bin-path)/hermes-smoke"
python3 scripts/smoke-real-gateway.py \
  --repo upstream/hermes-agent \
  --python upstream/hermes-agent/.venv/bin/python \
  --smoke "$TALARIA_SMOKE_BIN" \
  --native-runtime --extended --timeout 180
```

The harness uses synthetic inference and disposable settings. A normal app connection uses the host's configured provider, so sending a prompt there can incur provider charges.

## Pull requests and reports

Keep changes focused. Explain the resulting behaviour, how it was tested, and any compatibility limits. For bugs, include OS and Xcode versions, reproduction steps and redacted diagnostics. Report vulnerabilities privately using [SECURITY.md](SECURITY.md).

Use synthetic conversations, endpoints and files in tests and screenshots. Keep gateway tokens, provider keys, private conversation history, signing material and Hermes runtime state out of the repository.

Contributions use the project's [MIT license](LICENSE). Preserve [ThirdPartyNotices.md](ThirdPartyNotices.md) for the pinned Hermes contract and generated code.
