"""Local stand-in for a chat channel. Prints one line per alert Alertmanager sends it.

The URL path names the receiver (/page or /ticket), so the log shows where each alert was routed:
    docker compose logs -f alert-logger
"""
import json
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        now = datetime.now(timezone.utc).strftime("%H:%M:%S")
        channel = self.path.strip("/")
        for alert in body["alerts"]:
            labels = alert["labels"]
            print(
                f"{now} #{channel:<6} {alert['status']:<8} {labels.get('alertname')}"
                f" severity={labels.get('severity')} slo={labels.get('slo', '-')}"
                f" | {alert['annotations'].get('description', '')}",
                flush=True,
            )
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        pass  # keep the output to alerts only


HTTPServer(("", 8080), Handler).serve_forever()
