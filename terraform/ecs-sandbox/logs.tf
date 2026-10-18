resource "aws_cloudwatch_log_group" "midpoint" {
  name              = "/ecs/${var.name_prefix}/midpoint"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "import" {
  name              = "/ecs/${var.name_prefix}/midpoint-import"
  retention_in_days = var.log_retention_days
}
