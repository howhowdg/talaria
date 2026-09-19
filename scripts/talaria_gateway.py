#!/usr/bin/env python3
"""Launch Hermes with Talaria's optional, authenticated Telegram topic reader.

Run with the Python environment that supplies Hermes and its dependencies:
    python /path/to/talaria/scripts/talaria_gateway.py -p default serve --isolated

All arguments are handled by Hermes. No installed Hermes files are changed.
The extension adds only GET /api/talaria/telegram/topics?profile=<name>.
"""

from __future__ import annotations

import importlib
import importlib.abc
import importlib.machinery
from pathlib import Path
import re
import sys
from types import ModuleType


TOPICS_PATH = "/api/talaria/telegram/topics"
_WEB_SERVER_MODULE = "hermes_cli.web_server"
_PROFILE_ID = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")


def _profile_home(web_server: ModuleType, profile: str) -> tuple[str, Path]:
    """Use Hermes' resolver, rejecting any missing-profile/default fallback."""
    from fastapi import HTTPException
    from hermes_cli import profiles

    canonical = profile.strip().lower()
    if not _PROFILE_ID.fullmatch(canonical):
        raise HTTPException(status_code=400, detail="Invalid profile")
    try:
        profiles.validate_profile_name(canonical)
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid profile") from None
    if not profiles.profile_exists(canonical):
        raise HTTPException(status_code=404, detail="Profile not found")

    # Hermes split its dashboard modules in September 2026. Both versions use
    # the same resolver; the newer version exposes it through web_deps.late.
    resolver = getattr(web_server, "_cron_profile_home", None)
    if resolver is None:
        from hermes_cli.web_deps import late

        resolver = late("_cron_profile_home", "hermes_cli.web_server_cron")
    resolved_name, home = resolver(canonical)
    expected = Path(profiles.get_profile_dir(canonical)).resolve()
    if resolved_name != canonical or Path(home).resolve() != expected:
        raise HTTPException(status_code=503, detail="Profile resolution unavailable")
    return canonical, expected


def register_routes(web_server: ModuleType | None = None) -> None:
    """Register once on the real app, leaving all auth/host/CORS rules intact."""
    from fastapi import HTTPException, Query
    from telegram_topics import TelegramTopicsError, read_telegram_topics

    server = web_server or importlib.import_module(_WEB_SERVER_MODULE)
    app = server.app
    if getattr(app.state, "talaria_telegram_topics_registered", False):
        return
    if any(getattr(route, "path", None) == TOPICS_PATH for route in app.routes):
        raise RuntimeError("The Telegram topics route is already owned by another extension")

    def telegram_topics(profile: str = Query(default="default", min_length=1, max_length=64)):
        name, home = _profile_home(server, profile)
        try:
            return read_telegram_topics(home, profile=name)
        except TelegramTopicsError as error:
            # Reader errors are stable codes, never file paths, tokens or SQL.
            raise HTTPException(status_code=error.status_code, detail=error.code) from None

    app.add_api_route(TOPICS_PATH, telegram_topics, methods=["GET"],
                      name="talaria_telegram_topics", tags=["Talaria"])
    # Hermes installs a /{full_path:path} fallback even in headless mode.
    # Put only this new literal route ahead of it; existing routes and every
    # middleware retain their order. Otherwise authenticated reads hit a 404.
    route = app.router.routes.pop()
    app.router.routes.insert(0, route)
    app.openapi_schema = None
    app.state.talaria_telegram_topics_registered = True


class _RegisterAfterLoad(importlib.abc.Loader):
    """Add the route only after Hermes has prepared and imported its server."""

    def __init__(self, original, hook):
        self.original = original
        self.hook = hook

    def create_module(self, spec):
        factory = getattr(self.original, "create_module", None)
        return factory(spec) if factory else None

    def exec_module(self, module):
        self.original.exec_module(module)
        register_routes(module)
        if self.hook in sys.meta_path:
            sys.meta_path.remove(self.hook)


class _WebServerRegistration(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path=None, target=None):
        if fullname != _WEB_SERVER_MODULE:
            return None
        spec = importlib.machinery.PathFinder.find_spec(fullname, path, target)
        if spec is None or spec.loader is None:
            raise ImportError("Hermes web server is unavailable")
        spec.loader = _RegisterAfterLoad(spec.loader, self)
        return spec


def main() -> None:
    # Importing the CLI applies -p/--profile before config-dependent modules.
    # Delay the web-server import until cmd_dashboard has prepared headless
    # mode, scoped config and plugins. An eager import here can mount the SPA
    # or freeze the wrong profile before the normal CLI setup runs.
    cli = importlib.import_module("hermes_cli.main")
    hook = _WebServerRegistration()
    if _WEB_SERVER_MODULE in sys.modules:
        register_routes(sys.modules[_WEB_SERVER_MODULE])
    else:
        sys.meta_path.insert(0, hook)
    try:
        cli.main()
    finally:
        if hook in sys.meta_path:
            sys.meta_path.remove(hook)


if __name__ == "__main__":
    main()
