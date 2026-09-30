"""Stand-in for the Hermes API server (chat completions SSE) used by container tests.

Echoes the caller's words back so the audio round trip can be verified.
"""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KEY = sys.argv[1]
LOG = sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(LOG, "a") as log:
            log.write(
                json.dumps(
                    {
                        "auth_ok": self.headers.get("Authorization") == f"Bearer {KEY}",
                        "session": self.headers.get("X-Hermes-Session-Id"),
                        "stream": body.get("stream"),
                        "roles": [m["role"] for m in body["messages"]],
                    }
                )
                + "\n"
            )
        if self.headers.get("Authorization") != f"Bearer {KEY}":
            self.send_response(401)
            self.end_headers()
            return
        content = body["messages"][-1]["content"]
        if isinstance(content, list):  # "look at this": text plus image_url parts
            images = sum(part.get("type") == "image_url" for part in content)
            content = " ".join(part.get("text", "") for part in content if part.get("type") == "text")
            content += f" (with {images} image{'s' if images != 1 else ''})"
        question = content.replace("(I interrupted you.) ", "")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        time.sleep(0.4)
        if "search" in str(question).lower():  # tool progress, as Hermes' API server streams it
            for status in ("running", "completed"):
                event = {"tool": "web_search", "label": "fake query", "toolCallId": "call_1", "status": status}
                self.wfile.write(f"event: hermes.tool.progress\ndata: {json.dumps(event)}\n\n".encode())
                self.wfile.flush()
                time.sleep(1.5)
        for word in f"You asked: {question} That is all for now.".split(" "):
            chunk = {"id": "chatcmpl-test", "choices": [{"delta": {"content": word + " "}}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            self.wfile.flush()
            time.sleep(0.03)
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *args) -> None:
        pass


ThreadingHTTPServer(("127.0.0.1", 8642), Handler).serve_forever()
