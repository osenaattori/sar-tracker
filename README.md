# SAR Tracker

A serverless, event-driven pipeline that **tracks new scenes in ICEYE's public SAR (radar satellite) open dataset**, plus an iPhone app that shows them on a map with image previews, SAR videos and live pipeline health.

Personal learning project (IT / DevOps / cloud). Not affiliated with or endorsed by ICEYE.

```
ICEYE public S3 ──► ICEYE SNS topic ──► SQS queue ──► Lambda ──► S3 (feed.json, status.json) ──► CloudFront ──► iPhone app
                                         └► DLQ (after 3 failed attempts)
EventBridge (daily) ─────────────────────────► Lambda {"backfill": true}   (self-healing full re-sync)
CloudWatch alarms + dashboard + budget ──► email
```

## What it shows

| Area | How |
|---|---|
| Event-driven architecture | Cross-account SNS subscription to ICEYE's "object created" topic, buffered by SQS |
| Reliability | Retries + dead-letter queue, idempotent processing, daily reconciliation job, S3 versioning for instant rollback |
| Safe concurrency | `feed.json` updated with **S3 conditional writes** (`If-Match` ETag) + retry, so parallel Lambdas never overwrite each other |
| Security | Private bucket behind CloudFront Origin Access Control, TLS-only bucket policy, least-privilege IAM (two objects, one queue), encryption at rest, security headers |
| Observability | Custom CloudWatch metric (`NewScenes`) via Embedded Metric Format, dashboard, alarms for DLQ / errors / "pipeline silent" |
| Cost control | Serverless, ARM Lambda, PriceClass_100 CDN, log retention, AWS Budget alert (≈ $0–1/month) |
| IaC + CI | Everything in Terraform; GitHub Actions runs unit tests, `terraform fmt/validate`, Trivy IaC scan and an iOS build |

## Repo layout

```
backend/lambda/handler.py    feed-builder Lambda (stdlib + boto3 only)
backend/local/server.py      run the pipeline on your Mac (no AWS)
backend/tests/               unit tests (in-memory S3 fake, local server)
infra/                       Terraform (AWS, us-west-2)
ios/SARTracker/              SwiftUI iPhone app (iOS 26+)
.github/workflows/ci.yml     CI
```

## 1. Run the iPhone app

The app works **immediately without AWS**. With no feed URL it reads ICEYE's public STAC catalog directly ("Direct mode").

1. Xcode → **Settings → Accounts** → add your Apple ID (a free account works; the app then stays installed for 7 days).
2. Open `ios/SARTracker/SARTracker.xcodeproj`.
3. Target **SARTracker → Signing & Capabilities** → pick your team. If the bundle ID is taken, change it to something unique.
4. iPhone: connect with USB-C, tap **Trust**, enable **Settings → Privacy & Security → Developer Mode** (the phone restarts).
5. Choose your iPhone as the run destination → **Run (⌘R)**.
6. First launch only: iPhone **Settings → General → VPN & Device Management** → trust your developer certificate.

## 2. Run the pipeline locally (free, no AWS)

The same feed-building code as the Lambda, running on your Mac:

```bash
python3 backend/local/server.py            # polls ICEYE every 10 min, serves on :8080
```

| AWS | Local |
|---|---|
| ICEYE SNS push → SQS → Lambda | polls ICEYE's STAC summary every `--interval` seconds |
| S3 with conditional writes | `backend/local/data/` with the same ETag / If-Match logic, atomic file replace |
| CloudFront | built-in HTTP server on your Wi-Fi |
| CloudWatch metrics + alarms | `/metrics` (Prometheus format) and `/healthz` (503 when stale) |

Install the app pointing at your Mac (iPhone on the same Wi-Fi):

```bash
FEED_URL=http://$(ipconfig getifaddr en0):8080/feed.json ios/install-on-device.sh <bundle-id>
```

Or paste the URL in the app under **About → Data source**. iOS allows plain HTTP only to local-network hosts (`NSAllowsLocalNetworking`); internet feeds must use HTTPS. On first launch, allow **Local Network** access on the iPhone, and on the Mac allow Python through the firewall if asked.

## 3. Deploy the AWS pipeline

Requires an AWS account, the [AWS CLI](https://aws.amazon.com/cli/) (`aws configure` or SSO) and [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.6.

```bash
cd infra
terraform init
terraform apply -var="alert_email=you@example.com"
```

Then fill the feed with existing scenes (afterwards it updates itself):

```bash
aws lambda invoke --region us-west-2 \
  --function-name "$(terraform output -raw lambda_name)" \
  --payload '{"backfill":true}' --cli-binary-format raw-in-base64-out /dev/stdout
```

Copy `terraform output -raw feed_url` into the app: **About → Data source → Save**. The Status tab now shows live pipeline health.

Notes:
- Confirm the SNS email subscription to receive alarms.
- The budget filters on the `Project=sar-tracker` tag. Activate it once under **Billing → Cost allocation tags**.
- Remove everything with `terraform destroy`.

### Remote state (optional, for teams)
Add an S3 backend with locking to `versions.tf`:
```hcl
backend "s3" { bucket = "<state-bucket>" key = "sar-tracker.tfstate" region = "us-west-2" use_lockfile = true }
```

## 4. Runbook

**DLQ alarm**: a notification failed 3 times.
1. Check logs: `aws logs tail /aws/lambda/sar-tracker-feed-builder --since 1h`.
2. If ICEYE published a malformed item, the daily re-sync skips it (counted in `backfillFailed`). Purge the DLQ after reviewing it.
3. After fixing the code, redrive: SQS console → DLQ → *Start DLQ redrive*.

**Lambda errors**: usually ICEYE or S3 being unreachable. Transient errors retry automatically. Persistent errors: check the logs, then run a backfill manually.

**Pipeline silent (no runs in 26 h)**: the EventBridge rule may be disabled, or the SNS subscription was removed.
`aws sns list-subscriptions-by-topic --topic-arn arn:aws:sns:us-west-2:058264311954:iceye-open-data-catalog-object_created` (only works if it's yours), or `terraform plan` to detect drift.

**Bad feed.json**: the bucket is versioned. Restore the previous version from the S3 console, or rerun the backfill.

## Tests

```bash
python3 -m unittest discover backend/tests -v
```

## Data & licence

Contains **ICEYE SAR Open Data**, licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
*ICEYE Synthetic Aperture Radar (SAR) Open Dataset was accessed on 2026-11-13 from https://registry.opendata.aws/iceye-opendata.*
ICEYE notes that some open samples may be experimental and may not fully match current product specifications.
