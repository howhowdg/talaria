# Telegram topic integration

Talaria imports Hermes's explicit Telegram topic bindings through an optional,
read-only gateway extension. Hermes must first receive a message in a topic and
persist its routing metadata. This integration does not scrape Telegram, log in
as the user, send Telegram messages or fetch live topic titles.

## Install on the Hermes host

Keep these files together on the host, preferably in a Talaria checkout:

- [scripts/talaria_gateway.py](../scripts/talaria_gateway.py)
- [scripts/telegram_topics.py](../scripts/telegram_topics.py)
- [scripts/telegram_topic_names.py](../scripts/telegram_topic_names.py)

Run the launcher with Hermes's Python environment from the Hermes checkout.
Replace the placeholder paths and profile name for your installation:

```sh
cd /path/to/hermes-agent
.venv/bin/python /path/to/talaria/scripts/talaria_gateway.py \
  -p default serve --isolated --host 127.0.0.1 --port 9119 --no-open
```

All CLI arguments are handled by Hermes. Use `--isolated`: otherwise Hermes can
route a named-profile launch to the machine dashboard and re-execute its ordinary
launcher without the extension. In an existing gateway launcher, replace
`-m hermes_cli.main` with the `talaria_gateway.py` path while retaining its
profile, authentication, ownership, readiness and lifecycle settings.

The extension allows Hermes to apply `-p` before loading configuration, then
registers its route when Hermes imports the prepared web server. It modifies no
installed Hermes source. Normal authentication, hostname validation, OAuth gates
and CORS rules stay in force; the extension adds no authentication exceptions.

Connect Talaria to this gateway using its usual session token. Keep a remote
backend behind the existing SSH tunnel or authenticated HTTPS deployment.
Talaria does not manage that tunnel and its preview does not implement gated
OAuth sign-in. A loopback URL on a phone refers to the phone, not the Hermes host.

## Import in Talaria

1. Connect to the gateway and select the intended profile.
2. Open Home or Workspaces and choose **Import from Telegram…**.
3. Choose a topic for Home, or keep the current Home. Select the topics to add as
   Workspaces; a topic chosen as Home is excluded from the Workspace selection.
4. Choose **Import**. Opening the sheet or refreshing does not classify topics.

The sheet initially selects available topics as Workspace candidates. Review
those selections before importing. Importing changes only local organisation;
it does not send a conversation message or alter Telegram.

Choices persist on this device by connection and profile. Their stable identity
is the chat/thread/routing key, so opening or refreshing can follow Hermes's
explicit current-session pointer after a Telegram reset. Missing or unverifiable
bindings preserve saved choices and disable sending rather than substitute an
unrelated conversation. There is no periodic live synchronisation.

If discovery is unavailable, check that the gateway was started with this
launcher and that Hermes has recorded a topic for the selected profile. Ordinary
direct messages and the redirectable direct-message topic-mode lobby are excluded.

## Endpoint contract

`GET /api/talaria/telegram/topics?profile=default` requires normal gateway
authentication, such as the `X-Hermes-Session-Token` header. Example response:

```json
{
  "schema_version": 1,
  "profile": "default",
  "topics": [{
    "chat_id": "-100123",
    "thread_id": "7",
    "session_key": "agent:main:telegram:group:-100123:7",
    "current_session_id": "current-hermes-session",
    "chat_type": "group",
    "chat_name": "Example chat",
    "topic_name": "Example topic",
    "binding_source": "gateway_routing"
  }]
}
```

Names may be `null`. The reader follows `gateway_routing` pointers in the resolved
profile's `state.db`, using that profile's canonical `sessions` scope. It never
selects by title or recency or falls back to another profile or old routing scope.
The canonical General topic ID can supply the label `General`; the user still
chooses whether it becomes Home.

SQLite opens read-only with bounded rows and field sizes. The endpoint returns no
messages, credentials or filesystem paths. Missing or malformed metadata yields
an explicit error. A gateway without the extension returns its normal unsupported
route response; existing local assignments remain intact.

## Recover saved topic names

Topic and conversation titles are separate. Labels come first from explicit
`origin.chat_topic`, then configured Telegram topic names, then the profile-owned
`talaria-telegram-topic-names.json` cache. Matching uses chat, topic and routing
identity, never conversation content or title.

To recover names from successful structured topic creation/edit events already
recorded in Hermes tool results, run this read-only backfill with Hermes's Python
environment. Substitute the selected profile's home directory, and save the
result in a private directory:

```sh
cd /path/to/hermes-agent
umask 077
.venv/bin/python /path/to/talaria/scripts/telegram_topic_names.py \
  --hermes-home /path/to/profile-home --profile default \
  > /path/to/private/recovered-topic-names.json
```

Review the result before installing it as `talaria-telegram-topic-names.json`
inside that profile's home with mode `0600`. Merge with any existing verified
records rather than overwrite them. The output's `truncated` field identifies a
partial bounded scan. Ordinary navigation reads configuration and this small
cache; it does not repeatedly scan transcripts or execute stored commands.

These are **last-observed names**, not titles freshly fetched from Telegram.
Manual renames that Hermes never recorded cannot be reconstructed. An unnamed
topic appears as `Topic <ID>`, with its conversation title shown separately.
Refresh replaces imported numbered defaults when names become available. Later
name changes follow only while a Workspace retains its last imported name;
custom names and archive choices are preserved.

## Contributor checks

Run these from the Talaria repository root. The last command requires an existing
Hermes checkout and its Python dependencies; replace both placeholder paths.

```sh
PYTHONPATH=scripts python3 -m unittest discover -s scripts/tests -p test_telegram_topics.py
PYTHONPATH=scripts python3 -m unittest discover -s scripts/tests -p test_telegram_topic_names.py
PYTHONPATH=scripts:/path/to/hermes-agent /path/to/hermes-python \
  -m unittest discover -s scripts/tests -p test_talaria_gateway.py
```

Gateway tests use the real Hermes ASGI app and middleware with a disposable home
to exercise token rejection, profile isolation, late route registration and safe
errors. They neither start a bot nor contact Telegram.
