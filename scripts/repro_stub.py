#!/usr/bin/env python3
# TEMPORARY (CI repro harness, `repro-sim` branch only): canned `POST /api/*`
# stub so the seeded simulator server (http://127.0.0.1:3080) answers the
# settings/chat-channels screens with real wire shapes. Without it every page
# dies on the first fetch and the hang path never runs. Remove with the harness.
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = int(os.environ.get("STUB_PORT", "3080"))

# ChatChannelInfo / ChannelStatusInfo — snake_case (shared .convertFromSnakeCase).
CHANNELS = [
    {
        "id": 1,
        "name": "Lark",
        "channel_type": "lark",
        "enabled": True,
        "config_json": json.dumps({"app_id": "cli_repro", "chat_id": "oc_repro"}),
        "event_filter_json": None,
        "daily_report_enabled": False,
        "daily_report_time": None,
    },
    {
        "id": 2,
        "name": "Telegram",
        "channel_type": "telegram",
        "enabled": True,
        "config_json": json.dumps({"chat_id": "1001"}),
        "event_filter_json": None,
        "daily_report_enabled": True,
        "daily_report_time": "09:00",
    },
    {
        "id": 3,
        "name": "WeChat",
        "channel_type": "weixin",
        "enabled": False,
        "config_json": json.dumps({"base_url": "https://ilinkai.weixin.qq.com"}),
        "event_filter_json": None,
        "daily_report_enabled": False,
        "daily_report_time": None,
    },
]

STATUSES = [
    {"channel_id": 1, "name": "Lark", "channel_type": "lark", "status": "connected"},
    {"channel_id": 2, "name": "Telegram", "channel_type": "telegram", "status": "disconnected"},
    {"channel_id": 3, "name": "WeChat", "channel_type": "weixin", "status": "error"},
]

# Bare JSON fragments (decodeStringFragment / decodeBoolFragment / null filter).
FRAGMENTS = {
    "get_chat_command_prefix": b'"/"',
    "get_chat_message_language": b'"en"',
    "get_chat_event_filter": b"null",
    "get_chat_channel_has_token": b"true",
    "get_feedback_settings": b'{"enabled":true}',
    "get_question_settings": b'{"enabled":true}',
}

OBJECTS = {
    "health": {"status": "ok", "version": "0.0-repro"},
    "list_chat_channels": CHANNELS,
    "get_chat_channel_status": STATUSES,
    "get_chat_event_webhooks": [],
    "list_all_folder_details": [],
    "list_open_folder_details": [],
    "list_all_conversations": [],
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("stub: %s\n" % (fmt % args))
        sys.stderr.flush()

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        path = self.path.split("/api/", 1)[-1] if "/api/" in self.path else ""
        if path in FRAGMENTS:
            body = FRAGMENTS[path]
        else:
            body = json.dumps(OBJECTS.get(path, {})).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.do_POST()


def main():
    ThreadingHTTPServer.allow_reuse_address = True
    try:
        server = ThreadingHTTPServer((HOST, PORT), Handler)
    except OSError as exc:
        sys.stderr.write("stub: bind %s:%d failed: %s\n" % (HOST, PORT, exc))
        sys.stderr.flush()
        sys.exit(1)
    sys.stderr.write("stub: listening on http://%s:%d\n" % (HOST, PORT))
    sys.stderr.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
