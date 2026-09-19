#!/usr/bin/env python3
"""Synthetic UI-only gateway for Talaria's iPhone design verification.

This is not Hermes and does not establish backend integration coverage. All
conversations, tools, approvals, files and schedules are fictional in-memory
records. Commands and approvals never execute. No provider or user files are
accessed; only the private, temporary connection handoff is written.

Run with a Python environment containing fastapi and uvicorn:
    python scripts/fixtures/mobile_design_gateway.py

The generated token is written to /tmp/talaria-ios-design-fixture.json (0600),
never logged. The loopback server expires after at most 30 minutes. SIGINT/SIGTERM
also stop it and remove only its own handoff file.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import copy
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import time
from datetime import datetime, timedelta

from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
import uvicorn


FIXTURE_KIND = "synthetic-mobile-design-only"
MODEL = "design-fixture-model"
PROFILE = "default"
HOME = "design-home"
CHAT = "design-lisbon-weekend"
APPROVAL = "design-downloads-review"


def message(role: str, text: str, **extra):
    return {"role": role, "text": text, **extra}


def tool(name: str, args: dict, result: dict):
    return message("tool", json.dumps(result), name=name, args=args)


class DesignFixture:
    def __init__(self):
        self.token = secrets.token_urlsafe(32)
        self.sockets: set[WebSocket] = set()
        self.tasks: dict[str, asyncio.Task] = {}
        self.sequence = 0
        self.approval_pending = True
        now = datetime.now()
        morning = now.replace(hour=8, minute=30, second=0, microsecond=0)
        if morning > now:
            morning = now - timedelta(hours=1)
        self.now = now.timestamp()
        self.morning = morning.timestamp()
        self.sessions = self.seed_sessions()
        self.automations = {
            "design-morning": {"id": "design-morning", "name": "Morning Brief", "profile": PROFILE,
                "enabled": True, "schedule_display": "Daily · 7:00", "last_run_at": self.morning,
                "next_run_at": self.morning + 86400, "prompt_preview": "A short look at your day: calendar, messages and anything that needs your attention."},
            "design-projects": {"id": "design-projects", "name": "Weekly Review", "profile": PROFILE,
                "enabled": False, "schedule_display": "Friday · 17:00", "prompt_preview": "Review the week and prepare the next steps."},
            "design-reading": {"id": "design-reading", "name": "Weekend Reading", "profile": PROFILE,
                "enabled": True, "schedule_display": "Friday · 16:00", "next_run_at": self.now + 86400,
                "prompt_preview": "A few things worth a longer read."},
        }
        self.run_owners = {"design-inbox-run": "design-morning", "design-project-run": "design-projects",
                           "design-reading-run": "design-reading", "design-empty-run": "design-morning"}
        self.app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
        self.install_routes()

    def seed_sessions(self):
        itinerary = "# A weekend in Lisbon\n\n## Friday\nArrive, settle in and find dinner in Príncipe Real.\n\n## Saturday\nTram through Graça, then a quiet afternoon by the river.\n\n## Sunday\nCoffee, a walk and time to wander."
        records = [
            (HOME, "General chat with Hermes", "/Design Fixture/Personal", self.now - 7200, [
                message("user", "Ana and I want Lisbon the second weekend of October. Take it on properly — flights, stay, under €900 for two."),
                message("assistant", "I’ve opened **Plan a trip** so we can keep the travel details together. Your Home stays here."),
                message("user", "What did I tell the landlord about the boiler?"),
                message("assistant", "Repair by the 20th, deposit talk after. That’s in an older conversation — pull it in here?"),
            ]),
            (CHAT, "Plan a trip", "/Design Fixture/Travel", self.now - 900, [
                message("user", "Plan a long weekend in Lisbon. Keep Friday light, and find somewhere walkable to stay."),
                message("assistant", "Friday looks clear. I’m pulling together flights, a place to stay and a slower Saturday.", reasoning="I’ll keep arrival day flexible and group the weekend around walkable neighborhoods."),
                tool("Calendar", {"query": "Friday through Sunday"}, {"available": True}),
                tool("Flights", {"query": "Lisbon · Friday morning"}, {"options": 3}),
                tool("Stay", {"query": "Príncipe Real · walkable"}, {"options": 4}),
                tool("write_file", {"path": "/Design Fixture/Travel/itinerary.md", "content": itinerary}, {"success": True, "bytes_written": len(itinerary)}),
                message("assistant", "I’d stay near **Príncipe Real**: good cafés, easy walks and a little breathing room. Your first draft is ready in `itinerary.md`."),
            ]),
            (APPROVAL, "Build Talaria", "/Design Fixture/Downloads", self.now - 1800, [
                message("user", "Check the session list source and prepare the change."),
                message("assistant", "The source field now stays attached to each session. The regression checks pass. May I record this change?"),
            ]),
            ("design-inbox-run", "Your morning inbox", "/Design Fixture/Personal", self.morning, [
                message("user", "Review the synthetic inbox and prepare a morning summary."),
                tool("calendar", {"range": "today"}, {"meetings": 3}),
                message("assistant", "## Friday, 18 September\n\n- **Three meetings** today: planning at 10, lunch with Maya at 12:30, and a review at 3.\n- The landlord confirmed the **boiler repair for Monday**. No reply needed.\n- Your Lisbon planning is ready to pick up in **Plan a trip**."),
            ]),
            ("design-project-run", "Project folder review", "/Design Fixture/Work", self.morning - 1200, [
                message("user", "Review the synthetic project folders."),
                message("system", "Calendar connection timed out. This run did not complete."),
            ]),
            ("design-reading-run", "A little weekend reading", "/Design Fixture/Personal", self.now - 86400, [
                message("user", "Prepare a short synthetic reading list."),
                message("assistant", "Five pieces saved for the weekend: architecture, a new trail, and a thoughtful essay on making time for creative work."),
            ]),
            ("design-empty-run", "Morning Brief · earlier", "/Design Fixture/Personal", self.now - 86400, [
                message("user", "Prepare the synthetic morning brief."),
                message("assistant", "[SILENT]"),
            ]),
            ("design-landlord", "Rewrite the landlord email about the deposit and the boiler", "/Design Fixture/Personal", self.now - 3600, [
                message("user", "Keep the repair request friendly and brief."),
                message("assistant", "Here’s a short draft of your repair request."),
            ]),
            ("design-bikes", "Compare three e-bikes", "/Design Fixture/Personal", self.now - 3800, [
                message("user", "Compare these three e-bikes for a short commute."),
                message("assistant", "Let’s compare weight, battery range and comfort for your route."),
            ]),
            ("design-sunday-notes", "Sunday notes", "/Design Fixture/Personal", self.now - 90000, [
                message("user", "Keep a few ideas for Sunday."),
                message("assistant", "A long walk, a good coffee and an afternoon with no plans. Your notes are here whenever you’re ready."),
            ]),
        ]
        return {sid: {"id": sid, "runtime": "runtime-" + sid, "title": title,
                      "cwd": cwd, "started_at": started, "messages": rows,
                      "running": sid in (CHAT, APPROVAL), "source": "telegram" if sid == CHAT else "cron" if sid.endswith("-run") else "native"}
                for sid, title, cwd, started, rows in records}

    def authenticated(self, supplied: str | None):
        return isinstance(supplied, str) and secrets.compare_digest(supplied, self.token)

    def check_http(self, request: Request):
        if not self.authenticated(request.headers.get("x-hermes-session-token")):
            raise HTTPException(401, "A visual fixture token is required")
        if request.query_params.get("profile", PROFILE) != PROFILE:
            raise HTTPException(404, "The visual fixture only has a default profile")

    def find_session(self, sid):
        return next((record for record in self.sessions.values()
                     if sid in (record["id"], record["runtime"])), None)

    def approval(self):
        return {"jsonrpc": "2.0", "id": "design-approval-1", "method": "approval", "params": {
            "session_id": self.sessions[APPROVAL]["runtime"], "gateway_session_id": APPROVAL,
            "profile": PROFILE, "description": "Allow a command?", "tool_name": "terminal",
            "command": "git commit -am \"Fix session list source\"",
            "choices": ["once", "session", "always", "deny"], "allow_session": True,
            "allow_permanent": True, "smart_denied": False,
        }}

    def snapshot(self, record):
        rows = copy.deepcopy(record["messages"])
        for index, row in enumerate(rows):
            row["row_id"] = index + 1
        result = {"session_id": record["runtime"], "stored_session_id": record["id"],
                "profile": PROFILE, "running": record["running"], "messages": rows,
                "info": {"title": record["title"], "model": MODEL, "cwd": record["cwd"], "source": record.get("source", "native")},
                "open_requests": [self.approval()] if record["id"] == APPROVAL and self.approval_pending else []}
        if record["id"] == CHAT and record["running"]:
            result["inflight"] = {"assistant": rows[-1]["text"]}
        return result

    async def event(self, kind, record=None, payload=None):
        self.sequence += 1
        params = {"type": kind, "seq": self.sequence, "payload": payload or {}}
        if record:
            params["session_id"] = record["runtime"]
        frame = {"jsonrpc": "2.0", "method": "event", "params": params}
        for client in tuple(self.sockets):
            try:
                await client.send_json(frame)
            except (RuntimeError, WebSocketDisconnect):
                self.sockets.discard(client)

    async def simulated_reply(self, record):
        try:
            await asyncio.sleep(0.15)
            await self.event("message.start", record)
            reply = "Got it. This is a synthetic design fixture, so your message stays in this temporary preview. No files or external services were changed."
            for part in [reply[:31], reply[31:88], reply[88:]]:
                await asyncio.sleep(0.3)
                await self.event("message.delta", record, {"text": part})
            record["messages"].append(message("assistant", reply))
            record["running"] = False
            await self.event("message.complete", record, {"text": reply})
        finally:
            self.tasks.pop(record["id"], None)

    async def respond_to_approval(self, frame):
        if frame.get("id") != "design-approval-1" or not self.approval_pending:
            return
        choice = frame.get("result", {}).get("choice", "deny")
        if choice not in ("once", "session", "always", "deny"):
            return
        self.approval_pending = False
        record = self.sessions[APPROVAL]
        record["running"] = False
        text = "Request declined. No files were changed." if choice == "deny" else "Approval received for this synthetic preview. No files were moved."
        record["messages"].append(message("assistant", text))
        await self.event("request.cancel", record, {"id": "design-approval-1"})
        await self.event("message.complete", record, {"text": text})

    async def rpc(self, method, params):
        if params.get("profile", PROFILE) != PROFILE:
            raise ValueError("The visual fixture only has a default profile")
        if method in ("client.capabilities", "gateway.ping"):
            return {"ok": True}
        if method == "session.list":
            return {"sessions": [{"id": row["id"], "title": row["title"], "started_at": row["started_at"],
                                   "preview": next((m["text"] for m in row["messages"] if m["role"] == "user"), ""),
                                   "message_count": len(row["messages"]), "source": row.get("source", "native")}
                                  for row in sorted(self.sessions.values(), key=lambda r: r["started_at"], reverse=True)]}
        if method == "session.create":
            sid = "design-new-" + secrets.token_hex(4)
            self.sessions[sid] = {"id": sid, "runtime": "runtime-" + sid, "title": "New conversation",
                                  "cwd": "/Design Fixture/Personal", "started_at": time.time(), "messages": [], "running": False}
            return self.snapshot(self.sessions[sid])
        if method in ("session.resume", "session.activate"):
            record = self.find_session(params.get("session_id"))
            if not record:
                raise ValueError("Synthetic session was not found")
            return self.snapshot(record)
        if method == "model.options":
            return {"model": MODEL, "provider": "design-fixture", "providers": [{
                "slug": "design-fixture", "name": "Synthetic visual fixture", "models": [MODEL],
                "authenticated": True, "capabilities": {MODEL: {"fast": False, "reasoning": True, "can_disable_reasoning": True}}}]}
        if method == "profiles.list":
            return {"profiles": [{"name": PROFILE, "display_name": "Personal", "is_default": True,
                                  "description": "Synthetic visual fixture", "model": MODEL, "provider": "design-fixture"}]}
        if method == "config.get":
            return {"key": params.get("key"), "value": "high" if params.get("key") == "reasoning" else "off"}
        if method == "config.set":
            return {"value": str(params.get("value", "")), "scope": "session", "deferred": False}
        if method == "skills.manage" and params.get("action") == "list":
            return {"skills": {"Everyday": ["calendar", "inbox-review", "travel-planning"], "Work": ["writing", "project-notes"]}}
        if method == "projects.list":
            return {"projects": [{"id": "design-travel", "name": "Travel", "primary_path": "/Design Fixture/Travel",
                                  "folders": [{"path": "/Design Fixture/Travel"}]}]}
        record = self.find_session(params.get("session_id"))
        if method == "prompt.submit" and record:
            if record["running"]:
                raise ValueError("Stop the synthetic turn before sending another message")
            text = str(params.get("text", ""))[:16000]
            record["messages"].append(message("user", text))
            record["running"] = True
            if record["title"] == "New conversation":
                record["title"] = text[:60] or "New conversation"
                await self.event("session.title", record, {"title": record["title"]})
            self.tasks[record["id"]] = asyncio.create_task(self.simulated_reply(record))
            return {"status": "streaming", "session_id": record["runtime"]}
        if method == "session.interrupt" and record:
            task = self.tasks.pop(record["id"], None)
            if task:
                task.cancel()
            record["running"] = False
            if record["id"] == APPROVAL and self.approval_pending:
                self.approval_pending = False
                await self.event("request.cancel", record, {"id": "design-approval-1"})
            await self.event("message.complete", record, {"status": "interrupted"})
            return {"interrupted": True}
        if method in ("image.list", "image.clear"):
            return {"images": [], "count": 0}
        raise ValueError("This UI-only fixture does not implement " + str(method))

    def install_routes(self):
        @self.app.get("/api/status")
        async def status(request: Request):
            self.check_http(request)
            return {"auth_required": False, "fixture_kind": FIXTURE_KIND, "profile": PROFILE}

        @self.app.get("/api/cron/jobs")
        async def schedules(request: Request):
            self.check_http(request)
            return list(self.automations.values())

        @self.app.get("/api/cron/jobs/{job_id}/runs")
        async def runs(job_id: str, request: Request):
            self.check_http(request)
            if job_id not in self.automations:
                raise HTTPException(404, "Synthetic automation was not found")
            result = []
            for sid, owner in self.run_owners.items():
                if owner != job_id:
                    continue
                record = self.sessions[sid]
                reason = "cron_failed" if sid == "design-project-run" else "cron_incomplete_no_output" if sid == "design-empty-run" else "cron_complete"
                result.append({"id": sid, "profile": PROFILE, "title": record["title"],
                    "started_at": record["started_at"], "is_active": record["running"],
                    "ended_at": None if record["running"] else record["started_at"] + 41,
                    "end_reason": None if record["running"] else reason})
            return {"runs": sorted(result, key=lambda row: row["started_at"], reverse=True)}

        @self.app.post("/api/cron/jobs/{job_id}/{action}")
        async def automation_action(job_id: str, action: str, request: Request):
            self.check_http(request)
            if job_id not in self.automations:
                raise HTTPException(404, "Synthetic automation was not found")
            if action in ("pause", "resume"):
                self.automations[job_id]["enabled"] = action == "resume"
                return {"ok": True}
            if action == "trigger":
                sid = "design-rerun-" + secrets.token_hex(4)
                self.sessions[sid] = {"id": sid, "runtime": "runtime-" + sid,
                    "title": self.automations[job_id]["name"], "cwd": "/Design Fixture/Personal",
                    "started_at": time.time(), "messages": [message("user", "Synthetic automation run")],
                    "running": True, "source": "cron"}
                self.run_owners[sid] = job_id
                self.tasks[sid] = asyncio.create_task(self.simulated_reply(self.sessions[sid]))
                return {"ok": True}
            raise HTTPException(404, "Synthetic automation action was not found")

        @self.app.get("/api/sessions/{sid}/messages")
        async def history(sid: str, request: Request):
            self.check_http(request)
            record = self.find_session(sid)
            if not record:
                raise HTTPException(404, "Synthetic session was not found")
            return {"session_id": record["id"], "profile": PROFILE,
                    "messages": [{**row, "content": row["text"]} for row in record["messages"][-40:]]}

        @self.app.websocket("/api/ws")
        async def websocket(client: WebSocket):
            if not self.authenticated(client.query_params.get("token")) or client.query_params.get("profile", PROFILE) != PROFILE:
                await client.close(code=1008)
                return
            await client.accept()
            self.sockets.add(client)
            await client.send_json({"jsonrpc": "2.0", "method": "event", "params": {
                "type": "gateway.ready", "payload": {"heartbeat": True, "fixture_kind": FIXTURE_KIND}}})
            try:
                while True:
                    frame = await client.receive_json()
                    if not isinstance(frame, dict) or frame.get("jsonrpc") != "2.0":
                        await client.close(code=1003)
                        break
                    if "method" not in frame:
                        await self.respond_to_approval(frame)
                        continue
                    try:
                        params = frame.get("params", {})
                        if not isinstance(params, dict):
                            raise ValueError("Expected object params")
                        result = await self.rpc(frame["method"], params)
                        await client.send_json({"jsonrpc": "2.0", "id": frame.get("id"), "result": result})
                    except ValueError as error:
                        await client.send_json({"jsonrpc": "2.0", "id": frame.get("id"), "error": {
                            "code": 4007 if str(error) == "Synthetic session was not found" else -32602, "message": str(error)}})
            except WebSocketDisconnect:
                pass
            finally:
                self.sockets.discard(client)


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lifetime", type=int, default=1800, help="Seconds to live, from 10 through 1800")
    parser.add_argument("--handoff", type=Path, default=Path("/tmp/talaria-ios-design-fixture.json"))
    args = parser.parse_args()
    if not 10 <= args.lifetime <= 1800:
        parser.error("--lifetime must be between 10 and 1800 seconds")
    fixture = DesignFixture()
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    listener.listen(128)
    port = listener.getsockname()[1]
    handoff = {"base_url": f"http://127.0.0.1:{port}", "token": fixture.token, "profile": PROFILE,
               "pid": os.getpid(), "fixture_kind": FIXTURE_KIND, "expires_at": time.time() + args.lifetime,
               "session_ids": {"home": HOME, "chat": CHAT, "approval": APPROVAL, "inbox": "design-inbox-run"}}
    # Exclusive creation refuses an existing or symlinked handoff from another run.
    fd = os.open(args.handoff, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as output:
        json.dump(handoff, output)
    server = uvicorn.Server(uvicorn.Config(fixture.app, log_level="warning", access_log=False,
                                          ws_max_size=65536, timeout_graceful_shutdown=5))
    # Own signal handling so both signal and expiry take the same cleanup path.
    server.capture_signals = contextlib.nullcontext
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(signum, lambda: setattr(server, "should_exit", True))
    expiry = loop.call_later(args.lifetime, lambda: setattr(server, "should_exit", True))
    print(f"Synthetic visual fixture listening on 127.0.0.1:{port}; private handoff: {args.handoff}", flush=True)
    print("UI verification only. No real agent, commands, provider calls or user files.", flush=True)
    try:
        await server.serve(sockets=[listener])
    finally:
        expiry.cancel()
        for task in fixture.tasks.values():
            task.cancel()
        listener.close()
        try:
            current = json.loads(args.handoff.read_text())
            if current.get("pid") == os.getpid() and current.get("token") == fixture.token:
                args.handoff.unlink()
        except (FileNotFoundError, ValueError):
            pass
        print("Synthetic visual fixture stopped; owned handoff removed.", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
