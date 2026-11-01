variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-west-3"
}

variable "project_name" {
  description = "Name prefix applied to all resources"
  type        = string
  default     = "midpoint"
}

variable "environment" {
  description = "Environment tag (dev/staging/prod)"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for the dedicated VPC"
  type        = string
  default     = "10.42.0.0/16"
}

variable "admin_cidr" {
  description = "CIDR allowed to reach the midPoint web UI (and SSH if enabled). Set to your own IP/32, never 0.0.0.0/0."
  type        = string
}

variable "enable_ssh" {
  description = "Whether to open port 22 to admin_cidr. If false, use SSM Session Manager instead (no key pair needed)."
  type        = bool
  default     = false
}

variable "ssh_key_name" {
  description = "Existing EC2 key pair name for SSH access. Only used if enable_ssh is true."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type running midPoint (single node)"
  type        = string
  default     = "t3.large"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB (holds /opt/midpoint, including midpoint-home)"
  type        = number
  default     = 40
}

variable "midpoint_version" {
  description = "midPoint version to install"
  type        = string
  default     = "4.10.5"
}

variable "db_name" {
  description = "Initial PostgreSQL database name"
  type        = string
  default     = "midpoint"
}

variable "db_username" {
  description = "RDS master username (also used as the midPoint repository JDBC user)"
  type        = string
  default     = "midpoint"
}

variable "db_password" {
  description = "RDS master password (also used as the midPoint repository JDBC password). Set via terraform.tfvars or TF_VAR_db_password env var, never commit it."
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.medium"
}

variable "db_allocated_storage_gb" {
  description = "RDS allocated storage in GB"
  type        = number
  default     = 20
}

variable "db_engine_version" {
  description = "PostgreSQL engine version. Check availability with: aws rds describe-db-engine-versions --engine postgres"
  type        = string
  default     = "16.15"
}

variable "db_skip_final_snapshot" {
  description = "Skip final RDS snapshot on destroy (set false for anything you care about keeping)"
  type        = bool
  default     = true
}
