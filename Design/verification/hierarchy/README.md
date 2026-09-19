# Native hierarchy verification

18 September 2026. These are native Talaria development-build captures using the explicit synthetic hierarchy fixture. They are separate from the supplied [2× design references](../../handoff/hierarchy/screens) and the older screenshots under `research/screenshots`.

**The final Swift test rerun passes all 189 tests:** 89 Core, 45 UI, 38 Transport, 9 Protocol and 8 MacServices, using `swift test --scratch-path /tmp/talaria-swift-build`. Contract drift passes for 218 RPCs, 12 server requests and 69 events. Final Mac Debug/Release builds include the dark-appearance and Settings-scope fixes; both pass. iOS simulator Debug/generic-device Release builds also pass after the approval receipt fix. The receipt interaction is verified in the Mac app.

The durable local Release archive is `build/hierarchy/Talaria-Hierarchy-Mac.zip` (gitignored); the runnable development copy is `/tmp/Talaria-Hierarchy.app`. The universal arm64/x86_64 app is locally ad hoc signed, and the `/tmp` copy passes `codesign --verify --deep --strict`. The archive excludes resource metadata; the synced workspace can reapply metadata to an unpacked app. This is not Developer ID signing or notarization. This pass has not published a new binary or GitHub release.

## Evidence

The 16 inspected iPhone files retain the simulator's native 1206×2622 pixels (402×874 points at 3×). The handoff's iPhone images are 804×1748 pixels at 2×; compare logical point sizes, not raw pixel counts. The Mac export targets the handoff's 1180×760-point window at 2×. The Discuss modal is a native 1× 440×517 JPEG because the window exporter excludes child windows. Images are not enlarged to simulate higher-resolution evidence.

| Native screen | Capture | Design reference |
| --- | --- | --- |
| Home | [Home](ios/home-3x.png) | i1 |
| Choose Home | [First use](ios/home-first-use-3x.png) | i10 |
| Home unavailable | [Unavailable](ios/home-unavailable-3x.png) | SPEC_IOS states |
| Workspaces | [List](ios/workspaces-3x.png) | i2 |
| Workspace | [Detail](ios/workspace-detail-3x.png) | i3; unsupported live delegated data omitted |
| Automations | [List](ios/automations-3x.png) | i5 |
| Automation | [Detail](ios/automation-detail-3x.png) | i6 |
| Run | [Result first](ios/run-result-3x.png) | i7 |
| Activity | [Activity](ios/activity-3x.png) | i8 |
| Discuss | [Selective context sheet](ios/discuss-3x.png) | i9 |
| Activity request origin | [Approval in its owning workspace](ios/activity-origin-3x.png) | SPEC_IOS Activity navigation; four host choices |
| Failed Run | [Failure](ios/failed-run-3x.png) | SPEC_IOS Run states |
| Run with no output | [No output](ios/no-output-3x.png) | SPEC_IOS Run states |
| Home, dark | [Dark Home](ios/home-dark-3x.png) | SPEC_IOS appearance |
| Activity, dark | [Dark Activity](ios/activity-dark-3x.png) | SPEC_IOS attention colour |
| Activity, larger text | [Accessibility text](ios/activity-accessibility-3x.png) | SPEC_IOS Dynamic Type |

| Native Mac screen | Capture | Evidence |
| --- | --- | --- |
| Choose Home | [First use](mac/mac-home-first-use-2x.png) | Explicit choice, no inferred default |
| Home | [Home](mac/mac-home-2x.png) | Native conversation surface |
| Workspaces | [Workspaces](mac/mac-workspaces-2x.png) | Explicit local organisation |
| Run | [Result first](mac/mac-run-result-2x.png) | Result before collapsed execution |
| Activity | [Activity](mac/mac-activity-2x.png) | Needs you separated from result updates |
| Activity request origin | [Approval origin](mac/mac-activity-request-2x.png) | Exact pending request and host permission options |
| Discuss | [Native modal](mac/mac-discuss-native.jpg) | Result and back-link selected; draft staging |
| Approval receipt | [Answered request](mac/mac-approval-receipt-2x.png) | Pending card removed, “You chose once” receipt and final reply |
| Home unavailable | [Cached Home](mac/mac-home-unavailable-2x.png) | Cached transcript retained; composer disabled |
| Home, dark | [Dark Home](mac/mac-home-dark-2x.png) | Final native contrast, including the model control |

Mac interactions verified the explicit Home picker, keyboard navigation to all four roots, Activity navigation to the exact approval origin with all host choices, Mark all read preserving Needs you, collapsed execution on a result-first Run, and Discuss staging selected context without submitting a prompt. Choosing the host's once option removes the pending card, shows “You chose once”, receives the synthetic final message and clears the Needs-you badge. Unavailable Home retains the cached transcript and disables its composer. All ten Mac captures were visually inspected; the final dark Home capture includes the corrected model-control contrast. No screenshot is evidence of a backend capability merely because the reference prototype draws it.

These images establish rendered layout with synthetic records. iOS installation, launch and capture use `simctl`; DeviceHub/CUA was unavailable for phone interaction, so synthetic route selection does not establish that every tap, swipe, keyboard transition or accessibility action works on a physical device. Mac interaction checks and final build/test evidence are recorded in [IMPLEMENTATION_STATUS.md](../../../IMPLEMENTATION_STATUS.md#current-hierarchy-verification). Older-OS runtimes, dedicated iPad layout, physical-device networking and background delivery remain unverified in this pass.

## What the fixture represents

Home, Workspace assignments, branches, requests, Automations and Runs are explicitly seeded synthetic records. There are no provider calls, real agent actions or user files. Production screens do not insert these examples when host data is unavailable.

The implementation uses a local, connection/profile-scoped classification store. iCloud KVS and server organisation sync are not implemented. Telegram topic bindings, delegated goal/progress/lifecycle, instruction editing, reset/compression continuity and canonical result provenance remain incomplete behind default-off flags. Existing supported host requests keep their exact options and permission limits. Discuss selects context, stages a draft and requires a separate normal Send.

No output, failure, active work, waiting input and unavailable history remain distinct. An inactive session is not automatically Completed. A known branch is not called a Delegated task. Display metadata never derives Home or Workspace membership from names, source or recency.

## Start the shared fixture

From the repository root, use an environment with FastAPI and Uvicorn WebSocket support. Leave this process running while viewing the apps:

```sh
python3 scripts/fixtures/mobile_design_gateway.py \
  --handoff /tmp/talaria-hierarchy-design-fixture.json
```

The fixture listens only on loopback and writes an expiring `0600` handoff. It refuses to overwrite an existing handoff from another run. Stop it with Ctrl-C or let its 30-minute lifetime expire; it removes its owned handoff. The credential file is private runtime state and must not be included in screenshots, source or release assets.

## Mac reproduction

Build and open **TalariaMac Debug**, then use:

1. **Window → Open Hierarchy Design Fixture**.
2. **Window → Design Reference Size (1180 × 760)**.
3. Select the screen in the native sidebar, then **Export 2× Design Snapshot…**.

The fixture-opening command expects `/tmp/talaria-hierarchy-design-fixture.json`, so the `--handoff` argument above is required. It does not discover the older default iPhone handoff path. The fixture connection has its own identity and does not persist its token to Keychain. The command is absent from Release builds.

## iPhone reproduction

Build/install **TalariaIOS Debug** on a booted iPhone simulator as described in the [main reproduction instructions](../../../IMPLEMENTATION_STATUS.md#repeat-the-iphone-design-preview). Set the simulator UDID, then choose a root tab or a detail destination:

```sh
TALARIA_PREVIEW_DEVICE='paste-the-booted-iPhone-UDID'
python3 scripts/preview_ios_design.py --device "$TALARIA_PREVIEW_DEVICE" \
  --handoff /tmp/talaria-hierarchy-design-fixture.json --tab Home
python3 scripts/preview_ios_design.py --device "$TALARIA_PREVIEW_DEVICE" \
  --handoff /tmp/talaria-hierarchy-design-fixture.json --tab Workspaces
python3 scripts/preview_ios_design.py --device "$TALARIA_PREVIEW_DEVICE" \
  --handoff /tmp/talaria-hierarchy-design-fixture.json \
  --tab Automations --destination run
python3 scripts/preview_ios_design.py --device "$TALARIA_PREVIEW_DEVICE" \
  --handoff /tmp/talaria-hierarchy-design-fixture.json --tab Activity
python3 scripts/preview_ios_design.py --device "$TALARIA_PREVIEW_DEVICE" \
  --handoff /tmp/talaria-hierarchy-design-fixture.json \
  --tab Automations --destination discuss
python3 scripts/preview_ios_design.py --device "$TALARIA_PREVIEW_DEVICE" \
  --handoff /tmp/talaria-hierarchy-design-fixture.json \
  --tab Home --home unavailable
xcrun simctl io "$TALARIA_PREVIEW_DEVICE" screenshot /tmp/talaria-hierarchy-preview.png
```

The four `--tab` values are `Home`, `Workspaces`, `Automations`, `Activity`. Detail values include `workspace`, `approval`, `automation`, `run`, `failed-run`, `no-output`, `conversation`, `discuss` and `activity-request`. `--home unselected` opens first use; `--keyboard` focuses the composer on a conversation preview. The runner validates the private handoff and passes credentials in the child environment rather than command arguments. Routing hooks are Debug-only.
