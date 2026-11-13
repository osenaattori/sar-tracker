"""Tests for the local (no-AWS) runner."""

import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "local"))
import server  # noqa: E402

handler = server.handler
handler.emit_metric = lambda *a: None
ITEM = json.load(open(os.path.join(HERE, "fixtures", "stac_item_dwell.json")))


def item_with(id_, dt):
    i = json.loads(json.dumps(ITEM))
    i["id"], i["properties"]["datetime"] = id_, dt
    return i


class FakeIceye:
    """Serves a summary + items; add() simulates ICEYE publishing a scene."""

    def __init__(self):
        self.items = {}

    def add(self, id_, dt):
        self.items[f"{handler.ICEYE_BASE}/stac-items/2026/01/{id_}.json"] = item_with(id_, dt)

    def __call__(self, url):
        if url == handler.FOOTPRINT_SUMMARY:
            return {"features": [{"properties": {"id": i["id"], "href": u}} for u, i in self.items.items()]}
        return self.items[url]


class LocalS3Tests(unittest.TestCase):
    def test_conditional_writes(self):
        s3 = server.LocalS3(tempfile.mkdtemp())
        s3.put_object(Bucket="b", Key="feed.json", Body=b"1", IfNoneMatch="*")
        with self.assertRaises(server.PreconditionFailed):
            s3.put_object(Bucket="b", Key="feed.json", Body=b"2", IfNoneMatch="*")
        etag = s3.get_object(Bucket="b", Key="feed.json")["ETag"]
        with self.assertRaises(server.PreconditionFailed):
            s3.put_object(Bucket="b", Key="feed.json", Body=b"3", IfMatch='"stale"')
        s3.put_object(Bucket="b", Key="feed.json", Body=b"4", IfMatch=etag)
        self.assertEqual(s3.get_object(Bucket="b", Key="feed.json")["Body"].read(), b"4")

    def test_keys_cannot_escape_folder(self):
        root = tempfile.mkdtemp()
        s3 = server.LocalS3(root)
        s3.put_object(Bucket="b", Key="../../evil.json", Body=b"x")
        self.assertTrue(os.path.exists(os.path.join(root, "evil.json")))


class PollTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.store = handler.FeedStore(server.LocalS3(self.dir), "local")
        self.metrics = server.Metrics()
        self.iceye = FakeIceye()

    def test_first_poll_backfills_then_detects_new_scene(self):
        self.iceye.add("A", "2025-01-01T00:00:00Z")
        self.iceye.add("B", "2025-02-01T00:00:00Z")
        server.poll_once(self.store, self.metrics, fetch=self.iceye)
        self.assertEqual(self.metrics.scenes, 2)
        self.assertEqual(self.metrics.new_scenes, 0)  # backfill isn't "new"

        server.poll_once(self.store, self.metrics, fetch=self.iceye)  # nothing new
        self.assertEqual(json.load(open(os.path.join(self.dir, "status.json")))["lastEvent"], "poll")

        self.iceye.add("C", "2026-01-01T00:00:00Z")
        server.poll_once(self.store, self.metrics, fetch=self.iceye)
        feed = json.load(open(os.path.join(self.dir, "feed.json")))
        self.assertEqual([s["id"] for s in feed["scenes"]], ["C", "B", "A"])
        self.assertEqual(self.metrics.new_scenes, 1)
        self.assertEqual(self.metrics.poll_errors, 0)

    def test_poll_error_is_counted_not_raised(self):
        def broken(url):
            raise OSError("network down")
        server.poll_once(self.store, self.metrics, fetch=broken)
        self.assertEqual(self.metrics.poll_errors, 1)


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.metrics = server.Metrics()
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(self.dir, self.metrics, 600))
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.base = "http://127.0.0.1:%d" % self.httpd.server_address[1]

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def get(self, path):
        try:
            with urllib.request.urlopen(self.base + path) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def test_endpoints(self):
        self.assertEqual(self.get("/feed.json")[0], 503)   # not built yet
        self.assertEqual(self.get("/healthz")[0], 503)
        with open(os.path.join(self.dir, "feed.json"), "w") as f:
            f.write('{"scenes":[]}')
        self.metrics.last_success = __import__("time").time()
        self.assertEqual(self.get("/feed.json"), (200, b'{"scenes":[]}'))
        self.assertEqual(self.get("/healthz")[0], 200)
        self.assertEqual(self.get("/../../etc/passwd")[0], 404)
        code, body = self.get("/metrics")
        self.assertEqual(code, 200)
        self.assertIn(b'sar_http_requests_total{path="/feed.json",code="200"} 1', body)


if __name__ == "__main__":
    unittest.main()
