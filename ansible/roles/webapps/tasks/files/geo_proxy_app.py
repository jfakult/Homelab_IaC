#!/usr/bin/env python3
"""Reverse-geocoding proxy in front of Nominatim (OpenStreetMap).

Stdlib-only on purpose: it runs as `python3 /app/geo_proxy_app.py` inside a
plain python:3.12-alpine container with this file bind-mounted in, no image
build/pip install step. Single-threaded HTTPServer so the 1 req/sec Nominatim
usage-policy throttle below is enforced by construction rather than a lock.
"""
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(os.environ.get("PORT", "8091"))
CONTACT_EMAIL = os.environ.get("CONTACT_EMAIL", "")
NOMINATIM_URL = os.environ.get("NOMINATIM_URL", "https://nominatim.openstreetmap.org/reverse")
MIN_UPSTREAM_INTERVAL = 1.1  # seconds; Nominatim usage policy caps at 1 req/sec
CACHE_MAX_ENTRIES = 4096
CACHE_PRECISION = 5  # ~1.1m at the equator

if not CONTACT_EMAIL:
    sys.exit("CONTACT_EMAIL is required (Nominatim usage policy requires a contact)")

USER_AGENT = "fakult-geo-proxy/1.0 (%s)" % CONTACT_EMAIL

_cache = {}
_cache_lock = threading.Lock()
_last_upstream_call = 0.0


def _cache_key(lat, lon):
    return (round(lat, CACHE_PRECISION), round(lon, CACHE_PRECISION))


def reverse_geocode(lat, lon):
    global _last_upstream_call

    key = _cache_key(lat, lon)
    with _cache_lock:
        if key in _cache:
            return _cache[key]

    wait = MIN_UPSTREAM_INTERVAL - (time.monotonic() - _last_upstream_call)
    if wait > 0:
        time.sleep(wait)

    params = urllib.parse.urlencode({
        "lat": lat,
        "lon": lon,
        "format": "jsonv2",
        "zoom": 18,
        "addressdetails": 1,
    })
    req = urllib.request.Request(
        NOMINATIM_URL + "?" + params,
        headers={"User-Agent": USER_AGENT},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    _last_upstream_call = time.monotonic()

    with _cache_lock:
        if len(_cache) >= CACHE_MAX_ENTRIES:
            _cache.pop(next(iter(_cache)))
        _cache[key] = body
    return body


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)

        if parsed.path == "/health":
            self._send_json(200, {"status": "ok"})
            return

        if parsed.path != "/reverse":
            self._send_json(404, {"error": "not found"})
            return

        qs = urllib.parse.parse_qs(parsed.query)
        try:
            lat = float(qs["lat"][0])
            lon = float(qs["lon"][0])
        except (KeyError, ValueError, IndexError):
            self._send_json(400, {"error": "lat and lon query params are required floats"})
            return

        if not (-90 <= lat <= 90) or not (-180 <= lon <= 180):
            self._send_json(400, {"error": "lat/lon out of range"})
            return

        try:
            result = reverse_geocode(lat, lon)
        except urllib.error.URLError as exc:
            self._send_json(502, {"error": "upstream request failed: %s" % exc})
            return
        except Exception as exc:
            self._send_json(502, {"error": "upstream error: %s" % exc})
            return

        self._send_json(200, result)


def main():
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
