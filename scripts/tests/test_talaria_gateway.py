"""Real Hermes ASGI security/profile tests, using a disposable Hermes home.

Run with a Hermes Python environment:
  PYTHONPATH=scripts:/path/to/hermes python -m unittest discover \
      -s scripts/tests -p test_talaria_gateway.py

No server is started, no bot is contacted, and no real profile is read.
"""

import asyncio
import importlib.util
import json
import os
from pathlib import Path
import secrets
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch


HAS_HERMES = all(importlib.util.find_spec(module) is not None
                 for module in ("hermes_cli", "fastapi", "httpx"))


@unittest.skipUnless(HAS_HERMES, "Requires Hermes with FastAPI and httpx")
class TelegramGatewayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = tempfile.TemporaryDirectory(prefix="talaria-gateway-test-")
        cls.home = Path(cls.root.name).resolve() / ".hermes"
        cls.home.mkdir()
        cls.token = secrets.token_hex(32)
        cls.environment = patch.dict(os.environ, {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": cls.root.name, "HERMES_HOME": str(cls.home),
            "HERMES_MANAGED_DIR": str(Path(cls.root.name) / "managed"),
            "HERMES_SHARED_AUTH_DIR": str(Path(cls.root.name) / "shared-auth"),
            "HERMES_DASHBOARD_SESSION_TOKEN": cls.token,
            "HERMES_SERVE_HEADLESS": "1", "PYTHONDONTWRITEBYTECODE": "1",
        }, clear=True)
        cls.environment.start()
        cls.seed(cls.home, "default", "default-current")
        cls.seed(cls.home / "profiles/work", "work", "work-current")
        cls.seed(cls.home / "profiles/study", "study", "study-current")
        # The CLI applies -p before the web-server module can resolve config.
        with patch.object(sys, "argv", ["hermes", "-p", "work", "serve", "--isolated"]):
            from hermes_cli import main as cli
        cls.assert_home_after_cli = os.environ["HERMES_HOME"]
        cls.cli = cli

        # Exercise the production late-import hook, not just direct mounting.
        from talaria_gateway import _WebServerRegistration, register_routes
        cls.hook = _WebServerRegistration()
        sys.meta_path.insert(0, cls.hook)
        from hermes_cli import web_server
        cls.server = web_server
        register_routes(web_server)  # Must be harmless when called twice.

    @classmethod
    def tearDownClass(cls):
        if cls.hook in sys.meta_path:
            sys.meta_path.remove(cls.hook)
        cls.environment.stop()
        cls.root.cleanup()

    @staticmethod
    def seed(home, profile, session):
        home.mkdir(parents=True, exist_ok=True)
        (home / "config.yaml").write_text("model: local-test-only\n", encoding="utf-8")
        key = "agent:main:telegram:group:-100123:7"
        entry = {
            "session_key": key, "session_id": session, "platform": "telegram",
            "origin": {"platform": "telegram", "chat_id": "-100123", "thread_id": "7",
                       "chat_type": "group", "chat_name": "Test chat", "chat_topic": "Test topic",
                       "profile": profile},
        }
        with sqlite3.connect(home / "state.db") as db:
            db.execute("CREATE TABLE gateway_routing(scope TEXT, session_key TEXT, entry_json TEXT)")
            db.execute("INSERT INTO gateway_routing VALUES(?, ?, ?)",
                       (str((home / "sessions").resolve()), key, json.dumps(entry)))

    def request(self, query="profile=default", token=None, **kwargs):
        import httpx
        headers = {} if token is None else {"X-Hermes-Session-Token": token}

        async def run():
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=self.server.app),
                                         base_url="http://127.0.0.1") as client:
                return await client.get("/api/talaria/telegram/topics?" + query,
                                        headers=headers, **kwargs)
        return asyncio.run(run())

    def test_cli_scopes_home_before_server_import(self):
        self.assertEqual(Path(self.assert_home_after_cli).resolve(), self.home / "profiles/work")

    def test_route_is_registered_once_and_hook_removes_itself(self):
        routes = [r for r in self.server.app.routes
                  if getattr(r, "path", None) == "/api/talaria/telegram/topics"]
        self.assertEqual(len(routes), 1)
        self.assertNotIn(self.hook, sys.meta_path)

    def test_authentication_is_required(self):
        self.assertEqual(self.request().status_code, 401)
        self.assertEqual(self.request(token="incorrect").status_code, 401)
        self.assertEqual(self.request("profile=default&token=" + self.token).status_code, 401)

    def test_real_profile_resolver_isolated_a_b_a(self):
        for profile in ("work", "study", "work", "default"):
            response = self.request("profile=" + profile, token=self.token)
            self.assertEqual(response.status_code, 200, response.text)
            result = response.json()
            self.assertEqual(result["profile"], profile)
            self.assertEqual(result["topics"][0]["current_session_id"], profile + "-current")
            self.assertEqual(result["topics"][0]["binding_source"], "gateway_routing")

    def test_missing_and_traversal_profiles_do_not_fall_back(self):
        self.assertEqual(self.request("profile=missing", token=self.token).status_code, 404)
        for profile in ("..", "../work", "/tmp", "work%2F..%2F.."):
            self.assertEqual(self.request("profile=" + profile, token=self.token).status_code, 400)
        self.assertFalse((self.home / "profiles/missing").exists())

    def test_errors_do_not_expose_profile_paths(self):
        empty = self.home / "profiles/empty"
        empty.mkdir(exist_ok=True)
        (empty / "config.yaml").write_text("model: local-test-only\n", encoding="utf-8")
        response = self.request("profile=empty", token=self.token)
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json(), {"detail": "telegram_topics_unavailable"})
        self.assertFalse((empty / "state.db").exists())


if __name__ == "__main__":
    unittest.main()
