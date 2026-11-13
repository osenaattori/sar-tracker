#!/usr/bin/env python3
"""Run the SAR tracker pipeline locally on your Mac - no AWS needed.

    python3 backend/local/server.py            # poll every 10 min, serve on :8080
    python3 backend/local/server.py --interval 120 --port 9000

It reuses the exact same feed-building code as the AWS Lambda. Differences:

    AWS                               Local
    ICEYE SNS push -> SQS -> Lambda    poll ICEYE's STAC summary every N minutes
    S3 bucket (conditional writes)     ./data folder (same ETag/If-Match logic)
    CloudFront                         built-in HTTP server on your Wi-Fi
    CloudWatch metrics / alarms        /metrics (Prometheus format) + /healthz

Endpoints: /feed.json  /status.json  /healthz  /metrics
Stdlib only - works with the macOS system Python 3.9.
"""

import argparse
import hashlib
import io
import json
import logging
import os
import signal
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lambda"))
import handler  # noqa: E402  (the same module the Lambda runs)

log = logging.getLogger("sar-local")


# --------------------------------------------------------------- storage --

class PreconditionFailed(Exception):
    response = {"Error": {"Code": "PreconditionFailed"}}


class LocalS3:
    """Folder that behaves like the S3 calls FeedStore uses, including
    conditional writes - so the Lambda code runs unchanged."""

    class exceptions:
        class NoSuchKey(Exception):
            pass

    def __init__(self, root):
        self.root = root
        self.lock = threading.Lock()
        os.makedirs(root, exist_ok=True)

    def _path(self, key):
        return os.path.join(self.root, os.path.basename(key))

    @staticmethod
    def _etag(body):
        return '"%s"' % hashlib.md5(body).hexdigest()

    def get_object(self, Bucket, Key):
        try:
            with open(self._path(Key), "rb") as f:
                body = f.read()
        except FileNotFoundError:
            raise self.exceptions.NoSuchKey(Key)
        return {"Body": io.BytesIO(body), "ETag": self._etag(body)}

    def put_object(self, Bucket, Key, Body, IfMatch=None, IfNoneMatch=None, **_):
        path = self._path(Key)
        with self.lock:
            exists = os.path.exists(path)
            if IfNoneMatch == "*" and exists:
                raise PreconditionFailed()
            if IfMatch:
                with open(path, "rb") as f:
                    if not exists or self._etag(f.read()) != IfMatch:
                        raise PreconditionFailed()
            tmp = path + ".tmp"
            with open(tmp, "wb") as f:
                f.write(Body)
            os.replace(tmp, path)  # atomic: readers never see half a file


# --------------------------------------------------------------- metrics --

class Metrics:
    def __init__(self):
        self.lock = threading.Lock()
        self.poll_runs = 0
        self.poll_errors = 0
        self.new_scenes = 0
        self.last_success = 0.0
        self.last_duration = 0.0
        self.scenes = 0
        self.requests = {}

    def count_request(self, path, code):
        with self.lock:
            k = (path, code)
            self.requests[k] = self.requests.get(k, 0) + 1

    def render(self):
        with self.lock:
            lines = [
                "# HELP sar_scenes Scenes currently in the feed",
                "# TYPE sar_scenes gauge",
                "sar_scenes %d" % self.scenes,
                "# HELP sar_new_scenes_total New scenes discovered since start",
                "# TYPE sar_new_scenes_total counter",
                "sar_new_scenes_total %d" % self.new_scenes,
                "# TYPE sar_poll_runs_total counter",
                "sar_poll_runs_total %d" % self.poll_runs,
                "# TYPE sar_poll_errors_total counter",
                "sar_poll_errors_total %d" % self.poll_errors,
                "# TYPE sar_last_success_timestamp_seconds gauge",
                "sar_last_success_timestamp_seconds %.0f" % self.last_success,
                "# TYPE sar_poll_duration_seconds gauge",
                "sar_poll_duration_seconds %.3f" % self.last_duration,
                "# TYPE sar_http_requests_total counter",
            ]
            for (path, code), n in sorted(self.requests.items()):
                lines.append('sar_http_requests_total{path="%s",code="%d"} %d' % (path, code, n))
        return "\n".join(lines) + "\n"


# --------------------------------------------------------------- polling --

def poll_once(store, metrics, fetch=handler.http_json):
    """Find scenes in ICEYE's summary that we don't have yet and add them.
    First run (no feed yet) does a full backfill."""
    started = time.time()
    try:
        feed, _ = store.load()
        known = {s["id"] for s in feed.get("scenes", [])}
        if not known:
            log.info("no feed yet - running full backfill (about 700 STAC items)…")
            result = handler.backfill(store, fetch=fetch)
            added = result["added"]
        else:
            summary = fetch(handler.FOOTPRINT_SUMMARY)
            prefix = handler.ICEYE_BASE + "/"
            keys = [
                f["properties"]["href"][len(prefix):]
                for f in summary.get("features", [])
                if f.get("properties", {}).get("id") not in known
                and (f.get("properties", {}).get("href") or "").startswith(prefix)
            ]
            added = len(handler.process_new_items(store, keys, fetch=fetch, event="poll")) if keys else 0
            if not keys:
                # Still record a heartbeat so the app shows the pipeline is alive.
                store.write_status(len(known), lastEvent="poll")
        feed, _ = store.load()
        with metrics.lock:
            metrics.poll_runs += 1
            metrics.new_scenes += added if known else 0  # first backfill is not "new"
            metrics.scenes = len(feed.get("scenes", []))
            metrics.last_success = time.time()
            metrics.last_duration = time.time() - started
        log.info("poll ok: %d scenes, %d new, %.1fs", metrics.scenes, added, metrics.last_duration)
    except Exception as e:  # keep the loop alive; surfaced in /healthz and /metrics
        with metrics.lock:
            metrics.poll_runs += 1
            metrics.poll_errors += 1
        log.error("poll failed: %s", e)


def poll_loop(store, metrics, interval, stop):
    while not stop.is_set():
        poll_once(store, metrics)
        stop.wait(interval)


# ---------------------------------------------------------------- server --

def make_handler(data_dir, metrics, interval):
    files = {"/feed.json", "/status.json"}

    class Handler(BaseHTTPRequestHandler):
        server_version = "sar-tracker-local/1.0"

        def log_message(self, fmt, *args):
            log.debug("%s " + fmt, self.address_string(), *args)

        def _send(self, code, body, ctype, cache="no-cache"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", cache)
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
            metrics.count_request(self.path.split("?")[0], code)

        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            path = self.path.split("?")[0]
            if path in files:
                try:
                    with open(os.path.join(data_dir, path[1:]), "rb") as f:
                        body = f.read()
                except FileNotFoundError:
                    return self._send(503, b'{"error":"feed not built yet"}', "application/json")
                return self._send(200, body, "application/json", "public, max-age=30")
            if path == "/healthz":
                age = time.time() - metrics.last_success
                ok = metrics.last_success > 0 and age < interval * 3
                body = json.dumps({"ok": ok, "lastSuccessAgeSeconds": round(age),
                                   "scenes": metrics.scenes}).encode()
                return self._send(200 if ok else 503, body, "application/json")
            if path == "/metrics":
                return self._send(200, metrics.render().encode(), "text/plain; version=0.0.4")
            self._send(404, b'{"error":"not found"}', "application/json")

    return Handler


def lan_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))  # no packet sent; just picks the route
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--interval", type=int, default=600, help="seconds between ICEYE polls (default 600)")
    ap.add_argument("--data", default=os.path.join(HERE, "data"), help="where feed.json/status.json live")
    ap.add_argument("--bind", default="0.0.0.0", help="0.0.0.0 = reachable from your iPhone on the same Wi-Fi")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    # The Lambda prints CloudWatch metric lines; locally /metrics replaces them.
    handler.emit_metric = lambda name, value: None

    store = handler.FeedStore(LocalS3(args.data), "local")
    metrics = Metrics()
    stop = threading.Event()

    httpd = ThreadingHTTPServer((args.bind, args.port), make_handler(args.data, metrics, args.interval))
    worker = threading.Thread(target=poll_loop, args=(store, metrics, args.interval, stop), daemon=True)
    worker.start()

    def shutdown(*_):
        stop.set()
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    url = "http://%s:%d/feed.json" % (lan_ip(), args.port)
    log.info("serving on %s  (health: /healthz, metrics: /metrics)", url)
    log.info("in the iPhone app: About → Data source → paste %s", url)
    httpd.serve_forever()
    log.info("stopped")


if __name__ == "__main__":
    main()
