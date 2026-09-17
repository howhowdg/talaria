# Native attachment contract

Audited against pinned Hermes commit `a566d20d226a8e2ef0747639dc8a3fc1c43f9dba`.

## Existing desktop and gateway behavior

The Electron composer stages non-image files (including PDFs) through `file.attach`
with `{session_id, profile, name, data_url}`. Images use `image.attach_bytes` with
`{session_id, profile, filename, content_base64}` when the backend cannot read the
device path. See `apps/desktop/src/app/session/hooks/use-prompt-actions/index.ts`,
`uploadComposerAttachment`.

`prompt.submit` has no `attachments` parameter. File reference strings accompany
the plain-text prompt. Images live in the backend session's `attached_images`
queue, consumed on turn admission. `image.attach`, `image.attach_bytes`, and
`pdf.attach` mutate that queue immediately. `image.detach {session_id,profile,path}`
removes a known queued path; there is no image-list RPC. `pdf.attach` rasterizes up
to 25 pages and requires `pdftoppm`; it is distinct from attaching a PDF as a file.

Sources: `tui_gateway/contracts/prompt_voice.py`, `methods_prompt.py:715–915`,
`prompt_attachments.py`, and `prompt_turn.py:109–156`.

Inline `@image:<path>` is a persisted display reference, not sufficient to attach
native vision input. The gateway preprocesses `@file`/`@folder`/Git references in
string prompts, then routes separately queued images according to the selected
model and image-input configuration. Structured content passed directly through
`prompt.submit.text` skips the string context-reference expansion and normal
image-routing decision; it is not used as a shortcut in the native client.

## Queue-free native transfers

The new native transfer service uploads bytes without changing the session image
queue or sending a turn:

| Kind | HTTP route | Body | Result |
|---|---|---|---|
| PNG/JPEG/GIF/WebP/BMP image | `POST /api/chat/image-upload?profile=...` | JSON `filename`, `data_url` | `ok`, absolute `path`, `bytes`, `mime_type` |
| Document, PDF, or other regular file | `POST /api/files/upload-stream?profile=...` | Multipart `file`, `path`, `overwrite=false` | `ok`, absolute `path`, `entry` |

Both use `X-Hermes-Session-Token`; secrets never enter persistent endpoint URLs.
Existing endpoint validation permits HTTPS and loopback HTTP, preserves a reverse
proxy base path, and rejects embedded credentials/query/fragment. The existing
ephemeral network session rejects redirects and has cookies/caches disabled.
The transfer layer returns sanitized errors and never surfaces response bodies or
raw networking error descriptions containing URLs/credentials.

The image route writes under the selected profile's `images/` directory and
validates its image magic. Its upstream cap is 25 MiB. The managed upload route
streams into a sibling temporary file, enforces a 100 MiB upstream cap, and
atomically renames on completion. Managed-file policy can reject a destination
outside a hosted root; the native client reports that rejection instead of
silently staging somewhere else. See `hermes_cli/web_routers/files.py:285–357,
477–566` and `hermes_cli/web_server_files.py:124–173`.

The preview uses a stricter **20 MiB per-file**, **8 files / 64 MiB per-message**
budget. Device files are read with security-scoped access, file coordination,
regular-file checks, a bounded read loop, and cancellation checks. Directories,
packages, symlinks, empty files, invalid image signatures, and PDF names without
PDF magic are rejected. Image bytes are not recompressed. Unsupported image types
such as HEIC/TIFF/SVG need a later deliberate conversion or document policy.
Binary document files are uploaded unchanged; validating their whole document
format remains the backend tool's responsibility.

## Document placement and workspace boundary

At this pinned commit, `file.attach` stages uploaded documents under
`<profile_home>/attachments` and can return an absolute `@file:` path outside the
conversation's working directory. The gateway expands file references with
`allowed_root=cwd`, which rejects that reference for a separate project workspace.
See `prompt_attachments.py:136–194`, `prompt_turn.py:523–538`, and
`agent/context_references.py`'s path expansion boundary.

The native client therefore uploads documents directly to a generated destination:

```text
<gateway workspace>/.hermes/native-attachments/<attachment UUID>/<safe filename>
```

It submits a workspace-relative `@file:.hermes/native-attachments/...` reference.
The UUID avoids collisions and `overwrite=false` refuses replacement. The chip
shows the host destination. These files remain after send/removal because stored
conversation references can still need them; this implementation does not perform
automatic host-file deletion. No gateway path is ever interpreted as a local Mac
or iPhone URL. Windows drive/UNC paths are treated as opaque host strings.

## Ownership and submission

`AttachmentScope` aliases `ComposerScope(connectionID, profile, storedSessionID)`.
Device bytes are held in `StagedAttachment` in memory only, and successful uploads
produce `UploadedAttachment` retaining exactly that owner. Endpoint/profile
mismatches fail before network I/O. A canceled transfer rejects even a late
successful HTTP response. The owner must also discard completion after a composer
or connection generation changes; upload completion never initiates a send.

`AttachmentPrompt.compose` validates owner/budgets and adds only document
references. An attachments-only message receives an explicit fallback caption.
Images have `hostPath` but no `promptReference`; `AttachmentSender` calls
`image.attach` with the uploaded path just before `prompt.submit`, preserving the
gateway's vision/text routing behavior. Each attempted image path is journaled
before that RPC. A positive acknowledgement must contain `attached=true`, a valid
canonical host path, and the expected queue count. The canonical path is persisted
before submitting. All attachment-bearing submissions set `queued=true`, ensuring
that document references receive normal new-turn expansion if the session becomes
busy during preparation.

A `streaming` response arrives before agent initialization and turn admission.
Initialization failure or an early interrupt can leave images in the queue, so the
sender retains its journal until authoritative hydration shows no running or queued
turn. A `queued` response synchronously transfers the images into the queued turn,
so its journal can be cleared without detaching. Typed `voice_stopped` responses
occur before image consumption and require cleanup before returning a definite
non-submission to the composer. Unknown/malformed/lost submit acknowledgements
remain locked for reconciliation and are never automatically replayed.

Cleanup validates `image.detach` acknowledgements and removes only recorded paths.
A lost attach acknowledgement can hide canonicalization of a symlinked profile
home: if the raw path does not detach anything and the queue is nonempty, the
sender cannot establish ownership and remains locked. It does not guess a path by
basename. Restarting that Hermes runtime clears this condition; an explicit 4001
session-not-found response also establishes that its old queue is gone. Journal
matching uses connection/profile plus stored ID or recorded runtime ID so stored
ID rotation cannot bypass a pending send. Journal files are device-local, written
atomically with mode 0600, and contain host paths but no bytes or credentials.

**Upstream concurrency limit:** this pinned backend has no `image.list` RPC, no
attachment ownership token, and no atomic attach-and-submit method. Attach ACK
counts detect an already populated or concurrently changed queue, but another
client can still submit between our attach and submit and consume those images.
The preview therefore requires a single active sending client per conversation;
full cross-device concurrency needs an upstream atomic submission contract. Text
and document-only sends cannot preflight an unrelated image queue through this
version's API. This is not solved by local journaling.

## Portable APIs

```swift
let staged = try await AttachmentLoader.read(url: deviceURL, scope: composerScope)
// In-memory paste/drop and fixtures:
let stagedBytes = try AttachmentLoader.stage(data: bytes, filename: "notes.txt", scope: composerScope)
let uploaded = try await AttachmentTransferService().upload(
    staged, workspace: conversation.cwd, endpoint: endpoint, token: token)
let text = try AttachmentPrompt.compose(text: draft, attachments: [uploaded], scope: composerScope)
```

`AttachmentStrip` renders immutable `AttachmentItem` values and a remove callback;
the containing native composer owns its document picker and in-flight tasks.
