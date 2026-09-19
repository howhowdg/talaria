# Telegram topic integration

Talaria can import Hermes's explicit Telegram topic bindings through an optional
read-only gateway extension. It does not scrape the Telegram UI or call Telegram
with the user's credentials. Hermes must have received a message in a topic and
persisted its routing metadata before that topic can be discovered.

## Gateway extension

Keep `scripts/talaria_gateway.py`, `scripts/telegram_topics.py` and
`scripts/telegram_topic_names.py` together on the
Hermes host. Run the launcher with Hermes's Python environment, from its checkout:

```sh
cd /path/to/hermes-agent
.venv/bin/python /path/to/talaria/scripts/talaria_gateway.py \
  -p default serve --isolated --host 127.0.0.1 --port 9119 --no-open
```

All CLI arguments belong to Hermes. Existing owned SSH-backend launchers can
replace `-m hermes_cli.main` with the path to `talaria_gateway.py`, retaining their
profile, token-file, owner-nonce, ready-file and lifecycle settings. Use
`--isolated`: Hermes can otherwise route a named-profile launch to the machine
dashboard and re-execute its ordinary launcher without the extension.

The launcher lets Hermes apply `-p` before importing configuration and registers
the route when Hermes imports its prepared web server. It modifies no installed
Hermes source files. Existing authentication, host validation, OAuth gates and
CORS rules remain in force; it adds no public paths or query-token exceptions.
Keep remote backends behind the same SSH tunnel or authenticated deployment used
for the rest of Talaria.

## Read contract

`GET /api/talaria/telegram/topics?profile=default` requires the normal gateway
authentication, such as `X-Hermes-Session-Token`. Its response is:

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

Names may be `null`. The reader follows current `gateway_routing` pointers in the
resolved profile's `state.db`, using exactly that profile's canonical `sessions`
scope. It never selects history by title or recency and never falls back to a
different profile or old routing scope. A forum's canonical General topic ID can
provide the label `General`; assigning it as Home still belongs to the user.
Ordinary non-topic DMs and Hermes's redirectable DM topic-mode lobby are excluded.

SQLite is opened read-only with bounded rows and field sizes. No messages,
credentials or filesystem paths are returned. Missing/malformed metadata is an
explicit error rather than a successful empty import. A gateway without this
extension returns its normal unsupported-route response; Talaria should retain
existing local classifications and explain that topic discovery is unavailable.

Imported Home and Workspace choices remain local to a Talaria connection and
profile. The durable identity is the chat/thread/routing key, allowing a later
refresh to follow an explicit current-session pointer after a Telegram reset.
Missing bindings must not cause an unrelated conversation to replace Home.

## Recovering saved topic names

Topic titles are independent of conversation titles. The reader first uses an
explicit `origin.chat_topic`, then configured Telegram topic names, then a small
profile-owned `talaria-telegram-topic-names.json` cache. Labels are matched by
chat, topic and routing key, never inferred from a chat's content or title.

An explicit, read-only backfill can recover names from successful structured
Telegram topic creation/edit events already recorded in Hermes tool results:

```sh
.venv/bin/python /path/to/talaria/scripts/telegram_topic_names.py \
  --hermes-home /path/to/profile-home --profile default > /private/path/recovered-topic-names.json
```

Review the result before installing it as `talaria-telegram-topic-names.json`
inside that profile's home with mode `0600`. Preserve any existing verified
records when merging. The output reports whether the bounded scan was truncated.
The metadata endpoint reads only this cache and configuration, so ordinary
navigation does not repeatedly scan transcripts. Stored commands are never run.

These are **last-observed names**, not current titles fetched from Telegram.
Manual renames that Hermes never recorded cannot be reconstructed from this
data. Full current-title lookup needs a separate Telegram metadata integration;
this extension does not call Telegram, consume bot updates or use a user's
Telegram login.

Talaria replaces an imported `Topic <ID>` default when a name becomes available.
Subsequent metadata name changes follow only while the Workspace still uses its
last imported name. Custom Workspace names and archive choices are preserved.
Existing numbered imports migrate on the next topic refresh without reimporting.

## Verification

```sh
PYTHONPATH=scripts python3 -m unittest discover -s scripts/tests -p test_telegram_topics.py
PYTHONPATH=scripts:/path/to/hermes-agent /path/to/hermes-python \
  -m unittest discover -s scripts/tests -p test_talaria_gateway.py
```

The gateway tests use the real Hermes ASGI app and middleware with a disposable
home. They cover token rejection, profile traversal and missing-profile failures,
A → B → A profile isolation, late registration after CLI profile selection, and
safe error responses. They do not start a bot or contact Telegram.
