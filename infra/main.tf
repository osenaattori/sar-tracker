# ICEYE SAR tracker
#
#   ICEYE SNS topic ──► SQS queue ──► Lambda ──► S3 (feed.json, status.json) ──► CloudFront ──► iPhone app
#                        │  └► DLQ (after 3 failures)
#   EventBridge daily ───┘──────────► Lambda {"backfill": true}  (self-healing re-sync)
#   CloudWatch alarms + budget ──► SNS email

data "aws_caller_identity" "me" {}

locals {
  alarms_enabled = var.alert_email != ""
}

# ------------------------------------------------------------- feed bucket --

resource "aws_s3_bucket" "feed" {
  bucket_prefix = "${var.name}-feed-"
  force_destroy = true # contents are fully rebuildable by the backfill job
}

resource "aws_s3_bucket_public_access_block" "feed" {
  bucket                  = aws_s3_bucket.feed.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "feed" {
  bucket = aws_s3_bucket.feed.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "feed" {
  bucket = aws_s3_bucket.feed.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "feed" {
  bucket = aws_s3_bucket.feed.id
  versioning_configuration {
    status = "Enabled" # roll back a bad feed.json in seconds
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "feed" {
  bucket = aws_s3_bucket.feed.id
  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

# -------------------------------------------------------------- CloudFront --
# The bucket stays private; only CloudFront can read it (Origin Access Control).

resource "aws_cloudfront_origin_access_control" "feed" {
  name                              = "${var.name}-feed"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_response_headers_policy" "security" {
  name = "Managed-SecurityHeadersPolicy"
}

resource "aws_cloudfront_distribution" "feed" {
  enabled         = true
  comment         = "${var.name} feed"
  price_class     = "PriceClass_100"
  is_ipv6_enabled = true

  origin {
    domain_name              = aws_s3_bucket.feed.bucket_regional_domain_name
    origin_id                = "feed"
    origin_access_control_id = aws_cloudfront_origin_access_control.feed.id
  }

  default_cache_behavior {
    target_origin_id           = "feed"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
    minimum_protocol_version       = "TLSv1.2_2021"
  }
}

data "aws_iam_policy_document" "feed_bucket" {
  statement {
    sid       = "CloudFrontReadOnly"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.feed.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.feed.arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.feed.arn, "${aws_s3_bucket.feed.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "feed" {
  bucket     = aws_s3_bucket.feed.id
  policy     = data.aws_iam_policy_document.feed_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.feed]
}

# ------------------------------------------------------------- SQS buffer --

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name}-dlq"
  message_retention_seconds = 1209600 # 14 days to investigate
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "events" {
  name                       = "${var.name}-events"
  visibility_timeout_seconds = 180 # > Lambda timeout for event processing
  message_retention_seconds  = 345600
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}

data "aws_iam_policy_document" "events_queue" {
  statement {
    sid       = "AllowIceyeTopic"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.events.arn]
    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.iceye_sns_topic_arn]
    }
  }
}

resource "aws_sqs_queue_policy" "events" {
  queue_url = aws_sqs_queue.events.id
  policy    = data.aws_iam_policy_document.events_queue.json
}

# Cross-account subscription to ICEYE's public topic.
resource "aws_sns_topic_subscription" "iceye" {
  topic_arn = var.iceye_sns_topic_arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.events.arn
  # Only new STAC items matter; other uploads (GeoTIFFs etc.) are filtered out
  # in the Lambda, so no filter policy is needed on the topic side.
  depends_on = [aws_sqs_queue_policy.events]
}

# ------------------------------------------------------------------ Lambda --

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/../backend/lambda/handler.py"
  output_path = "${path.module}/build/lambda.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name}-feed-builder"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name}-feed-builder"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# Least privilege: read/write only the two feed objects, consume one queue,
# write to its own log group.
data "aws_iam_policy_document" "lambda" {
  statement {
    sid     = "FeedObjects"
    actions = ["s3:GetObject", "s3:PutObject"]
    resources = [
      "${aws_s3_bucket.feed.arn}/feed.json",
      "${aws_s3_bucket.feed.arn}/status.json",
    ]
  }
  statement {
    sid       = "ListForNoSuchKey"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.feed.arn]
  }
  statement {
    sid = "ConsumeQueue"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.events.arn]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }
}

resource "aws_iam_role_policy" "lambda" {
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

resource "aws_lambda_function" "feed_builder" {
  function_name    = "${var.name}-feed-builder"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 300 # backfill fetches ~700 STAC items in parallel
  memory_size      = 512

  environment {
    variables = {
      FEED_BUCKET = aws_s3_bucket.feed.id
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda.name
  }

  depends_on = [aws_iam_role_policy.lambda]
}

resource "aws_lambda_event_source_mapping" "events" {
  event_source_arn                   = aws_sqs_queue.events.arn
  function_name                      = aws_lambda_function.feed_builder.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 30 # ICEYE uploads arrive in bursts
  function_response_types            = []

  scaling_config {
    maximum_concurrency = 2 # small, and feed writes use S3 conditional writes anyway
  }
}

# ----------------------------------------------------- daily reconciliation --

resource "aws_cloudwatch_event_rule" "reconcile" {
  name                = "${var.name}-daily-reconcile"
  description         = "Full re-sync from ICEYE's STAC catalog in case a notification was missed"
  schedule_expression = var.reconcile_schedule
}

resource "aws_cloudwatch_event_target" "reconcile" {
  rule  = aws_cloudwatch_event_rule.reconcile.name
  arn   = aws_lambda_function.feed_builder.arn
  input = jsonencode({ backfill = true })
}

resource "aws_lambda_permission" "reconcile" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.feed_builder.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.reconcile.arn
}

# -------------------------------------------------------- alarms & budget --

resource "aws_sns_topic" "alerts" {
  count             = local.alarms_enabled ? 1 : 0
  name              = "${var.name}-alerts"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "alert_email" {
  count     = local.alarms_enabled ? 1 : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email # you must click the confirmation email
}

resource "aws_cloudwatch_metric_alarm" "dlq" {
  count               = local.alarms_enabled ? 1 : 0
  alarm_name          = "${var.name}-dlq-not-empty"
  alarm_description   = "Notifications failed 3 times. See README runbook: 'DLQ alarm'."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts[0].arn]
  ok_actions          = [aws_sns_topic.alerts[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  count               = local.alarms_enabled ? 1 : 0
  alarm_name          = "${var.name}-lambda-errors"
  alarm_description   = "Feed builder is failing. See README runbook: 'Lambda errors'."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.feed_builder.function_name }
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 2
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "reconcile_missing" {
  count               = local.alarms_enabled ? 1 : 0
  alarm_name          = "${var.name}-no-runs-26h"
  alarm_description   = "The feed builder has not run for over a day. See README runbook: 'Pipeline silent'."
  namespace           = "AWS/Lambda"
  metric_name         = "Invocations"
  dimensions          = { FunctionName = aws_lambda_function.feed_builder.function_name }
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 26
  datapoints_to_alarm = 26
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts[0].arn]
}

resource "aws_budgets_budget" "monthly" {
  count        = local.alarms_enabled ? 1 : 0
  name         = "${var.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$sar-tracker"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

# ---------------------------------------------------------------- dashboard --

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = var.name
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title   = "New ICEYE scenes found"
          region  = var.region
          stat    = "Sum"
          period  = 3600
          metrics = [["SarTracker", "NewScenes"]]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Lambda invocations / errors"
          region = var.region
          stat   = "Sum"
          period = 3600
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.feed_builder.function_name],
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.feed_builder.function_name],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "Queue depth (events / DLQ)"
          region = var.region
          stat   = "Maximum"
          period = 300
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.events.name],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.dlq.name],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title   = "Lambda duration (p95, ms)"
          region  = var.region
          stat    = "p95"
          period  = 3600
          metrics = [["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.feed_builder.function_name]]
        }
      },
    ]
  })
}
