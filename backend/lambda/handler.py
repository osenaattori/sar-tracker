"""ICEYE open SAR data tracker - feed builder Lambda.

Triggers:
  * SQS messages that carry ICEYE's SNS "object created" notifications
    (SNS -> SQS -> Lambda). Only new STAC item JSONs are processed.
  * {"backfill": true} - rebuilds the whole feed from ICEYE's public STAC
    footprint summary. Run once after deploy and daily by EventBridge as a
    reconciliation job, so a missed notification heals itself.

Output (in our own bucket, served through CloudFront):
  * feed.json   - all scenes, newest first, read by the iPhone app
  * status.json - pipeline health shown in the app's Status tab

Data: ICEYE SAR Open Dataset, CC BY 4.0, (c) ICEYE.
https://registry.opendata.aws/iceye-opendata
"""

import json
import logging
import os
import re
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

log = logging.getLogger()
log.setLevel(logging.INFO)

ICEYE_BASE = "https://iceye-open-data-catalog.s3.amazonaws.com"
FOOTPRINT_SUMMARY = f"{ICEYE_BASE}/stac-items/summary/footprint-summary-points.geojson"
STAC_ITEM_KEY = re.compile(r"^stac-items/\d{4}/\d{2}/[^/]+\.json$")
ATTRIBUTION = (
    "Contains ICEYE SAR Open Data (CC BY 4.0), accessed via "
    "https://registry.opendata.aws/iceye-opendata"
)
FEED_KEY = "feed.json"
STATUS_KEY = "status.json"
FEED_VERSION = 1


# ---------------------------------------------------------------- helpers --

def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def http_json(url, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": "sar-tracker/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def mode_from_url(url):
    """ICEYE stores assets under data/<acquisition-mode>/<scene-id>/..."""
    m = re.search(r"/data/([^/]+)/", url or "")
    return m.group(1) if m else None


def centroid(ring):
    pts = ring[:-1] if len(ring) > 1 and ring[0] == ring[-1] else ring
    if not pts:
        return None
    return {
        "lat": round(sum(p[1] for p in pts) / len(pts), 6),
        "lon": round(sum(p[0] for p in pts) / len(pts), 6),
    }


def scene_from_item(item, stac_url):
    """Turn a STAC item into the compact scene record the app needs."""
    props = item.get("properties", {})
    assets = item.get("assets", {})
    geom = item.get("geometry") or {}
    ring = geom.get("coordinates", [[]])[0] if geom.get("type") == "Polygon" else []

    def href(*keys):
        for k in keys:
            if k in assets:
                return assets[k].get("href")
        return None

    thumb = href("graphic", "thumbnail")
    any_asset = thumb or href("grd-cog", "qlk-cog", "slc-cog")
    c = props.get("proj:centroid")
    return {
        "id": item.get("id"),
        "datetime": props.get("datetime") or props.get("start_datetime"),
        "platform": props.get("platform"),
        "mode": mode_from_url(any_asset) or props.get("sar:instrument_mode"),
        "instrumentMode": props.get("sar:instrument_mode"),
        "polarizations": props.get("sar:polarizations"),
        "orbitState": props.get("sat:orbit_state"),
        "incidenceAngle": props.get("view:incidence_angle"),
        "centroid": {"lat": c["lat"], "lon": c["lon"]} if c else centroid(ring),
        "footprint": [[round(p[0], 6), round(p[1], 6)] for p in ring],
        "thumbnail": thumb,
        "quicklook": href("qlk-cog"),
        "video": href("vid-mp4"),
        "stac": stac_url,
    }


def sort_scenes(scenes):
    # Newest first; scenes without a date go last.
    return sorted(scenes, key=lambda s: s.get("datetime") or "", reverse=True)


def stac_keys_from_sqs(event):
    """Extract new STAC item keys from SQS(SNS(S3 event)) messages."""
    keys = []
    for rec in event.get("Records", []):
        body = json.loads(rec["body"])
        # SNS envelope unless raw delivery is enabled.
        msg = json.loads(body["Message"]) if "Message" in body else body
        for s3rec in msg.get("Records", []):
            key = urllib.parse.unquote_plus(s3rec["s3"]["object"]["key"])
            if STAC_ITEM_KEY.match(key):
                keys.append(key)
    return keys


# ------------------------------------------------------------------ store --

class FeedStore:
    """feed.json in S3 with optimistic locking (S3 conditional writes),
    so concurrent Lambda invocations never overwrite each other."""

    def __init__(self, s3, bucket):
        self.s3, self.bucket = s3, bucket

    def load(self):
        try:
            obj = self.s3.get_object(Bucket=self.bucket, Key=FEED_KEY)
            return json.loads(obj["Body"].read()), obj["ETag"]
        except self.s3.exceptions.NoSuchKey:
            return {"scenes": []}, None

    def save(self, scenes, etag, **extra):
        body = {
            "version": FEED_VERSION,
            "generatedAt": now_iso(),
            "sceneCount": len(scenes),
            "attribution": ATTRIBUTION,
            "scenes": sort_scenes(scenes),
        }
        args = dict(
            Bucket=self.bucket,
            Key=FEED_KEY,
            Body=json.dumps(body, separators=(",", ":")).encode(),
            ContentType="application/json",
            CacheControl="public, max-age=60",
        )
        if etag:
            args["IfMatch"] = etag
        else:
            args["IfNoneMatch"] = "*"
        self.s3.put_object(**args)
        self.write_status(len(scenes), **extra)

    def write_status(self, scene_count, **extra):
        status = {"lastRunAt": now_iso(), "sceneCount": scene_count, **extra}
        try:
            old = json.loads(
                self.s3.get_object(Bucket=self.bucket, Key=STATUS_KEY)["Body"].read()
            )
        except Exception:
            old = {}
        if not status.get("lastNewSceneAt"):
            status["lastNewSceneAt"] = old.get("lastNewSceneAt")
        self.s3.put_object(
            Bucket=self.bucket,
            Key=STATUS_KEY,
            Body=json.dumps(status).encode(),
            ContentType="application/json",
            CacheControl="public, max-age=30",
        )


def update_with_retry(store, mutate, attempts=5):
    """Load -> mutate -> conditional save; retry on a lost race."""
    for i in range(attempts):
        feed, etag = store.load()
        scenes, extra = mutate(feed.get("scenes", []))
        try:
            store.save(scenes, etag, **extra)
            return scenes, extra
        except Exception as e:  # botocore ClientError
            code = getattr(e, "response", {}).get("Error", {}).get("Code")
            if code not in ("PreconditionFailed", "ConditionalRequestConflict"):
                raise
            log.warning("feed write race, retry %d", i + 1)
            time.sleep(0.2 * (i + 1))
    raise RuntimeError("could not update feed after retries")


def emit_metric(name, value):
    # CloudWatch Embedded Metric Format: a log line becomes a metric.
    print(json.dumps({
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [{
                "Namespace": "SarTracker",
                "Dimensions": [[]],
                "Metrics": [{"Name": name, "Unit": "Count"}],
            }],
        },
        name: value,
    }))


# ---------------------------------------------------------------- actions --

def process_new_items(store, keys, fetch=http_json, event="notification"):
    fetched = []
    for key in keys:
        url = f"{ICEYE_BASE}/{key}"
        fetched.append(scene_from_item(fetch(url), url))  # errors -> SQS retry

    added = []

    def mutate(scenes):
        added.clear()  # mutate may run again after a lost write race
        by_id = {s["id"]: s for s in scenes}
        for s in fetched:
            if s["id"] not in by_id:
                added.append(s["id"])
            by_id[s["id"]] = s
        extra = {"lastEvent": event}
        if added:
            extra["lastNewSceneAt"] = now_iso()
        return list(by_id.values()), extra

    update_with_retry(store, mutate)
    emit_metric("NewScenes", len(added))
    return added


def backfill(store, fetch=http_json, workers=16):
    summary = fetch(FOOTPRINT_SUMMARY)
    urls = [f["properties"]["href"] for f in summary.get("features", [])
            if f.get("properties", {}).get("href")]

    def one(url):
        try:
            return scene_from_item(fetch(url), url)
        except Exception as e:  # one broken item must not stop the rebuild
            log.warning("skip %s: %s", url, e)
            return None

    with ThreadPoolExecutor(max_workers=workers) as pool:
        fresh = [s for s in pool.map(one, urls) if s]
    failed = len(urls) - len(fresh)
    added = []

    def mutate(scenes):
        added.clear()
        old_ids = {s["id"] for s in scenes}
        by_id = {s["id"]: s for s in scenes}
        for s in fresh:
            if s["id"] not in old_ids:
                added.append(s["id"])
            by_id[s["id"]] = s
        extra = {"lastEvent": "backfill", "backfillFailed": failed}
        if added and old_ids:
            extra["lastNewSceneAt"] = now_iso()
        return list(by_id.values()), extra

    scenes, _ = update_with_retry(store, mutate)
    emit_metric("NewScenes", len(added))
    emit_metric("BackfillFailedItems", failed)
    return {"scenes": len(scenes), "added": len(added), "failed": failed}


def handler(event, context):
    import boto3  # available in the Lambda runtime

    store = FeedStore(boto3.client("s3"), os.environ["FEED_BUCKET"])
    if event.get("backfill"):
        result = backfill(store)
        log.info("backfill done: %s", result)
        return result
    keys = stac_keys_from_sqs(event)
    if not keys:
        return {"added": []}
    added = process_new_items(store, keys)
    log.info("processed %d keys, %d new scenes", len(keys), len(added))
    return {"added": added}

