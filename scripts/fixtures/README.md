# Real gateway smoke fixtures

Run these commands from the Talaria repository root in the same shell. The native
client requires the development tools listed in the [main README](../../README.md).
The integration fixture additionally needs Git, `python3`, and
[uv](https://docs.astral.sh/uv/getting-started/installation/) on `PATH`.
No Hermes account or provider API key is needed.

For a fresh checkout, fetch the exact backend revision recorded in
[`Contracts/pin.json`](../../Contracts/pin.json). The `upstream/` directory is
ignored by Git and is not included in a Talaria clone:

```sh
TALARIA_ROOT="$(pwd)"
TALARIA_HERMES_REPOSITORY="$(python3 -c 'import json; print(json.load(open("Contracts/pin.json"))["repository"])')"
TALARIA_HERMES_COMMIT="$(python3 -c 'import json; print(json.load(open("Contracts/pin.json"))["commit"])')"
mkdir -p "$TALARIA_ROOT/upstream"
git clone --filter=blob:none --no-checkout "$TALARIA_HERMES_REPOSITORY" \
  "$TALARIA_ROOT/upstream/hermes-agent"
git -C "$TALARIA_ROOT/upstream/hermes-agent" checkout --detach "$TALARIA_HERMES_COMMIT"
```

If that destination already exists, use a separate clean checkout and adjust the
paths below. The harness requires a Git checkout at the pinned revision and rejects
repositories containing `.env` or `.op.env` files.

Install the pinned backend's core and web dependencies into a dedicated virtual
environment. The pinned project supports Python 3.11–3.13; this recipe selects
3.11. `uv` can download that interpreter if needed. The dependency installation
requires network access; the subsequent smoke run uses synthetic loopback inference.
The `--locked` flag preserves upstream's `uv.lock` resolution:

```sh
UV_PROJECT_ENVIRONMENT="$TALARIA_ROOT/upstream/hermes-agent/.venv" \
  uv sync --project "$TALARIA_ROOT/upstream/hermes-agent" \
  --python 3.11 --locked --extra web --no-dev
```

This fresh-environment installation recipe has not been run as part of Talaria's
reported verification. The successful integration runs below used an existing
Python environment with Hermes dependencies. If locked installation fails, retain
the error for diagnosis rather than silently updating the lockfile.

Build the smoke executable and ask SwiftPM for its actual output directory, using
the same scratch path for both commands:

```sh
swift build --scratch-path /tmp/talaria-swift-build --product hermes-smoke
TALARIA_SMOKE_BIN="$(swift build --scratch-path /tmp/talaria-swift-build --show-bin-path)/hermes-smoke"
```

Run the checks with explicit source, interpreter and executable paths:

```sh
python3 scripts/smoke-real-gateway.py \
  --repo "$TALARIA_ROOT/upstream/hermes-agent" \
  --python "$TALARIA_ROOT/upstream/hermes-agent/.venv/bin/python" \
  --smoke "$TALARIA_SMOKE_BIN" --timeout 120
python3 scripts/smoke-real-gateway.py \
  --repo "$TALARIA_ROOT/upstream/hermes-agent" \
  --python "$TALARIA_ROOT/upstream/hermes-agent/.venv/bin/python" \
  --smoke "$TALARIA_SMOKE_BIN" --native-runtime --timeout 120
python3 scripts/smoke-real-gateway.py \
  --repo "$TALARIA_ROOT/upstream/hermes-agent" \
  --python "$TALARIA_ROOT/upstream/hermes-agent/.venv/bin/python" \
  --smoke "$TALARIA_SMOKE_BIN" --native-runtime --extended --timeout 180
```

You can instead pass `--python` pointing to another existing environment with the
upstream dependencies. The harness uses its packages read-only and imports Hermes
from `--repo` through `PYTHONPATH`; it checks the checkout's Git revision against
`Contracts/pin.json`. It does not install or change dependencies. Omitting overrides
uses `upstream/hermes-agent`, `~/.hermes/hermes-agent/venv/bin/python`, and
`.build/debug/hermes-smoke`; those defaults are not the paths prepared above.
`--backend-only` checks server startup and authenticated HTTP, without claiming
that chat or the Swift transport passed.

For a subsequent manual native-app check, add `--hold-for-ui 600`. After the full
smoke passes, the server remains alive for ten minutes and writes its loopback
`base_url`, generated `token`, `profile`, process ID and expiry to
`/tmp/hermes-native-ui-fixture.json` with mode `0600`. Use this temporary connection
with credential remembering disabled. The handoff file is removed when the hold
ends; the harness then stops the server and deletes its disposable home. The
token belongs only to this synthetic fixture, never an existing account.
With `--extended`, the handoff also lists synthetic picker file paths, a suggested
attachment prompt/model, the secondary profile and retained stored session IDs.

`--native-runtime` makes the Swift `LocalRuntimeManager` launch the real backend
instead of the Python harness. The client receives the manager's generated token
and announced endpoint, performs the same chat/tool/reconnect checks, calls
`manager.stop()`, and verifies that the owned HTTP listener refuses connections.
The harness supplies isolated launch paths with `--launch-python`, `--launch-home`
and `--launch-cwd`; it does not supply the native manager's token. This mode cannot
be combined with `--backend-only` or `--hold-for-ui`, since its final assertion
requires a stopped runtime.

`--extended` adds a configured synthetic alternate model and a second isolated
profile. The client uses the native settings service to load inventory, change
only the active session's model, reject a stale-session mutation and check that
the profile default remains unchanged. It uploads a document into the session
workspace with the native multipart client and an image into the profile image
directory with the HTTP image client, explicitly queues the image, then submits
the references. The mock provider checks the actual document marker and exact PNG
bytes in the real inference request; an upload acknowledgment alone cannot pass.
Reconnect must preserve the attachment history and the image queue must be empty
after completion. A second connection checks named-profile model routing and
session-history isolation. The generated PNG and text files contain no user data.

The workspace is intentionally separate from `HERMES_HOME`. Upstream
`file.attach` stores uploaded documents under the profile's attachment directory,
while `@file` expansion rejects paths outside the conversation workspace. Native
document transfer uses `cwd/.hermes/native-attachments/<UUID>/` and a relative
reference, exercising the existing workspace restriction without weakening it.

The backend is the real `hermes_cli.main --profile default serve --host 127.0.0.1
--port 0`, including the real agent loop, session database, WebSocket bridge and
`todo_list` execution. Only model inference is synthetic. `mock_openai.py`
advertises `native-smoke-model` and returns a streamed safe todo tool call, then
returns its final text only after receiving the real tool result. The Swift
client creates a session, submits a prompt, waits for `message.complete`, lists
stored sessions, disconnects, reconnects, resumes and checks assistant history.
The harness additionally requires the mock provider to have consumed a tool
result without fixture errors.

Every run creates a disposable root with separate directories for `HOME`,
`HERMES_HOME`, `HERMES_MANAGED_DIR`, `HERMES_SHARED_AUTH_DIR`, XDG config/cache/data,
temporary files and the terminal workspace. The child environment is constructed
from a fixed list; it does not inherit provider keys, proxies, SSH agents or other
Hermes launch markers. The only provider credential is the fixture string
`local-test-only`. A random gateway token is passed in the environment, never in
command arguments, and redacted from diagnostic output. The harness refuses a
source checkout containing a repository `.env` or `.op.env` fallback.

The temporary configuration selects the custom loopback provider and
`chat_completions`, disables memory/user-profile memory and automatic model title
generation, and configures no MCP servers. `HERMES_TUI_TOOLSETS=todo` restricts the
agent to the in-memory task-list tool. `HERMES_DESKTOP=1` exercises desktop server
startup, and `HERMES_PARENT_PID` gives the backend an owned parent lifetime.
`sitecustomize.py` adds a Python audit hook rejecting non-loopback outbound
connections and DNS resolution. This is a test guard for Python networking, not
an operating-system sandbox for arbitrary child programs. No shell-execution
tool is enabled by the fixture. The harness stops only its own backend process.

Validated against commit `a566d20d226a8e2ef0747639dc8a3fc1c43f9dba` on macOS:

- Authenticated HTTP and both native WebSocket connections succeeded.
- One completed turn emitted text and reasoning deltas, `tool.start`,
  `tool.complete`, and `todo.updated`.
- Reconnect/resume recovered four persisted history messages.
- Two streamed inference requests produced one real todo tool cycle; the mock
  provider reported zero errors.
- The `--native-runtime` run also passed: Swift launched the real backend,
  generated its own token, completed the same flow, and verified connection
  refusal after stopping its owned runtime.
- The combined `--native-runtime --extended` run passed model selection,
  stale-session rejection, both persisted profile defaults, cross-profile model
  and history routing, exact document/image delivery and attachment history.
  Five streamed inference calls reached all three synthetic models with zero
  fixture errors; resumed attachment history contained six messages.

This proves the native transport and history path against the pinned real server.
It does not validate real model quality, provider authentication, remote OAuth,
network-loss recovery, approvals, arbitrary tools, or the macOS UI. Attachment
delivery is exercised by `--extended`; native picker interaction is a separate
manual UI check using the held fixture.
The Swift runtime supervisor also has separate temporary-process lifecycle tests.
The default harness mode starts Python itself; `--native-runtime` covers the
supervisor with the real pinned backend.
