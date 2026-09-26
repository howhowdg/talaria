#!/usr/bin/env python3
"""Exercise the native Swift transport against the pinned, real Hermes backend.

The Python installation supplies dependencies only. All Hermes source comes from
--repo, all settings/state come from a disposable home, and inference is synthetic
over loopback. No existing Hermes configuration or provider credentials are read.
Build `hermes-smoke` before running this script. See --help for overrides.
"""

import argparse
from collections import deque
import json
import os
from pathlib import Path
import queue
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

from fixtures.mock_openai import DOCUMENT_MARKER, MockOpenAI, image_fixture


WORKSPACE = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures"
BASIC_AUTH_REVISION = "9fc7f17906eab1dd81ddfdf8a1edeecac1e79940"
UI_HANDOFF = Path("/tmp/hermes-native-ui-fixture.json")


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--repo", type=Path, default=WORKSPACE / "upstream/hermes-agent")
    result.add_argument("--python", type=Path,
                        default=Path.home() / ".hermes/hermes-agent/venv/bin/python",
                        help="Existing Python with Hermes dependencies; never modified")
    result.add_argument("--smoke", type=Path, default=WORKSPACE / ".build/debug/hermes-smoke")
    result.add_argument("--timeout", type=float, default=120, help="Seconds for each startup/client phase")
    result.add_argument("--auth", choices=("token", "basic"), default="token",
                        help="Basic requires the separately reviewed auth revision; see BASIC_AUTH_REVISION")
    result.add_argument("--backend-only", action="store_true", help="Check authenticated HTTP startup only")
    result.add_argument("--native-runtime", action="store_true",
                        help="Have Swift LocalRuntimeManager launch and stop the real isolated backend")
    result.add_argument("--extended", action="store_true",
                        help="Also verify model selection, profile routing and document/image attachments")
    result.add_argument("--hold-for-ui", type=int, default=0, metavar="SECONDS",
                        help="After the smoke passes, keep the isolated gateway alive for UI testing")
    return result


def isolated_environment(root, repo, provider_url, token):
    # Deliberately do not copy os.environ: no provider keys, proxy, SSH agent or
    # earlier Hermes process/profile/auth markers can bleed into this process.
    return {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
        "HOME": str(root), "USERPROFILE": str(root),
        "HERMES_HOME": str(root / "profile"),
        "HERMES_MANAGED_DIR": str(root / "managed"),
        "HERMES_SHARED_AUTH_DIR": str(root / "shared-auth"),
        "XDG_CONFIG_HOME": str(root / "config"), "XDG_CACHE_HOME": str(root / "cache"),
        "XDG_DATA_HOME": str(root / "data"), "TMPDIR": str(root / "tmp"),
        "TERMINAL_CWD": str(root / "workspace"),
        "HERMES_DESKTOP": "1", "HERMES_PARENT_PID": str(os.getpid()),
        "HERMES_DASHBOARD_SESSION_TOKEN": token,
        "HERMES_TUI_TOOLSETS": "todo", "HERMES_NATIVE_SMOKE_LOOPBACK_ONLY": "1",
        "OPENAI_BASE_URL": provider_url, "OPENAI_API_KEY": "local-test-only",
        "PYTHONPATH": os.pathsep.join([str(FIXTURES), str(repo)]),
        "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1", "PYTHONUNBUFFERED": "1",
        "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
    }


def prepare_home(root, provider_url, *, extended=False):
    for name in ("profile", "managed", "shared-auth", "config", "cache", "data", "tmp", "workspace"):
        (root / name).mkdir()
    config = (
        "model:\n  default: native-smoke-model\n  provider: custom\n"
        f"  base_url: {provider_url}\n  api_mode: chat_completions\n"
        "memory:\n  memory_enabled: false\n  user_profile_enabled: false\n"
        "terminal:\n  env: local\n"
        "auxiliary:\n  title_generation:\n    model_upgrade_enabled: false\n"
        "mcp_servers: {}\n")
    # Expose the safe todo tool directly, independent of upstream discovery defaults.
    config += 'tools:\n  tool_search:\n    enabled: "off"\n'
    if extended:
        # Exercise native vision through the supported configuration surface.
        config += "agent:\n  image_input_mode: native\n"
        config += "model_overrides:\n  custom:\n    _default:\n      supports_vision: true\n      supports_reasoning: true\n"
        secondary = root / "profile/profiles/native-smoke-secondary"
        secondary.mkdir(parents=True)
        (secondary / "config.yaml").write_text(config.replace("default: native-smoke-model", "default: native-smoke-profile"), encoding="utf-8")
        inputs = root / "client-inputs"
        inputs.mkdir()
        (inputs / "native-smoke.txt").write_text("Document fixture proof: " + DOCUMENT_MARKER + "\n", encoding="utf-8")
        (inputs / "native-smoke.png").write_bytes(image_fixture())
    (root / "profile/config.yaml").write_text(config, encoding="utf-8")


def stop_owned(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def hold_for_ui(seconds, base, token, backend, provider, root, smoke_result):
    """Publish only this fixture's generated credential, and remove it on exit."""
    payload = {"base_url": base, "token": token, "profile": "default",
               "pid": os.getpid(), "expires_at": time.time() + seconds,
               "fixture_kind": "isolated-real-hermes-with-synthetic-inference"}
    inputs = root / "client-inputs"
    if inputs.is_dir():
        payload.update(fixture_directory=str(inputs), document_path=str(inputs / "native-smoke.txt"),
                       image_path=str(inputs / "native-smoke.png"),
                       attachment_prompt="NATIVE_ATTACHMENT_CHECK inspect the attached document and image.",
                       attachment_model="native-smoke-alternate", secondary_profile="native-smoke-secondary")
    if isinstance(smoke_result, dict):
        payload["sessions"] = smoke_result.get("sessions", {})
    request = urllib.request.Request(base + "/api/profiles/sessions?limit=20",
                                     headers={"Authorization": "Bearer " + token})
    with urllib.request.urlopen(request, timeout=15) as response:
        rows = json.load(response).get("sessions", [])
    payload["sessions"] = [{key: row.get(key) for key in ("id", "title", "profile", "model", "provider")}
                           for row in rows]
    descriptor, temporary = tempfile.mkstemp(prefix=".hermes-native-ui-", dir=UI_HANDOFF.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            os.fchmod(output.fileno(), 0o600)
            json.dump(payload, output, indent=2)
            output.write("\n")
        os.replace(temporary, UI_HANDOFF)
        print(f"UI_FIXTURE_READY: {base}; handoff={UI_HANDOFF}; lifetime={seconds}s", flush=True)
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if backend.poll() is not None:
                raise RuntimeError("Isolated backend exited while held for UI testing")
            time.sleep(min(1, max(0, deadline - time.monotonic())))
        print("UI fixture hold completed; " + json.dumps(provider.summary()), flush=True)
    finally:
        Path(temporary).unlink(missing_ok=True)
        try:
            current = json.loads(UI_HANDOFF.read_text(encoding="utf-8"))
            if current.get("pid") == os.getpid() and current.get("token") == token:
                UI_HANDOFF.unlink(missing_ok=True)
        except (OSError, ValueError):
            pass


def verify_client_result(smoke, provider, token, *, native_runtime=False, extended=False):
    print((smoke.stdout + smoke.stderr).replace(token, "[REDACTED]"), end="", flush=True)
    if smoke.returncode:
        raise RuntimeError(f"Native Swift smoke executable failed with status {smoke.returncode}")
    if native_runtime:
        result = json.loads(smoke.stdout)
        if not result.get("native_runtime") or not result.get("runtime_stopped"):
            raise RuntimeError("Rebuild hermes-smoke: it did not report native runtime launch and shutdown")
    summary = provider.summary()
    if summary["fixture_errors"] or summary["tool_calls"] < 1 or summary["tool_results"] < 1:
        raise RuntimeError("Native chat did not finish the real Hermes todo tool cycle: " + json.dumps(summary))
    if extended:
        result = json.loads(smoke.stdout)
        if result.get("extended_passed") is not True:
            raise RuntimeError("Rebuild hermes-smoke: extended client checks did not pass")
        if summary["attachment_requests"] < 1 or summary["profile_requests"] < 1:
            raise RuntimeError("Extended inference did not prove attachments and named-profile routing: " + json.dumps(summary))
        if not {"native-smoke-model", "native-smoke-alternate", "native-smoke-profile"} <= set(summary["models"]):
            raise RuntimeError("Not all fixture models reached the real inference endpoint")
    print("PASS: real Hermes agent consumed the safe todo tool result; " + json.dumps(summary), flush=True)


def verify_persisted_profile_defaults(python, root, env):
    """Check real fixture files, independent of any server-side inventory cache."""
    probe = (
        "import json,sys,yaml;from pathlib import Path;"
        "print(json.dumps([yaml.safe_load(Path(p).read_text())['model']['default'] for p in sys.argv[1:]]))"
    )
    paths = [root / "profile/config.yaml", root / "profile/profiles/native-smoke-secondary/config.yaml"]
    observed = subprocess.check_output([str(python.absolute()), "-c", probe, *map(str, paths)],
                                       cwd=root, env=env, text=True, timeout=15)
    if json.loads(observed) != ["native-smoke-model", "native-smoke-profile"]:
        raise RuntimeError("Session model mutations altered persisted profile defaults")
    print("PASS: both persisted profile model defaults remained unchanged", flush=True)


def main():
    args = parser().parse_args()
    if args.hold_for_ui < 0:
        raise RuntimeError("--hold-for-ui must be a non-negative number of seconds")
    if args.hold_for_ui and args.backend_only:
        raise RuntimeError("--hold-for-ui requires a passing full native smoke run")
    if args.native_runtime and (args.hold_for_ui or args.backend_only):
        raise RuntimeError("--native-runtime cannot be combined with --hold-for-ui or --backend-only")
    if args.auth == "basic" and (args.native_runtime or args.hold_for_ui):
        raise RuntimeError("Basic smoke uses a remote connection; --native-runtime and --hold-for-ui are token-only")
    repo = args.repo.resolve()
    if not (repo / "hermes_cli/main.py").is_file():
        raise RuntimeError("--repo must be the pinned Hermes source checkout")
    # Hermes supports a repository .env fallback. Refuse to read a checkout with
    # one, rather than silently loading an operator's real credentials.
    if (repo / ".env").exists() or (repo / ".op.env").exists():
        raise RuntimeError("Use a clean checkout without a repository .env or .op.env")
    if not args.python.is_file() or not os.access(args.python, os.X_OK):
        raise RuntimeError("Provide --python pointing to an existing Hermes Python environment")
    if not args.backend_only and not args.smoke.is_file():
        raise RuntimeError("Build the hermes-smoke Swift executable before running this integration test")
    pin = json.loads((WORKSPACE / "Contracts/pin.json").read_text(encoding="utf-8"))
    revision = subprocess.check_output(["/usr/bin/git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    expected_revision = BASIC_AUTH_REVISION if args.auth == "basic" else pin["commit"]
    if revision != expected_revision:
        raise RuntimeError("Backend checkout revision differs from the selected auth compatibility pin")
    token = secrets.token_hex(32)
    log = deque(maxlen=120)
    lines = queue.Queue()
    with tempfile.TemporaryDirectory(prefix="hermes-native-smoke-") as directory, MockOpenAI() as provider:
        root = Path(directory)
        prepare_home(root, provider.url, extended=args.extended)
        # An Xcode/SwiftPM build may replace its output during a long smoke run.
        # Execute an immutable copy so a concurrent relink cannot invalidate the
        # pages of an already-running signed macOS executable.
        client = root / "hermes-smoke"
        if not args.backend_only:
            shutil.copy2(args.smoke.resolve(), client)
        env = isolated_environment(root, repo, provider.url, token)
        if args.auth == "basic":
            # Engage the real public auth gate while keeping every listener on loopback.
            # Desktop-owned runtimes intentionally bypass that gate, so remove ownership markers.
            for name in ("HERMES_DESKTOP", "HERMES_PARENT_PID", "HERMES_DASHBOARD_SESSION_TOKEN"):
                env.pop(name, None)
            env.update(HERMES_DASHBOARD_PUBLIC_URL="https://native-smoke.invalid",
                       HERMES_DASHBOARD_BASIC_AUTH_USERNAME="native-smoke",
                       HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=token,
                       HERMES_DASHBOARD_BASIC_AUTH_SECRET=secrets.token_hex(32))
        extra_flags = ["--extended", "--fixture-directory", str(root / "client-inputs")] if args.extended else []
        workspace = root / "workspace"
        env["TERMINAL_CWD"] = str(workspace)
        if args.native_runtime:
            # Swift must generate its own gateway token and parent identity. The
            # harness supplies only the isolated config and synthetic provider.
            env.pop("HERMES_DASHBOARD_SESSION_TOKEN")
            env.pop("HERMES_PARENT_PID")
            smoke = subprocess.run([
                str(client), "--launch-python", str(args.python.absolute()),
                "--launch-home", str(root / "profile"),
                "--launch-cwd", str(workspace), "--profile", "default", *extra_flags,
            ], cwd=workspace, env=env, stdin=subprocess.DEVNULL,
                capture_output=True, text=True, encoding="utf-8", timeout=args.timeout)
            verify_client_result(smoke, provider, token, native_runtime=True, extended=args.extended)
            if args.extended:
                verify_persisted_profile_defaults(args.python, root, env)
            print(f"PASS: native manager launched real backend {revision[:12]} and stopped its HTTP listener", flush=True)
            return 0
        command = [str(args.python.absolute()), "-m", "hermes_cli.main", "--profile", "default",
                   "serve", "--host", "127.0.0.1", "--port", "0"]
        backend = subprocess.Popen(command, cwd=repo, env=env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                   encoding="utf-8", errors="replace", bufsize=1)

        def read_output():
            for line in backend.stdout:
                safe = line.replace(token, "[REDACTED]").rstrip()
                log.append(safe)
                lines.put(safe)
            lines.put(None)

        reader = threading.Thread(target=read_output, daemon=True)
        reader.start()
        try:
            deadline = time.monotonic() + args.timeout
            base = None
            while time.monotonic() < deadline:
                try:
                    line = lines.get(timeout=min(0.5, max(0.01, deadline - time.monotonic())))
                except queue.Empty:
                    continue
                if line is None:
                    raise RuntimeError(f"Real backend exited before ready (status {backend.wait()})")
                match = re.search(r"HERMES_(?:BACKEND|DASHBOARD)_READY port=(\d+)", line)
                if match:
                    base = f"http://127.0.0.1:{int(match.group(1))}"
                    break
            if base is None:
                raise RuntimeError("Real backend did not announce ready before timeout")
            headers = {} if args.auth == "basic" else {"Authorization": "Bearer " + token}
            request = urllib.request.Request(base + "/api/status", headers=headers)
            with urllib.request.urlopen(request, timeout=15) as response:
                status = json.load(response)
            if bool(status.get("auth_required")) != (args.auth == "basic"):
                raise RuntimeError("Isolated gateway did not activate the selected authentication mode")
            print(f"PASS: real backend {revision[:12]} started with expected {args.auth} authentication mode", flush=True)
            if args.backend_only:
                print("BACKEND ONLY: Swift transport, chat, tools and reconnect were not exercised", flush=True)
                return 0
            client_env = dict(env)
            if args.auth == "basic":
                client_env["HERMES_GATEWAY_USERNAME"] = "native-smoke"
                client_env["HERMES_GATEWAY_PASSWORD"] = token
                extra_flags += ["--basic"]
            else:
                client_env["HERMES_GATEWAY_TOKEN"] = token
            smoke = subprocess.run([str(client), "--url", base, "--profile", "default", *extra_flags],
                                   cwd=workspace, env=client_env, stdin=subprocess.DEVNULL,
                                   capture_output=True, text=True, encoding="utf-8", timeout=args.timeout)
            verify_client_result(smoke, provider, token, extended=args.extended)
            if args.extended:
                verify_persisted_profile_defaults(args.python, root, env)
            if args.hold_for_ui:
                hold_for_ui(args.hold_for_ui, base, token, backend, provider, root, json.loads(smoke.stdout))
            return 0
        except Exception:
            print("\nBackend diagnostic tail (temporary fixture only):", file=sys.stderr)
            print("\n".join(list(log)[-80:]), file=sys.stderr)
            print("Mock inference: " + json.dumps(provider.summary()), file=sys.stderr)
            raise
        finally:
            stop_owned(backend)
            reader.join(timeout=5)
            backend.stdout.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("Stopped the isolated smoke fixture and cleaned up its owned resources.", file=sys.stderr)
        raise SystemExit(130)
    except (RuntimeError, subprocess.TimeoutExpired) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
