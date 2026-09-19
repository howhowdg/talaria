"""Last-observed Telegram topic labels, separate from authoritative route identity.

The endpoint reads configuration and a small profile-owned cache. An explicit
backfill can recover names from bounded, structured Bot API tool results already
stored by Hermes. Nothing contacts Telegram or executes stored tool arguments.
Historical names must never be represented as freshly verified Telegram titles.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import re
import sqlite3
from typing import Any, Iterator

CACHE_FILENAME = "talaria-telegram-topic-names.json"
MAX_CACHE_BYTES = 1_048_576
MAX_RESULT_BYTES = 500_000
MAX_RECOVERY_ROWS = 500
MAX_RECOVERY_BYTES = 8_388_608
_PROFILE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
_SOURCES = frozenset(("createForumTopic_result", "forum_topic_created", "forum_topic_edited",
                      "hermes_config", "hermes_reference"))


def _profile(profile: str) -> None:
    if not isinstance(profile, str) or not _PROFILE.fullmatch(profile):
        raise ValueError("Invalid Hermes profile")


def _name(value: Any) -> str | None:
    if (isinstance(value, str) and value.strip() and len(value) <= 128
            and not any(ord(char) < 32 for char in value)):
        return value
    return None


def _routes(topics: list[dict[str, Any]]) -> dict[tuple[str, str], list[str]]:
    result: dict[tuple[str, str], list[str]] = {}
    for topic in topics:
        chat, thread, key = (topic.get(field) for field in ("chat_id", "thread_id", "session_key"))
        if all(isinstance(x, str) and x for x in (chat, thread, key)):
            result.setdefault((chat, thread), []).append(key)
    return result


def _record(chat: str, thread: str, key: str, name: str, kind: str, **evidence: Any) -> dict[str, Any]:
    return {"chat_id": chat, "thread_id": thread, "session_key": key, "topic_name": name,
            "source_kind": kind, "current_name_verified": False, **evidence}


def load_topic_name_cache(
    hermes_home: str | Path, profile: str, topics: list[dict[str, Any]], *, path: str | Path | None = None
) -> list[dict[str, Any]]:
    """Validate cached labels against the current explicit routing identities.

    A reset changes a session pointer, not its topic/route identity. Removed or
    differently routed topics do not inherit a name from a stale cache record.
    Invalid caches are ignored; routing still works with honest unnamed labels.
    """
    _profile(profile)
    cache = Path(path) if path is not None else Path(hermes_home) / CACHE_FILENAME
    try:
        if cache.stat().st_size > MAX_CACHE_BYTES:
            return []
        payload = json.loads(cache.read_text())
    except (OSError, ValueError, RecursionError):
        return []
    if (not isinstance(payload, dict) or payload.get("schema_version") != 1
            or payload.get("profile") != profile or not isinstance(payload.get("names"), list)
            or len(payload["names"]) > 2_048):
        return []
    routes = _routes(topics)
    output: dict[tuple[str, str, str], dict[str, Any]] = {}
    duplicates: set[tuple[str, str, str]] = set()
    for row in payload["names"]:
        if not isinstance(row, dict):
            continue
        chat, thread, key = (row.get(field) for field in ("chat_id", "thread_id", "session_key"))
        if not all(isinstance(value, str) for value in (chat, thread, key)):
            continue
        if key not in routes.get((chat, thread), []):
            continue
        name, kind = _name(row.get("topic_name")), row.get("source_kind")
        if name is None or not isinstance(kind, str) or kind not in _SOURCES or row.get("current_name_verified") is not False:
            continue
        observed = row.get("observed_at")
        if observed is not None and (not isinstance(observed, (int, float)) or isinstance(observed, bool)
                                     or not math.isfinite(observed) or observed < 0):
            continue
        identity = (chat, thread, key)
        if identity in output:
            duplicates.add(identity)
            continue
        metadata: dict[str, Any] = {"observed_at": observed}
        message = row.get("source_message_id")
        if isinstance(message, int) and not isinstance(message, bool) and message > 0:
            metadata["source_message_id"] = message
        reference = row.get("source_reference")
        if isinstance(reference, str) and len(reference) <= 512:
            metadata["source_reference"] = reference
        output[identity] = _record(chat, thread, key, name, kind, **metadata)
    return [row for identity, row in output.items() if identity not in duplicates]


def config_topic_names(config: Any, topics: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Extract only configured topic ``name`` paired with an explicit thread ID."""
    if not isinstance(config, dict):
        return []
    platforms = config.get("platforms") or {}
    if not isinstance(platforms, dict):
        return []
    telegram = platforms.get("telegram") or {}
    if not isinstance(telegram, dict):
        return []
    extra = telegram.get("extra") or {}
    if not isinstance(extra, dict):
        return []
    routes, output = _routes(topics), []
    for source in ("group_topics", "dm_topics"):
        groups = extra.get(source) or []
        if isinstance(groups, dict):
            groups = [{"chat_id": chat, "topics": entries} for chat, entries in groups.items()]
        if not isinstance(groups, list):
            continue
        for group in groups[:2_048]:
            if not isinstance(group, dict) or not isinstance(group.get("topics"), list):
                continue
            chat = str(group.get("chat_id", ""))
            for topic in group["topics"][:2_048]:
                if not isinstance(topic, dict):
                    continue
                thread, name = str(topic.get("thread_id", "")), _name(topic.get("name"))
                if name is None:
                    continue
                for key in routes.get((chat, thread), []):
                    output.append(_record(chat, thread, key, name, "hermes_config", observed_at=None,
                                          source_reference=f"config.yaml:platforms.telegram.extra.{source}"))
    return output


def read_config_topic_names(
    hermes_home: str | Path, profile: str, topics: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    _profile(profile)
    path = Path(hermes_home) / "config.yaml"
    try:
        if path.stat().st_size > MAX_CACHE_BYTES:
            return []
        import yaml  # Hermes dependency; the metadata endpoint remains usable without it.
        config = yaml.safe_load(path.read_text())
    except (OSError, ValueError, ImportError, RecursionError):
        return []
    except Exception:
        # Includes YAML parser errors without echoing configuration or secrets.
        return []
    return config_topic_names(config, topics)


def _json_documents(text: Any) -> Iterator[Any]:
    """Decode bounded JSON documents embedded in a terminal tool's output."""
    if not isinstance(text, str) or len(text.encode("utf-8")) > MAX_RESULT_BYTES:
        return
    decoder = json.JSONDecoder()
    position, attempts = 0, 0
    while position < len(text) and attempts < 150:
        match = re.search(r"[\[{]", text[position:])
        if match is None:
            return
        position += match.start()
        attempts += 1
        try:
            value, end = decoder.raw_decode(text[position:])
        except (ValueError, RecursionError):
            position += 1
            continue
        yield value
        position += end


def _api_results(value: Any, depth: int = 0) -> Iterator[dict[str, Any]]:
    if depth > 8:
        return
    if isinstance(value, dict):
        if value.get("ok") is True and isinstance(value.get("result"), dict):
            yield value["result"]
        # Successful terminal wrappers only. Do not scrape arbitrary transcript
        # prose or failed commands for JSON-looking examples.
        if value.get("exit_code", 0) != 0:
            return
        for key in ("output", "stdout", "result", "results"):
            child = value.get(key)
            if isinstance(child, str):
                for doc in _json_documents(child):
                    yield from _api_results(doc, depth + 1)
            elif isinstance(child, (dict, list)):
                yield from _api_results(child, depth + 1)
    elif isinstance(value, list):
        for item in value[:100]:
            yield from _api_results(item, depth + 1)


def _creation_destinations(connection: sqlite3.Connection, session_id: str, call_id: str) -> set[str]:
    """Inspect existing arguments as inert text; never execute or return them."""
    chats: set[str] = set()
    if not call_id or len(call_id) > 256:
        return chats
    rows = connection.execute(
        "SELECT tool_calls FROM messages WHERE role = 'assistant' "
        "AND session_id = ? AND length(tool_calls) <= ? AND instr(tool_calls, ?) > 0 LIMIT 5",
        (session_id, MAX_RESULT_BYTES, call_id),
    )
    for (raw,) in rows:
        try:
            calls = json.loads(raw)
        except (ValueError, RecursionError):
            continue
        for call in calls if isinstance(calls, list) else []:
            if not isinstance(call, dict) or call.get("id") != call_id:
                continue
            function = call.get("function") or {}
            if not isinstance(function, dict):
                continue
            arguments = function.get("arguments")
            if isinstance(arguments, str):
                try:
                    arguments = json.loads(arguments)
                except (ValueError, RecursionError):
                    continue
            if not isinstance(arguments, dict):
                continue
            command = arguments.get("command") or arguments.get("code")
            if not isinstance(command, str) or not re.search(r"\b(?:createForumTopic|create_forum_topic)\b", command):
                continue
            chats.update(re.findall(r"\bchat_id[\"'\s:=]+(-?\d+)\b", command))
    return chats


def _topic_messages(result: dict[str, Any], depth: int = 0) -> Iterator[dict[str, Any]]:
    """A successful Bot API reply may quote the original topic service message."""
    if depth > 8:
        return
    yield result
    for field in ("reply_to_message", "pinned_message"):
        nested = result.get(field)
        if isinstance(nested, dict):
            yield from _topic_messages(nested, depth + 1)


def recover_topic_names(
    hermes_home: str | Path, profile: str, topics: list[dict[str, Any]]
) -> dict[str, Any]:
    """Explicit read-only backfill; callers own writing the returned cache.

    Recency chooses the last *observed name event* only. Topic classification and
    current session pointers always come from the supplied authoritative routes.
    ``truncated`` distinguishes a bounded partial recovery from an exhaustive one.
    """
    _profile(profile)
    routes = _routes(topics)
    database = Path(hermes_home).expanduser().resolve() / "state.db"
    connection = sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=2.0)
    output: dict[tuple[str, str, str], dict[str, Any]] = {}
    total_bytes, scanned, truncated = 0, 0, False
    try:
        connection.execute("PRAGMA query_only = ON")
        rows = connection.execute(
            "SELECT id, session_id, tool_call_id, timestamp, content FROM messages "
            "WHERE role = 'tool' AND tool_name IN ('terminal', 'execute_code') "
            "AND length(CAST(content AS BLOB)) <= ? "
            "AND (instr(content, 'message_thread_id') > 0 OR instr(content, 'forum_topic_') > 0) "
            "ORDER BY timestamp DESC, id DESC LIMIT ?", (MAX_RESULT_BYTES, MAX_RECOVERY_ROWS + 1),
        )
        for message_id, session_id, call_id, observed, content in rows:
            if scanned >= MAX_RECOVERY_ROWS:
                truncated = True
                break
            total_bytes += len(content.encode("utf-8"))
            if total_bytes > MAX_RECOVERY_BYTES:
                truncated = True
                break
            scanned += 1
            destinations: set[str] | None = None
            for document in _json_documents(content):
                for result in (message for api_result in _api_results(document)
                               for message in _topic_messages(api_result)):
                    thread = str(result.get("message_thread_id", ""))
                    name, kind, chat = _name(result.get("name")), "createForumTopic_result", None
                    if name is not None and thread:
                        if destinations is None:
                            destinations = _creation_destinations(connection, session_id, str(call_id or ""))
                        # Multiple destinations in one command are ambiguous: do
                        # not assign a response to a chat merely because IDs fit.
                        if len(destinations) == 1:
                            chat = next(iter(destinations))
                    for event_kind in ("forum_topic_created", "forum_topic_edited"):
                        event = result.get(event_kind)
                        actual_chat = result.get("chat")
                        if isinstance(event, dict) and isinstance(actual_chat, dict):
                            event_name = _name(event.get("name"))
                            if event_name is not None:
                                chat, name, kind = str(actual_chat.get("id", "")), event_name, event_kind
                    if chat is None or name is None:
                        continue
                    # A newer reply can quote an old creation service message.
                    # Its original Telegram event date, not the reply's database
                    # timestamp, orders that name against recorded rename events.
                    event_time = result.get("date") if kind != "createForumTopic_result" else None
                    observed_name = event_time if (isinstance(event_time, (int, float))
                        and not isinstance(event_time, bool) and math.isfinite(event_time)
                        and 0 < event_time <= observed) else observed
                    for key in routes.get((chat, thread), []):
                        identity = (chat, thread, key)
                        if identity not in output or observed_name > output[identity]["observed_at"]:
                            output[identity] = _record(chat, thread, key, name, kind,
                                                       observed_at=observed_name, source_message_id=message_id)
    finally:
        connection.close()
    return {"schema_version": 1, "profile": profile, "names": list(output.values()),
            "scanned_results": scanned, "truncated": truncated}


def main() -> None:
    from telegram_topics import read_telegram_topics

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hermes-home", type=Path, required=True)
    parser.add_argument("--profile", default="default")
    arguments = parser.parse_args()
    topics = read_telegram_topics(arguments.hermes_home, arguments.profile)["topics"]
    print(json.dumps(recover_topic_names(arguments.hermes_home, arguments.profile, topics)))


if __name__ == "__main__":
    main()
