"""Read authoritative Telegram topic bindings without importing or modifying Hermes.

The caller resolves and authorizes ``hermes_home`` for the requested profile. This
module deliberately does not search other homes, use historical session titles,
or fall back to a different routing scope. It exposes only routing metadata.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sqlite3
from typing import Any


MAX_ROUTING_ROWS = 2_048
MAX_ENTRY_BYTES = 65_536
_PROFILE_ID = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
_GROUP_TYPES = frozenset(("group", "supergroup", "forum"))


class TelegramTopicsError(Exception):
    """A safe error suitable for an authenticated API response; no paths or data."""

    def __init__(self, code: str, message: str, status_code: int = 503):
        super().__init__(message)
        self.code = code
        self.status_code = status_code


def _invalid() -> TelegramTopicsError:
    return TelegramTopicsError(
        "telegram_topics_invalid", "Telegram routing metadata is invalid."
    )


def _identifier(value: Any, *, limit: int = 512) -> str:
    if isinstance(value, int) and not isinstance(value, bool):
        value = str(value)
    if (not isinstance(value, str) or not value or len(value) > limit
            or value.strip() != value or any(ord(char) < 32 for char in value)):
        raise _invalid()
    return value


def _label(value: Any) -> str | None:
    if value is None or value == "":
        return None
    if not isinstance(value, str) or len(value) > 512:
        raise _invalid()
    return value


def _topic(key: Any, raw: Any, profile: str) -> dict[str, Any] | None:
    if not isinstance(raw, str):
        raise _invalid()
    try:
        entry = json.loads(raw)
    except (ValueError, RecursionError) as error:
        raise _invalid() from error
    if not isinstance(entry, dict):
        raise _invalid()
    origin = entry.get("origin")
    if origin is None:
        # Unrelated CLI/cron routes have no messaging source. A Telegram route
        # without its source cannot be safely identified from its key alone.
        if entry.get("platform") == "telegram" or ":telegram:" in str(key):
            raise _invalid()
        return None
    if not isinstance(origin, dict):
        raise _invalid()
    if origin.get("platform") != "telegram":
        return None

    source_profile = origin.get("profile")
    if source_profile not in (None, "", profile):
        # A multiplexed store may contain explicit routes for other profiles.
        # The exact home scope is necessary but not sufficient for those rows.
        return None
    thread = origin.get("thread_id")
    if thread in (None, ""):
        return None  # Ordinary DMs and non-topic chats are not this importer.
    thread = _identifier(thread)
    chat_type = origin.get("chat_type") or entry.get("chat_type")
    if chat_type not in (*_GROUP_TYPES, "dm", "thread", "channel"):
        raise _invalid()
    if chat_type == "dm" and thread == "1":
        # Unlike forum General, the DM topic-mode lobby can be redirected by
        # Hermes to another topic. Do not present it as a durable Home binding.
        return None

    route_key = _identifier(key, limit=2_048)
    if _identifier(entry.get("session_key"), limit=2_048) != route_key:
        raise _invalid()
    topic_name = _label(origin.get("chat_topic"))
    return {
        "chat_id": _identifier(origin.get("chat_id")),
        "thread_id": thread,
        "session_key": route_key,
        "current_session_id": _identifier(entry.get("session_id")),
        "chat_type": chat_type,
        "chat_name": _label(origin.get("chat_name")),
        "topic_name": topic_name,
        "binding_source": "gateway_routing",
    }


def read_telegram_topics(
    hermes_home: str | Path, profile: str = "default"
) -> dict[str, Any]:
    """Return a bounded snapshot of explicit current topic-to-session pointers.

    ``hermes_home`` must already be resolved for ``profile`` by the serving
    application's trusted profile resolver. Missing names remain null. Missing
    or malformed metadata raises a safe error instead of claiming a complete
    empty import. No sessions, files, topics, or database rows are created.
    """
    if not isinstance(profile, str) or not _PROFILE_ID.fullmatch(profile):
        raise TelegramTopicsError("invalid_profile", "Invalid Hermes profile.", 400)
    home = Path(hermes_home).expanduser().resolve()
    scope = str((home / "sessions").resolve())
    connection: sqlite3.Connection | None = None
    try:
        connection = sqlite3.connect(
            (home / "state.db").as_uri() + "?mode=ro", uri=True, timeout=2.0
        )
        connection.execute("PRAGMA query_only = ON")
        rows = connection.execute(
            "SELECT session_key, CASE WHEN length(CAST(entry_json AS BLOB)) <= ? "
            "THEN entry_json ELSE NULL END FROM gateway_routing "
            "WHERE scope = ? ORDER BY session_key LIMIT ?",
            (MAX_ENTRY_BYTES, scope, MAX_ROUTING_ROWS + 1),
        ).fetchall()
    except (sqlite3.Error, OSError) as error:
        raise TelegramTopicsError(
            "telegram_topics_unavailable", "Telegram routing metadata is unavailable."
        ) from error
    finally:
        if connection is not None:
            connection.close()
    if len(rows) > MAX_ROUTING_ROWS:
        raise TelegramTopicsError(
            "telegram_topics_limit", "Telegram routing metadata exceeds the supported limit."
        )

    topics: list[dict[str, Any]] = []
    identities: set[tuple[str, str, str]] = set()
    for key, raw in rows:
        topic = _topic(key, raw, profile)
        if topic is None:
            continue
        identity = (topic["chat_id"], topic["thread_id"], topic["session_key"])
        if identity in identities:
            raise _invalid()
        identities.add(identity)
        topics.append(topic)
    # Names and routing authority are separate. This small cache holds only
    # explicit name-to-topic evidence recovered from Hermes, never chat titles.
    # Configuration and live origin metadata take precedence over old records.
    from telegram_topic_names import load_topic_name_cache, read_config_topic_names

    labels = load_topic_name_cache(home, profile, topics) + read_config_topic_names(home, profile, topics)
    by_identity = {(row["chat_id"], row["thread_id"], row["session_key"]): row["topic_name"] for row in labels}
    for topic in topics:
        if topic["topic_name"] is None:
            topic["topic_name"] = by_identity.get((topic["chat_id"], topic["thread_id"], topic["session_key"]))
        if topic["topic_name"] is None and topic["chat_type"] in _GROUP_TYPES and topic["thread_id"] == "1":
            # Canonical forum General identity, after all explicit labels.
            topic["topic_name"] = "General"
    return {"schema_version": 1, "profile": profile, "topics": topics}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hermes-home", type=Path, required=True)
    parser.add_argument("--profile", default="default")
    args = parser.parse_args()
    try:
        print(json.dumps(read_telegram_topics(args.hermes_home, args.profile)))
    except TelegramTopicsError as error:
        parser.exit(1, f"{error.code}: {error}\n")


if __name__ == "__main__":
    main()
