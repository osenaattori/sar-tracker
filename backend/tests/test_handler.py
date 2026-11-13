"""Unit tests for the feed builder. Run: python3 -m unittest discover backend/tests"""

import io
import json
import os
import sys
import unittest

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "lambda"))
import handler  # noqa: E402

ITEM = json.load(open(os.path.join(HERE, "fixtures", "stac_item_dwell.json")))
ITEM_KEY = "stac-items/2025/11/ICEYE_4EKGVZ_20251110T124428Z_7004635_X42_SLEDF.json"


class PreconditionFailed(Exception):
    response = {"Error": {"Code": "PreconditionFailed"}}


class FakeS3:
    """Tiny in-memory S3 with ETags and conditional writes."""

    class exceptions:
        class NoSuchKey(Exception):
            pass

    def __init__(self, race_once=False):
        self.objects, self.version, self.race_once = {}, 0, race_once

    def get_object(self, Bucket, Key):
        if Key not in self.objects:
            raise self.exceptions.NoSuchKey()
        body, etag = self.objects[Key]
        return {"Body": io.BytesIO(body), "ETag": etag}

    def put_object(self, Bucket, Key, Body, IfMatch=None, IfNoneMatch=None, **_):
        current = self.objects.get(Key)
        if self.race_once and Key == handler.FEED_KEY:
            self.race_once = False
            raise PreconditionFailed()
        if IfNoneMatch == "*" and current:
            raise PreconditionFailed()
        if IfMatch and (not current or current[1] != IfMatch):
            raise PreconditionFailed()
        self.version += 1
        self.objects[Key] = (Body, f'"v{self.version}"')

    def json(self, key):
        return json.loads(self.objects[key][0])


def sqs_event(*keys, raw=False):
    s3msg = {"Records": [{"s3": {"object": {"key": k}}} for k in keys]}
    body = s3msg if raw else {"Type": "Notification", "Message": json.dumps(s3msg)}
    return {"Records": [{"body": json.dumps(body)}]}


class SceneTests(unittest.TestCase):
    def test_scene_from_real_item(self):
        s = handler.scene_from_item(ITEM, "https://x/item.json")
        self.assertEqual(s["id"], "ICEYE_4EKGVZ_20251110T124428Z_7004635_X42_SLEDF")
        self.assertEqual(s["mode"], "dwell-fine")
        self.assertEqual(s["platform"], "ICEYE-X42")
        self.assertTrue(s["thumbnail"].endswith("_THM.png"))
        self.assertTrue(s["video"].endswith("_VID.mp4"))
        self.assertAlmostEqual(s["centroid"]["lat"], -71.0156, places=3)
        self.assertGreaterEqual(len(s["footprint"]), 4)

    def test_centroid_fallback(self):
        c = handler.centroid([[0, 0], [2, 0], [2, 2], [0, 2], [0, 0]])
        self.assertEqual(c, {"lat": 1.0, "lon": 1.0})


class SqsParsingTests(unittest.TestCase):
    def test_only_stac_items_are_picked(self):
        ev = sqs_event(ITEM_KEY, "data/dwell/X/X_GRD.tif", "catalog.json")
        self.assertEqual(handler.stac_keys_from_sqs(ev), [ITEM_KEY])

    def test_raw_delivery_and_url_encoding(self):
        ev = sqs_event("stac-items/2025/11/A%2BB.json", raw=True)
        self.assertEqual(handler.stac_keys_from_sqs(ev), ["stac-items/2025/11/A+B.json"])


class FeedTests(unittest.TestCase):
    def test_new_item_creates_feed_and_status(self):
        s3 = FakeS3()
        store = handler.FeedStore(s3, "bucket")
        added = handler.process_new_items(store, [ITEM_KEY], fetch=lambda u: ITEM)
        self.assertEqual(len(added), 1)
        feed = s3.json("feed.json")
        self.assertEqual(feed["sceneCount"], 1)
        self.assertIn("CC BY 4.0", feed["attribution"])
        self.assertIsNotNone(s3.json("status.json")["lastNewSceneAt"])

    def test_duplicate_notification_is_idempotent(self):
        s3 = FakeS3()
        store = handler.FeedStore(s3, "bucket")
        handler.process_new_items(store, [ITEM_KEY], fetch=lambda u: ITEM)
        added = handler.process_new_items(store, [ITEM_KEY], fetch=lambda u: ITEM)
        self.assertEqual(added, [])
        self.assertEqual(s3.json("feed.json")["sceneCount"], 1)

    def test_write_race_is_retried(self):
        s3 = FakeS3(race_once=True)
        store = handler.FeedStore(s3, "bucket")
        added = handler.process_new_items(store, [ITEM_KEY], fetch=lambda u: ITEM)
        self.assertEqual(len(added), 1)

    def test_backfill_skips_broken_items_and_sorts(self):
        newer = json.loads(json.dumps(ITEM))
        newer["id"] = "NEWER"
        newer["properties"]["datetime"] = "2026-01-01T00:00:00Z"
        summary = {"features": [
            {"properties": {"href": "u/old"}},
            {"properties": {"href": "u/new"}},
            {"properties": {"href": "u/broken"}},
        ]}

        def fetch(url):
            if url == handler.FOOTPRINT_SUMMARY:
                return summary
            if url == "u/broken":
                raise OSError("404")
            return newer if url == "u/new" else ITEM

        s3 = FakeS3()
        result = handler.backfill(handler.FeedStore(s3, "b"), fetch=fetch, workers=2)
        self.assertEqual(result, {"scenes": 2, "added": 2, "failed": 1})
        self.assertEqual(s3.json("feed.json")["scenes"][0]["id"], "NEWER")


if __name__ == "__main__":
    unittest.main()
