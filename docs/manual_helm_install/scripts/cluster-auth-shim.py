#!/usr/bin/env python3
"""
cluster-auth shim — in-memory stub for standalone installs.

Implements the REST endpoints that aiwb-api calls on cluster-auth so that
model deployments work without OpenBao or a real cluster-auth service.
State is in-memory only; it is lost on pod restart.

Endpoints
---------
GET  /health  /healthz  /ready          200  {"status": "ok"}
GET  /apikey/groups                     200  [{"id":…, "name":…}, …]
POST /apikey/group        {name}        200  {"id":…, "name":…}
DELETE /apikey/group      {id}          200  {"status": "ok"}
POST /apikey/create       {group_id}    200  {"key": "amd_aim_api_key_…", "group_id":…}
POST /apikey/lookup       {key}         200  {"key":…, "group_id":…}  or  404
POST /apikey/revoke       {key}         200  {"status": "ok"}
POST /apikey/renew        {key}         200  {"status": "ok"}
POST /apikey/bind         {key, …}      200  {"status": "ok"}
POST /apikey/unbind       {key, …}      200  {"status": "ok"}
"""

import json
import logging
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("cluster-auth-shim")

_groups: dict = {}  # group_id → {"id": …, "name": …}
_keys: dict = {}    # key_string → {"key": …, "group_id": …}

PORT = 8081


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        log.info("%s %s", self.path, args[0] if args else "")

    def _read_body(self) -> dict:
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        try:
            return json.loads(self.rfile.read(length))
        except Exception:
            return {}

    def _send(self, code: int, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/health", "/healthz", "/ready"):
            self._send(200, {"status": "ok"})
        elif self.path == "/apikey/groups":
            self._send(200, list(_groups.values()))
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        body = self._read_body()

        if self.path == "/apikey/group":
            name = body.get("name", "unnamed")
            gid = str(uuid.uuid4())
            group = {"id": gid, "name": name}
            _groups[gid] = group
            log.info("created group %s (%s)", gid, name)
            self._send(200, group)

        elif self.path == "/apikey/create":
            group_id = body.get("group_id", "")
            key_str = "amd_aim_api_key_" + uuid.uuid4().hex
            entry = {"key": key_str, "group_id": group_id}
            _keys[key_str] = entry
            log.info("created key for group %s", group_id)
            self._send(200, entry)

        elif self.path == "/apikey/lookup":
            key_str = body.get("key", "")
            entry = _keys.get(key_str)
            if entry:
                self._send(200, entry)
            else:
                self._send(404, {"error": "key not found"})

        elif self.path in ("/apikey/revoke", "/apikey/renew",
                           "/apikey/bind", "/apikey/unbind"):
            self._send(200, {"status": "ok"})

        else:
            self._send(404, {"error": "not found"})

    def do_DELETE(self):
        if self.path == "/apikey/group":
            body = self._read_body()
            gid = body.get("id", "")
            _groups.pop(gid, None)
            log.info("deleted group %s", gid)
            self._send(200, {"status": "ok"})
        else:
            self._send(404, {"error": "not found"})


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    log.info("cluster-auth shim listening on :%d", PORT)
    server.serve_forever()
