# Preview status

Talaria is an independent SwiftUI client for the existing Hermes Python agent.
The current Mac preview is **0.1.2**, for macOS 14 or later on Apple silicon and
Intel. The public app is Developer ID signed, notarized and stapled. iOS source
targets iOS 17 or later; an installable iPhone release is not yet published.
Talaria does not yet provide full Hermes Desktop feature parity.

## Available now

- **Conversations:** create and resume conversations, search the latest 100
  sessions, stream assistant text and reasoning, inspect tool results, interrupt
  work and restore history after reconnecting. Native Markdown includes headings,
  lists, quotes and fenced code.
- **Home and Workspaces:** explicitly choose Home; create, archive or restore
  Workspaces and assign conversations. Names, colours, membership, read
  tracking and transcript places persist on this device by connection and profile.
- **Automations:** view host jobs and their run history, pause or enable jobs, and
  run or retry enabled jobs. Results appear before expandable execution details.
  A paused job must be enabled explicitly before it can run.
- **Activity:** review unread run results separately from requests that need a
  decision. Marking results read never answers an approval or clarification.
- **Host requests:** native approval, clarification and masked secret, sudo and
  vault input retain the host's allowed choices and restrictions.
- **Models and profiles:** select existing profiles, session-specific provider and
  model settings, and supported reasoning levels. Host cost confirmations remain
  explicit.
- **Attachments and drafts:** native file selection, upload progress, persistent
  text drafts and recovery for interrupted image sends. Limits are eight files,
  20 MB per file and 64 MB per message. Supported images are PNG, JPEG, GIF, WebP
  and BMP; document extraction depends on the host's installed readers.
- **Connections:** token-authenticated gateways, optional Keychain token storage,
  and Mac discovery and supervision of an existing local Hermes installation.
- **Telegram topics:** explicit Home/Workspace import through the optional
  [gateway extension](telegram-topics.md). Stable topic identities follow the
  host's current session when opened or refreshed.

Mac uses a sidebar, conversation pane and Context/Files/Terminal inspector. iOS
uses Home, Workspaces, Automations and Activity tabs, with Skills and Settings in
the profile menu. Both support light/dark appearance and accessibility fallbacks.

## Important limits

- Hermes and Python are not bundled or installed by Talaria. iOS connects to a
  host and does not run the agent locally. Remote gateways require HTTPS;
  unencrypted HTTP is accepted only on loopback. Gated OAuth/Cloud sign-in and
  managed SSH tunnel startup are not implemented.
- Organisation and drafts do not sync across devices. A confirmed missing Home
  retains a bounded cached transcript with its composer disabled. Titles,
  recency and backend parent IDs never assign Home or Workspace membership.
- Use **one active native client per session**. The pinned backend's image queue
  is session-wide. Multi-client request settlement, full replay-gap recovery and
  attachment leases remain incomplete. An uncertain send is never replayed
  automatically; review authoritative history before retrying.
- Attachments must be selected again after app relaunch. Removing a composer
  attachment does not delete its uploaded host file. Draft text persists, while
  the recovery journal stores host image paths rather than file bytes.
- Files and Terminal show recorded tool evidence. They are not a live filesystem
  browser or interactive shell, and a host path is never opened through the
  device's local filesystem. Skills is a read-only inventory.
- Discuss this result stages selected context in a destination draft. Sending
  remains explicit; the back-link is local to the connection and profile, not a
  host-guaranteed provenance reference.
- Telegram labels are last observed names from Hermes metadata, configuration or
  recorded topic events. Live title lookup and periodic synchronisation are not
  implemented. Unverifiable bindings preserve the assignment and disable sending.
- Automation creation/editing, delegated-task lifecycle, general Home
  reset/compression continuity, canonical result references, provider account
  setup and profile creation/editing/deletion are unfinished.
- Live steering, queued prompts during a running turn, voice, push notifications,
  background delivery, rich media, Markdown tables, syntax highlighting,
  interactive terminals, browser control, projects/git and plugin/MCP management
  are not available yet.
- Physical-device networking, older supported OS versions and clean-machine
  runtime coverage remain release-validation work. The regular-width iOS shell
  is shared with iPhone; a dedicated iPad experience remains unfinished.

See [contributor setup](../CONTRIBUTING.md) for builds and checks,
[architecture](architecture.md) for ownership boundaries, and
[Mac distribution](mac-distribution.md) for release packaging.
