import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    result_path: Path
    return_success: bool = False

    def _record(self, body: bytes) -> None:
        model = None
        try:
            payload = json.loads(body.decode("utf-8")) if body else {}
            model = payload.get("model")
        except Exception:
            model = None
        result = {
            "method": self.command,
            "path": self.path,
            "model": model,
            "authorization_present": bool(self.headers.get("Authorization")),
            "authorization_matches_expected_dummy": self.headers.get("Authorization")
            == "Bearer cst-test",
            "content_type": self.headers.get("Content-Type"),
        }
        self.result_path.write_text(json.dumps(result), encoding="utf-8")

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length else b""
        self._record(body)
        if self.return_success:
            payload = {
                "id": "resp_cst_mock",
                "object": "response",
                "status": "completed",
                "model": "cst-mock-model",
                "output": [],
            }
            status = 200
        else:
            payload = {
                "error": {
                    "message": "Intentional local mock response after route capture.",
                    "type": "cst_mock_stop",
                }
            }
            status = 400
        response = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, _format: str, *_args: object) -> None:
        return


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready", required=True)
    parser.add_argument("--result", required=True)
    parser.add_argument("--success", action="store_true")
    args = parser.parse_args()

    Handler.result_path = Path(args.result)
    Handler.return_success = args.success
    server = HTTPServer(("127.0.0.1", 0), Handler)
    Path(args.ready).write_text(
        json.dumps({"port": server.server_address[1]}), encoding="utf-8"
    )
    server.handle_request()
    server.server_close()


if __name__ == "__main__":
    main()
