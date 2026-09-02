"""Loopback-only /models fixture. Never records a credential value."""

import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    control_path: Path
    result_path: Path
    records: list[dict] = []

    def do_GET(self) -> None:  # noqa: N802
        self.records.append(
            {
                "method": self.command,
                "path": self.path,
                "authorization_present": bool(self.headers.get("Authorization")),
                "authorization_matches_dummy": self.headers.get("Authorization")
                == "Bearer cst-model-catalog-dummy",
            }
        )
        self.result_path.write_text(json.dumps(self.records), encoding="utf-8")
        control = json.loads(self.control_path.read_text(encoding="utf-8-sig"))
        mode = control.get("mode", "success")
        payload = {
            "object": "list",
            "data": [
                {"id": "fixture-text-v1", "object": "model", "owned_by": "fixture"},
                {"id": "fixture-future-v2", "object": "model", "owned_by": "fixture"},
            ],
        }
        status = 200
        if mode == "redirect" and self.path != "/redirect-target/models":
            self.send_response(302)
            # Different hostname deliberately tests refusal to forward credentials.
            self.send_header(
                "Location",
                f"http://localhost:{self.server.server_address[1]}/redirect-target/models",
            )
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if mode == "missing-data":
            payload = {"object": "list", "message": "not a model list"}
        elif mode == "invalid-id":
            payload = {"data": [{"id": "fixture-text-v1"}, {"id": {"wrong": "type"}}]}
        elif mode == "empty-data":
            payload = {"data": []}
        elif mode == "server-error":
            status = 503
            payload = {"error": {"message": "server echoed cst-model-catalog-dummy"}}
        elif mode == "too-many-models":
            payload = {"data": [{"id": f"fixture-model-{i}"} for i in range(501)]}
        elif mode == "oversized-response":
            payload = {"data": [{"id": "fixture-model"}], "padding": "x" * 1048577}
        elif mode == "duplicate-id":
            payload = {"data": [{"id": "fixture-text-v1"}, {"id": "fixture-text-v1"}]}
        elif mode == "custom-models":
            payload = {"data": [{"id": value} for value in control["models"]]}
        response = (
            b"this is not json"
            if mode == "malformed-json"
            else json.dumps(payload).encode("utf-8")
        )
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        try:
            self.wfile.write(response)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            # A bounded client is expected to abort oversized responses early.
            pass

    def log_message(self, _format: str, *_args: object) -> None:
        return


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready", required=True)
    parser.add_argument("--result", required=True)
    parser.add_argument("--control", required=True)
    args = parser.parse_args()
    Handler.result_path = Path(args.result)
    Handler.control_path = Path(args.control)
    server = HTTPServer(("127.0.0.1", 0), Handler)
    Path(args.ready).write_text(
        json.dumps({"port": server.server_address[1]}), encoding="utf-8"
    )
    server.serve_forever(poll_interval=0.1)


if __name__ == "__main__":
    main()
