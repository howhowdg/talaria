"""Actual Hermes REST contracts, entirely inside a disposable home.

PYTHONPATH=/path/to/hermes /path/to/hermes/venv/bin/python \
    -m unittest discover -s scripts/tests -p test_channel_mirroring_contract.py

No network listener, provider, bot, existing profile, or existing credential is used.
Run separately from other real-Hermes tests: upstream caches paths on import.
"""
import asyncio
import importlib.util
import os
from pathlib import Path
import secrets
import tempfile
import unittest
from unittest.mock import patch

HAS_HERMES = all(importlib.util.find_spec(name) is not None
                 for name in ("hermes_cli", "fastapi", "httpx"))


@unittest.skipUnless(HAS_HERMES, "Requires Hermes, FastAPI, and httpx")
class ChannelMirroringContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = tempfile.TemporaryDirectory(prefix="talaria-channel-contract-")
        cls.addClassCleanup(cls.root.cleanup)
        cls.home = Path(cls.root.name) / ".hermes"
        cls.token = secrets.token_hex(32)
        cls.environment = patch.dict(os.environ, {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": cls.root.name,
            "HERMES_HOME": str(cls.home), "HERMES_SERVE_HEADLESS": "1",
            "HERMES_MANAGED_DIR": str(Path(cls.root.name) / "managed"),
            "HERMES_SHARED_AUTH_DIR": str(Path(cls.root.name) / "shared-auth"),
            "HERMES_DASHBOARD_SESSION_TOKEN": cls.token,
            "PYTHONDONTWRITEBYTECODE": "1", "HERMES_DISABLE_LAZY_INSTALLS": "1",
        }, clear=True)
        cls.environment.start()
        cls.addClassCleanup(cls.environment.stop)
        from hermes_state import SessionDB
        for profile in ("default", "work"):
            home = cls.home if profile == "default" else cls.home / "profiles" / profile
            home.mkdir(parents=True, exist_ok=True)
            (home / "config.yaml").write_text("model: local-test-only\n")
            db = SessionDB(home / "state.db")
            try:
                for index in range(601 if profile == "default" else 1):
                    sid = f"telegram-{index}"
                    db.create_session(sid, source="telegram", model="fixture")
                    db.append_message(sid, "user", f"channelneedle {profile} {index}")
                db.create_session("native-only", source="native", model="fixture")
                db.append_message("native-only", "user", "channelneedle native")
                db.set_session_title("telegram-0", f"{profile} title")
                for index in range(5):
                    db.append_message("telegram-0", "assistant", f"reply {index}")
                db.append_message("telegram-0", "assistant", "hidden scaffold", display_kind="hidden")
            finally:
                db.close()
        # This is an ASGI contract test, not a CLI/runtime installer test.
        # The preinstalled interpreter supplies dependencies; never repair an
        # installation or adopt a source checkout during a disposable-home run.
        with patch("hermes_cli.venv_sync.prepare_launch", return_value=None), \
             patch("pm.environments.activate_dependencies"), \
             patch("hermes_cli._early_recovery.recover_if_needed"), \
             patch("hermes_cli._early_recovery.restore_interrupted_pull", return_value=False):
            from hermes_cli import web_server
        cls.app = web_server.app

    def request(self, path, *, method="GET", authenticated=True, body=None):
        import httpx
        async def run():
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app),
                                         base_url="http://127.0.0.1") as client:
                return await client.request(method, path, json=body,
                    headers={"X-Hermes-Session-Token": self.token} if authenticated else {})
        return asyncio.run(run())

    def get(self, path):
        response = self.request(path)
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def test_authentication_and_paging(self):
        self.assertEqual(self.request("/api/sessions?profile=default", authenticated=False).status_code, 401)
        page = self.get("/api/sessions?profile=default&source=telegram&order=recent&archived=exclude&limit=100&offset=500")
        self.assertEqual(page["total"], 601)
        self.assertEqual(len(page["sessions"]), 100)
        self.assertEqual(page["offset"], 500)
        self.assertTrue(all(row["source"] == "telegram" and row["profile"] == "default" for row in page["sessions"]))
        filtered = self.get("/api/sessions?profile=default&exclude_sources=native&limit=100")
        self.assertEqual(filtered["total"], 601)
        scoped = self.get("/api/sessions?profile=work&source=telegram")
        self.assertEqual(scoped["total"], 1)

    def test_history_projection_identity_and_latest_order(self):
        base = "/api/sessions/telegram-0/messages?profile=default&include_compacted=true&order=latest&limit=3"
        latest = self.get(base + "&offset=0")
        older = self.get(base + "&offset=3")
        self.assertEqual(latest["session_id"], "telegram-0")
        self.assertEqual(latest["profile"], "default")
        self.assertEqual(latest["pagination"], {"limit": 3, "offset": 0, "order": "latest", "returned": 3})
        ids = [row["id"] for row in older["messages"] + latest["messages"]]
        self.assertTrue(all(isinstance(value, int) for value in ids))
        self.assertEqual(ids, sorted(set(ids)))
        self.assertEqual(latest["messages"][-1]["display_kind"], "hidden")
        self.assertEqual(latest["messages"][-2]["content"], "reply 4")

    def test_search_rename_profile_and_destinations(self):
        result = self.get("/api/sessions/search?profile=work&q=channelneedle&exclude_sources=native")
        self.assertEqual(len(result["results"]), 1)
        self.assertEqual(result["results"][0]["session_id"], "telegram-0")
        self.assertEqual(result["results"][0]["source"], "telegram")
        renamed = self.request("/api/sessions/telegram-0", method="PATCH", body={"title": "Work renamed", "profile": "work"})
        self.assertEqual(renamed.status_code, 200, renamed.text)
        self.assertEqual(renamed.json()["title"], "Work renamed")
        self.assertEqual(self.get("/api/sessions/telegram-0?profile=work")["title"], "Work renamed")
        self.assertEqual(self.get("/api/sessions/telegram-0?profile=default")["title"], "default title")
        platforms = self.get("/api/messaging/platforms?profile=work")["platforms"]
        self.assertIsInstance(platforms, list)
        self.assertTrue(all(not platform["configured"] and platform["home_channel"] is None for platform in platforms))


if __name__ == "__main__":
    unittest.main()
