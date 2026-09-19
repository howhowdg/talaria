"""Run with: python3 -m unittest discover -s scripts/tests -p 'test_telegram_topics.py'."""

from contextlib import closing
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from telegram_topics import TelegramTopicsError, read_telegram_topics


class TelegramTopicsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name).resolve()
        self.scope = str(self.home / "sessions")
        self.db = self.home / "state.db"
        with closing(sqlite3.connect(self.db)) as connection, connection:
            connection.execute("CREATE TABLE gateway_routing (scope TEXT, session_key TEXT, entry_json TEXT)")

    def route(self, thread="7", session="current", *, scope=None, profile=None,
              chat="-100123", chat_type="group", topic_name=None, user=None, **changes):
        key = f"agent:main:telegram:{chat_type}:{chat}:{thread}"
        if user:
            key += f":{user}"
        entry = {
            "session_key": key, "session_id": session, "platform": "telegram",
            "display_name": "A generated session title must never name a topic",
            "origin": {
                "platform": "telegram", "chat_id": chat, "thread_id": thread,
                "chat_type": chat_type, "chat_name": "My group", "chat_topic": topic_name,
                "profile": profile,
            },
        }
        entry.update(changes)
        self.insert(key, json.dumps(entry), scope=scope)
        return key

    def insert(self, key, raw, scope=None):
        with closing(sqlite3.connect(self.db)) as connection, connection:
            connection.execute("INSERT INTO gateway_routing VALUES (?, ?, ?)",
                               (self.scope if scope is None else scope, key, raw))

    def test_current_scope_wins_over_stale_imported_host_scope(self):
        self.route("1", "historical", scope="/old-host/.hermes/sessions")
        self.route("1", "current")
        result = read_telegram_topics(self.home)
        self.assertEqual(result["schema_version"], 1)
        self.assertEqual(result["profile"], "default")
        self.assertEqual(len(result["topics"]), 1)
        self.assertEqual(result["topics"][0]["current_session_id"], "current")
        self.assertEqual(result["topics"][0]["topic_name"], "General")

    def test_never_falls_back_when_current_scope_is_empty(self):
        self.route(scope="/old-host/.hermes/sessions")
        self.assertEqual(read_telegram_topics(self.home)["topics"], [])

    def test_reset_follows_pointer_not_historical_recency(self):
        key = self.route(session="old")
        with closing(sqlite3.connect(self.db)) as connection, connection:
            raw = connection.execute("SELECT entry_json FROM gateway_routing").fetchone()[0]
            entry = json.loads(raw)
            entry.update(session_id="new-reset", updated_at="1900-01-01")
            connection.execute("UPDATE gateway_routing SET entry_json = ? WHERE session_key = ?",
                               (json.dumps(entry), key))
        self.assertEqual(read_telegram_topics(self.home)["topics"][0]["current_session_id"], "new-reset")

    def test_profile_isolation_and_legacy_scoped_origin(self):
        self.route("3", profile="work")
        self.route("4", profile="other")
        self.route("5", profile=None)
        result = read_telegram_topics(self.home, "work")
        self.assertEqual({x["thread_id"] for x in result["topics"]}, {"3", "5"})
        self.assertEqual(result["profile"], "work")

    def test_profile_validation_rejects_noncanonical_or_traversal(self):
        for profile in ("../other", "Work", "", "work/other", "default ", "a" * 65, None):
            with self.subTest(profile=profile), self.assertRaises(TelegramTopicsError) as caught:
                read_telegram_topics(self.home, profile)
            self.assertEqual(caught.exception.status_code, 400)

    def test_omit_ordinary_dm_and_dm_general_lobby(self):
        self.route(None, chat="123", chat_type="dm")
        self.route("1", chat="123", chat_type="dm")
        self.route("27", chat="123", chat_type="dm", topic_name="Trip")
        topics = read_telegram_topics(self.home)["topics"]
        self.assertEqual([x["thread_id"] for x in topics], ["27"])
        self.assertEqual(topics[0]["topic_name"], "Trip")

    def test_names_are_only_explicit_metadata_or_canonical_general(self):
        self.route("10")
        self.route("1", topic_name="Renamed General")
        topics = {x["thread_id"]: x for x in read_telegram_topics(self.home)["topics"]}
        self.assertIsNone(topics["10"]["topic_name"])
        self.assertEqual(topics["1"]["topic_name"], "Renamed General")
        self.assertEqual(set(topics["10"]), {
            "chat_id", "thread_id", "session_key", "current_session_id", "chat_type",
            "chat_name", "topic_name", "binding_source",
        })

    def test_name_cache_backfills_labels_without_changing_routes(self):
        key = self.route("7", "current")
        cache = {"schema_version": 1, "profile": "default", "names": [{
            "chat_id": "-100123", "thread_id": "7", "session_key": key,
            "topic_name": "Travel ✈️", "source_kind": "forum_topic_created",
            "observed_at": 123, "current_name_verified": False,
        }]}
        path = self.home / "talaria-telegram-topic-names.json"
        path.write_text(json.dumps(cache))
        topic = read_telegram_topics(self.home)["topics"][0]
        self.assertEqual(topic["topic_name"], "Travel ✈️")
        self.assertEqual(topic["current_session_id"], "current")
        cache["profile"] = "other"
        path.write_text(json.dumps(cache))
        self.assertIsNone(read_telegram_topics(self.home)["topics"][0]["topic_name"])

    def test_configured_name_overrides_historical_name_but_not_origin(self):
        key = self.route("7", topic_name="Origin name")
        with patch("telegram_topic_names.load_topic_name_cache", return_value=[{
            "chat_id": "-100123", "thread_id": "7", "session_key": key, "topic_name": "Old name",
        }]), patch("telegram_topic_names.read_config_topic_names", return_value=[{
            "chat_id": "-100123", "thread_id": "7", "session_key": key, "topic_name": "Configured name",
        }]):
            self.assertEqual(read_telegram_topics(self.home)["topics"][0]["topic_name"], "Origin name")
            with closing(sqlite3.connect(self.db)) as connection, connection:
                entry = json.loads(connection.execute("SELECT entry_json FROM gateway_routing").fetchone()[0])
                entry["origin"]["chat_topic"] = None
                connection.execute("UPDATE gateway_routing SET entry_json = ?", (json.dumps(entry),))
            self.assertEqual(read_telegram_topics(self.home)["topics"][0]["topic_name"], "Configured name")

    def test_per_user_lanes_and_same_names_in_different_chats_stay_distinct(self):
        self.route(user="123", topic_name="Design")
        self.route(user="456", topic_name="Design")
        self.route(chat="-100456", topic_name="Design")
        topics = read_telegram_topics(self.home)["topics"]
        self.assertEqual(len(topics), 3)
        self.assertEqual(len({x["session_key"] for x in topics}), 3)

    def test_malformed_json_fails_closed(self):
        self.route()
        self.insert("broken", "{malformed}")
        with self.assertRaises(TelegramTopicsError) as caught:
            read_telegram_topics(self.home)
        self.assertEqual(caught.exception.code, "telegram_topics_invalid")

    def test_row_key_and_embedded_route_must_match(self):
        self.route(session_key="different")
        with self.assertRaises(TelegramTopicsError):
            read_telegram_topics(self.home)

    def test_missing_required_metadata_is_not_reconstructed_from_key(self):
        self.route(origin={"platform": "telegram", "thread_id": "7", "chat_type": "group"})
        with self.assertRaises(TelegramTopicsError):
            read_telegram_topics(self.home)

    def test_duplicate_route_identity_fails_closed(self):
        self.route(session="one")
        self.route(session="two")
        with self.assertRaises(TelegramTopicsError):
            read_telegram_topics(self.home)

    def test_non_telegram_routes_are_not_imported(self):
        self.insert("agent:main:discord:channel:123", json.dumps({
            "origin": {"platform": "discord", "thread_id": "1"},
        }))
        self.insert("cron", json.dumps({"platform": "cron"}))
        self.assertEqual(read_telegram_topics(self.home)["topics"], [])

    def test_missing_database_is_not_created(self):
        absent = self.home / "absent"
        with self.assertRaises(TelegramTopicsError) as caught:
            read_telegram_topics(absent)
        self.assertEqual(caught.exception.code, "telegram_topics_unavailable")
        self.assertFalse(absent.exists())

    def test_missing_table_is_unavailable_not_empty(self):
        with closing(sqlite3.connect(self.db)) as connection, connection:
            connection.execute("DROP TABLE gateway_routing")
        with self.assertRaises(TelegramTopicsError) as caught:
            read_telegram_topics(self.home)
        self.assertEqual(caught.exception.code, "telegram_topics_unavailable")

    def test_row_limit_does_not_return_partial_success(self):
        self.route("1")
        self.route("2")
        with patch("telegram_topics.MAX_ROUTING_ROWS", 1), self.assertRaises(TelegramTopicsError) as caught:
            read_telegram_topics(self.home)
        self.assertEqual(caught.exception.code, "telegram_topics_limit")

    def test_oversized_metadata_is_rejected(self):
        self.route()
        with patch("telegram_topics.MAX_ENTRY_BYTES", 8), self.assertRaises(TelegramTopicsError):
            read_telegram_topics(self.home)

    def test_reader_never_writes_database_or_creates_session_directory(self):
        self.route()
        before = self.db.read_bytes()
        before_files = sorted(x.name for x in self.home.iterdir())
        for _ in range(2):
            read_telegram_topics(self.home)
        self.assertEqual(self.db.read_bytes(), before)
        self.assertEqual(sorted(x.name for x in self.home.iterdir()), before_files)
        self.assertFalse((self.home / "sessions").exists())


if __name__ == "__main__":
    unittest.main()
