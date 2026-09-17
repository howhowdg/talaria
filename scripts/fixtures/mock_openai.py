"""Small synthetic inference endpoint; it does not replace Hermes execution."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import base64
import json
import struct
import threading
import zlib


COMPLETION = "HERMES_NATIVE_SMOKE_COMPLETE: the isolated gateway and todo tool completed."
DOCUMENT_MARKER = "TALARIA_DOCUMENT_PAYLOAD_86B0"
ATTACHMENT_COMPLETION = "TALARIA_ATTACHMENTS_CONFIRMED: document content and image bytes reached inference."
MODELS = ("native-smoke-model", "native-smoke-alternate", "native-smoke-profile")


def image_fixture():
    """A valid two-pixel RGB PNG, generated without external image dependencies."""
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 1, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00\x00\x00\xff")) + chunk(b"IEND", b""))


class MockOpenAI:
    def __init__(self):
        self.lock = threading.Lock()
        self.requests = 0
        self.tool_calls = 0
        self.tool_results = 0
        self.streams = 0
        self.errors = []
        self.models = set()
        self.attachment_requests = 0
        self.profile_requests = 0
        self.model_list_requests = 0
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                if self.path.rstrip("/").endswith("/models"):
                    with owner.lock:
                        owner.model_list_requests += 1
                    self._reply({"object": "list", "data": [
                        {"id": model, "object": "model", "owned_by": "local-fixture"} for model in MODELS
                    ]})
                else:
                    self.send_error(404)

            def _reply(self, value):
                raw = json.dumps(value).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_POST(self):
                if not self.path.rstrip("/").endswith("/chat/completions"):
                    self.send_error(404)
                    return
                try:
                    request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    messages = request.get("messages", [])
                    results = [m for m in messages if m.get("role") == "tool"]
                    tools = {t.get("function", {}).get("name") for t in request.get("tools", [])}
                    model = request.get("model")
                    if model not in MODELS:
                        raise ValueError("Unexpected model reached the synthetic provider: " + str(model))
                    serialized = json.dumps(messages)
                    latest_user = next((message for message in reversed(messages) if message.get("role") == "user"), {})
                    current_prompt = json.dumps(latest_user.get("content", ""))
                    attachment_turn = "NATIVE_ATTACHMENT_CHECK" in current_prompt
                    if attachment_turn:
                        if model != "native-smoke-alternate":
                            raise ValueError("Session model switch was not applied to attachment inference")
                        if DOCUMENT_MARKER not in serialized:
                            raise ValueError("Document bytes were not expanded into the actual inference request")
                        image_urls = [part.get("image_url", {}).get("url", "")
                                      for message in messages if isinstance(message.get("content"), list)
                                      for part in message["content"] if part.get("type") == "image_url"]
                        if not any(url.startswith("data:image/png;base64,") and
                                   base64.b64decode(url.split(",", 1)[1]) == image_fixture()
                                   for url in image_urls):
                            raise ValueError("The exact uploaded PNG bytes did not reach inference")
                        with owner.lock:
                            owner.attachment_requests += 1
                    if "NATIVE_PROFILE_CHECK" in current_prompt:
                        if model != "native-smoke-profile":
                            raise ValueError("Named-profile inference used another profile's model")
                        with owner.lock:
                            owner.profile_requests += 1
                    with owner.lock:
                        owner.requests += 1
                        owner.models.add(model)
                    if results:
                        if not any("native-smoke" in str(m.get("content")) for m in results):
                            raise ValueError("The real todo result did not contain the fixture task")
                        with owner.lock:
                            owner.tool_results += 1
                        message = {"role": "assistant", "content": ATTACHMENT_COMPLETION if attachment_turn else COMPLETION}
                        finish = "stop"
                    else:
                        if "todo_list" not in tools:
                            raise ValueError("Hermes did not advertise the pinned todo_list tool")
                        message = {"role": "assistant", "content": None, "tool_calls": [{
                            "id": "call_native_smoke", "type": "function", "function": {
                                "name": "todo_list", "arguments": json.dumps({"todos": [{
                                    "id": "native-smoke", "content": "Verify the native gateway smoke test",
                                    "status": "completed",
                                }]}),
                            },
                        }]}
                        finish = "tool_calls"
                        with owner.lock:
                            owner.tool_calls += 1
                    base = {"id": "chatcmpl-native-smoke", "created": 1,
                            "model": model}
                    usage = {"prompt_tokens": 20, "completion_tokens": 10, "total_tokens": 30}
                    if not request.get("stream"):
                        self._reply({**base, "object": "chat.completion", "choices": [{
                            "index": 0, "message": message, "finish_reason": finish,
                        }], "usage": usage})
                        return
                    with owner.lock:
                        owner.streams += 1
                    deltas = [{"role": "assistant", "reasoning_content": "Checking the local fixture. "}]
                    if finish == "tool_calls":
                        for index, tool in enumerate(message["tool_calls"]):
                            deltas.append({"tool_calls": [{"index": index, **tool}]})
                    else:
                        content = message["content"]
                        midpoint = len(content) // 2
                        deltas.extend([{"content": content[:midpoint]}, {"content": content[midpoint:]}])
                    chunks = [{**base, "object": "chat.completion.chunk", "choices": [{
                        "index": 0, "delta": delta, "finish_reason": None,
                    }]} for delta in deltas]
                    chunks.append({**base, "object": "chat.completion.chunk", "choices": [{
                        "index": 0, "delta": {}, "finish_reason": finish,
                    }], "usage": usage})
                    payload = "".join("data: " + json.dumps(chunk) + "\n\n" for chunk in chunks)
                    raw = (payload + "data: [DONE]\n\n").encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Content-Length", str(len(raw)))
                    self.end_headers()
                    self.wfile.write(raw)
                except Exception as exc:
                    with owner.lock:
                        owner.errors.append(str(exc))
                    self.send_error(500)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_port}/v1"

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def summary(self):
        with self.lock:
            return {"inference_requests": self.requests, "tool_calls": self.tool_calls,
                    "tool_results": self.tool_results, "streams": self.streams,
                    "models": sorted(self.models), "model_list_requests": self.model_list_requests,
                    "attachment_requests": self.attachment_requests, "profile_requests": self.profile_requests,
                    "fixture_errors": list(self.errors)}
