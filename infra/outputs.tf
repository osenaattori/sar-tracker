output "feed_url" {
  description = "Paste this into the iPhone app's Settings (or Config.swift)."
  value       = "https://${aws_cloudfront_distribution.feed.domain_name}/feed.json"
}

output "status_url" {
  value = "https://${aws_cloudfront_distribution.feed.domain_name}/status.json"
}

output "lambda_name" {
  value = aws_lambda_function.feed_builder.function_name
}

output "dlq_url" {
  value = aws_sqs_queue.dlq.url
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}
