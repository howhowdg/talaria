"""Metadata-only name recovery and cache validation regression tests."""

from contextlib import closing
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from telegram_topic_names import (
    CACHE_FILENAME, config_topic_names, load_topic_name_cache, recover_topic_names,
)


class TelegramTopicNamesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name).resolve()
        self.topics = [{"chat_id": "-100123", "thread_id": "7", "session_key": "route-7",
                        "current_session_id": "current"}]
        self.record = {"chat_id": "-100123", "thread_id": "7", "session_key": "route-7",
                       "topic_name": "Trip", "source_kind": "createForumTopic_result",
                       "observed_at": 1234, "source_message_id": 1, "current_name_verified": False}
        self.database = self.home / "state.db"
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, tool_name TEXT, "
                       "tool_call_id TEXT, tool_calls TEXT, timestamp REAL, content TEXT)")

    def cache(self, rows=None, profile="default"):
        (self.home / CACHE_FILENAME).write_text(json.dumps({
            "schema_version": 1, "profile": profile, "names": rows if rows is not None else [self.record],
        }))

    def tool_result(self, result, *, timestamp=100, chat="-100123", method="createForumTopic",
                    success=True, tool="terminal", exit_code=0, session="current"):
        call_id = f"call-{timestamp}"
        arguments = {"command": f"curl example.test/{method} -d 'chat_id={chat}'"}
        calls = [{"id": call_id, "function": {"name": tool, "arguments": json.dumps(arguments)}}]
        content = json.dumps({"exit_code": exit_code, "output": json.dumps({"ok": success, "result": result})})
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute("INSERT INTO messages(session_id,role,tool_calls,timestamp) VALUES (?,'assistant',?,?)",
                       (session, json.dumps(calls), timestamp - 1))
            db.execute("INSERT INTO messages(session_id,role,tool_name,tool_call_id,timestamp,content) "
                       "VALUES (?,'tool',?,?,?,?)", (session, tool, call_id, timestamp, content))

    def test_valid_cache_preserves_only_metadata_provenance(self):
        self.record["private_tool_arguments"] = "must never leave the cache"
        self.cache()
        records = load_topic_name_cache(self.home, "default", self.topics)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["topic_name"], "Trip")
        self.assertFalse(records[0]["current_name_verified"])
        self.assertNotIn("private_tool_arguments", records[0])

    def test_wrong_profile_chat_thread_or_route_cannot_supply_a_name(self):
        for field in ("chat_id", "thread_id", "session_key"):
            with self.subTest(field=field):
                self.cache([{**self.record, field: "wrong"}])
                self.assertEqual(load_topic_name_cache(self.home, "default", self.topics), [])
        self.cache(profile="other")
        self.assertEqual(load_topic_name_cache(self.home, "default", self.topics), [])

    def test_reset_pointer_keeps_same_route_label(self):
        self.cache()
        self.topics[0]["current_session_id"] = "new-reset-session"
        self.assertEqual(load_topic_name_cache(self.home, "default", self.topics)[0]["topic_name"], "Trip")

    def test_duplicates_and_malformed_names_are_not_chosen_by_recency(self):
        self.cache([self.record, {**self.record, "topic_name": "Different", "observed_at": 9999}])
        self.assertEqual(load_topic_name_cache(self.home, "default", self.topics), [])
        for extra in ({"topic_name": ""}, {"source_kind": []}, {"current_name_verified": True},
                      {"observed_at": float("nan")}, {"topic_name": "a" * 129}):
            with self.subTest(extra=extra):
                self.cache([{**self.record, **extra}])
                self.assertEqual(load_topic_name_cache(self.home, "default", self.topics), [])

    def test_missing_malformed_or_oversized_cache_is_ignored_without_write(self):
        self.assertEqual(load_topic_name_cache(self.home, "default", self.topics), [])
        self.assertFalse((self.home / CACHE_FILENAME).exists())
        (self.home / CACHE_FILENAME).write_text("not-json")
        self.assertEqual(load_topic_name_cache(self.home, "default", self.topics), [])
        self.cache()
        with patch("telegram_topic_names.MAX_CACHE_BYTES", 3):
            self.assertEqual(load_topic_name_cache(self.home, "default", self.topics), [])

    def test_config_list_and_legacy_mapping_require_explicit_ids(self):
        for group_config in ([{"chat_id": -100123, "topics": [{"thread_id": 7, "name": "Design"}]}],
                             {"-100123": [{"thread_id": 7, "name": "Design"}]}):
            config = {"platforms": {"telegram": {"extra": {"group_topics": group_config}}}}
            rows = config_topic_names(config, self.topics)
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["topic_name"], "Design")
            self.assertEqual(rows[0]["source_kind"], "hermes_config")
        config = {"platforms": {"telegram": {"extra": {"group_topics": [
            {"chat_id": -100123, "topics": [{"name": "No ID"}, {"thread_id": 8, "name": "Wrong topic"}]},
        ]}}}}
        self.assertEqual(config_topic_names(config, self.topics), [])
        self.assertEqual(config_topic_names({"platforms": []}, self.topics), [])

    def test_successful_creation_response_and_exact_destination_recover_name(self):
        self.tool_result({"message_thread_id": 7, "name": "Trip", "icon_color": 123})
        recovered = recover_topic_names(self.home, "default", self.topics)
        self.assertEqual(len(recovered["names"]), 1)
        self.assertEqual(recovered["names"][0]["source_kind"], "createForumTopic_result")
        self.assertFalse(recovered["names"][0]["current_name_verified"])

    def test_wrong_destination_failed_api_and_unrelated_tool_are_not_evidence(self):
        for change in ({"chat": "-100456"}, {"success": False}, {"tool": "read_file"},
                       {"method": "echo"}, {"exit_code": 1}):
            with self.subTest(change=change):
                with closing(sqlite3.connect(self.database)) as db, db:
                    db.execute("DELETE FROM messages")
                self.tool_result({"message_thread_id": 7, "name": "Do not import"}, **change)
                self.assertEqual(recover_topic_names(self.home, "default", self.topics)["names"], [])

    def test_service_event_supplies_exact_identity_and_rename_wins(self):
        self.tool_result({"message_thread_id": 7, "chat": {"id": -100123},
                          "forum_topic_created": {"name": "Old name"}}, method="forwardMessage", timestamp=100)
        self.tool_result({"message_thread_id": 7, "chat": {"id": -100123},
                          "forum_topic_edited": {"name": "Renamed"}}, method="forwardMessage", timestamp=200)
        row = recover_topic_names(self.home, "default", self.topics)["names"][0]
        self.assertEqual(row["topic_name"], "Renamed")
        self.assertEqual(row["source_kind"], "forum_topic_edited")
        self.assertEqual(row["observed_at"], 200)

    def test_same_tool_call_id_in_another_session_is_not_provenance(self):
        self.tool_result({"message_thread_id": 7, "name": "Trip"})
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute("UPDATE messages SET session_id = 'different-session' WHERE role = 'assistant'")
        self.assertEqual(recover_topic_names(self.home, "default", self.topics)["names"], [])

    def test_reply_to_topic_service_message_recovers_exact_source_identity(self):
        self.tool_result({"message_thread_id": 999, "chat": {"id": -100999}, "reply_to_message": {
            "message_thread_id": 7, "chat": {"id": -100123},
            "forum_topic_created": {"name": "Original topic"},
        }}, method="forwardMessage")
        row = recover_topic_names(self.home, "default", self.topics)["names"][0]
        self.assertEqual(row["chat_id"], "-100123")
        self.assertEqual(row["thread_id"], "7")
        self.assertEqual(row["topic_name"], "Original topic")

    def test_bounded_backfill_reports_partial_instead_of_inventing_coverage(self):
        self.tool_result({"message_thread_id": 7, "name": "Older"}, timestamp=100)
        self.tool_result({"message_thread_id": 7, "name": "Newer"}, timestamp=200)
        with patch("telegram_topic_names.MAX_RECOVERY_ROWS", 1):
            result = recover_topic_names(self.home, "default", self.topics)
        self.assertTrue(result["truncated"])
        self.assertEqual(result["scanned_results"], 1)
        self.assertEqual(result["names"][0]["topic_name"], "Newer")

    def test_backfill_is_read_only_and_does_not_write_cache(self):
        self.tool_result({"message_thread_id": 7, "name": "Trip"})
        before = self.database.read_bytes()
        recover_topic_names(self.home, "default", self.topics)
        self.assertEqual(self.database.read_bytes(), before)
        self.assertFalse((self.home / CACHE_FILENAME).exists())

    def test_new_reply_quoting_old_creation_does_not_undo_recorded_rename(self):
        self.tool_result({"message_thread_id": 7, "chat": {"id": -100123}, "date": 200,
                          "forum_topic_edited": {"name": "Current recorded name"}}, timestamp=200)
        self.tool_result({"message_thread_id": 7, "chat": {"id": -100123}, "date": 300,
                          "reply_to_message": {"message_thread_id": 7, "chat": {"id": -100123},
                          "date": 100, "forum_topic_created": {"name": "Old name"}}}, timestamp=300)
        result = recover_topic_names(self.home, "default", self.topics)
        self.assertEqual(result["names"][0]["topic_name"], "Current recorded name")

    def test_invalid_profile_is_rejected(self):
        for profile in ("../escape", "Other", ""):
            with self.subTest(profile=profile), self.assertRaises(ValueError):
                recover_topic_names(self.home, profile, self.topics)


if __name__ == "__main__":
    unittest.main()
