variable "aws_region" {
  description = "AWS region for the sandbox."
  type        = string
  default     = "eu-west-1"
}

variable "name_prefix" {
  description = "Prefix applied to every resource name, to keep this sandbox identifiable and easy to find/destroy."
  type        = string
  default     = "midpoint-sandbox"
}

variable "allowed_cidr" {
  description = "Your IPv4 address in CIDR form (e.g. 203.0.113.4/32), allowed to reach midPoint's UI (8080) and RDS (5432) directly for manual checks. Find yours with `curl -s -4 ifconfig.me` (the -4 matters: plain `curl ifconfig.me` may return IPv6, which this IPv4-only sandbox can't use). Never use 0.0.0.0/0 here."
  type        = string

  validation {
    condition     = can(regex("^(\\d{1,3}\\.){3}\\d{1,3}/\\d{1,2}$", var.allowed_cidr)) && can(cidrhost(var.allowed_cidr, 0)) && var.allowed_cidr != "0.0.0.0/0"
    error_message = "allowed_cidr must be an IPv4 CIDR with a prefix length, e.g. 203.0.113.4/32 (not 0.0.0.0/0, and not an IPv6 address - get one with `curl -s -4 ifconfig.me`)."
  }
}

variable "image_tag" {
  description = "Tag of the midpoint image to deploy (pushed to the ECR repo this stack creates)."
  type        = string
  default     = "latest"
}

variable "rds_engine_version" {
  description = "Postgres engine version. Verified available in eu-west-1 on 2026-10-06 (16.9-16.15); re-check if you change region: aws rds describe-db-engine-versions --engine postgres --region <region> --query 'DBEngineVersions[].EngineVersion'"
  type        = string
  default     = "16.9"
}

variable "rds_instance_class" {
  description = "RDS instance class - smallest/cheapest suitable for a throwaway test."
  type        = string
  default     = "db.t4g.micro"
}

variable "midpoint_cpu" {
  description = "Fargate vCPU units for the midpoint service task (1024 = 1 vCPU)."
  type        = number
  default     = 1024
}

variable "midpoint_memory" {
  description = "Fargate memory (MiB) for the midpoint service task. Must leave headroom above midpoint_jvm_max_heap for JVM overhead (metaspace, threads, native buffers)."
  type        = number
  default     = 4096
}

variable "midpoint_jvm_max_heap" {
  description = "Value passed as MP_MEM_MAX (JVM -Xmx) for the midpoint service container. Default image sets 4096M, too tight for a small sandbox task - lowered here."
  type        = string
  default     = "2560m"
}

variable "midpoint_jvm_init_heap" {
  description = "Value passed as MP_MEM_INIT (JVM -Xms) for the midpoint service container."
  type        = string
  default     = "512m"
}

variable "import_cpu" {
  description = "Fargate vCPU units for the one-off midpoint-import task."
  type        = number
  default     = 512
}

variable "import_memory" {
  description = "Fargate memory (MiB) for the one-off midpoint-import task."
  type        = number
  default     = 1024
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for both task definitions. Short on purpose - this is a disposable sandbox."
  type        = number
  default     = 1
}
