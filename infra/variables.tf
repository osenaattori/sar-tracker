variable "region" {
  description = "AWS region. ICEYE's open data bucket and SNS topic are in us-west-2."
  type        = string
  default     = "us-west-2"
}

variable "name" {
  description = "Prefix for all resource names."
  type        = string
  default     = "sar-tracker"
}

variable "iceye_sns_topic_arn" {
  description = "ICEYE's public 'new open data' SNS topic (from registry.opendata.aws/iceye-opendata)."
  type        = string
  default     = "arn:aws:sns:us-west-2:058264311954:iceye-open-data-catalog-object_created"
}

variable "alert_email" {
  description = "Email for alarms and the monthly budget alert. Leave empty to skip."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget; you get an email at 80% of it."
  type        = number
  default     = 5
}

variable "reconcile_schedule" {
  description = "When the daily full re-sync runs (EventBridge schedule expression)."
  type        = string
  default     = "cron(0 3 * * ? *)"
}

variable "log_retention_days" {
  type    = number
  default = 14
}
