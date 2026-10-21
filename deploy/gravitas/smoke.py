#!/usr/bin/env python3
"""Read-only deployment checks; never create accounts or calendar entries."""
import json
import sys
import urllib.error
import urllib.request

base = sys.argv[1].rstrip("/")

def check(path, status=200, method="GET", headers=None, body=None):
    request = urllib.request.Request(base + path, method=method, headers=headers or {}, data=body)
    try:
        response = urllib.request.urlopen(request, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        content = response.read()
        if response.status != status:
            raise SystemExit(f"{method} {path}: expected {status}, got {response.status}")
        return content, response.headers

health, _ = check("/healthz")
assert json.loads(health)["status"] == "ok"
html, _ = check("/")
assert b"<title>Spacetime</title>" in html
script, _ = check("/flutter_bootstrap.js")
assert len(script) > 100
script, _ = check("/main.dart.js")
assert len(script) > 10000
wasm, _ = check("/canvaskit/canvaskit.wasm")
assert wasm.startswith(b"\x00asm")
_, headers = check("/api/events", 401)
assert headers.get("Cache-Control") == "no-store"
_, headers = check("/.well-known/caldav", 401)
assert headers.get("WWW-Authenticate", "").startswith("Basic")
check("/api/login", 403, "POST", {"Origin": "https://invalid.example", "Content-Type": "application/json"}, b"{}")
print("PASS: health, Flutter assets, bundled renderer, authentication, CalDAV and origin protection")
