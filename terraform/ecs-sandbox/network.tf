# Reuses the account's default VPC/subnets on purpose: this is a throwaway
# sandbox, not meant to model ANETT-DEV's real network. Subnets are the
# default VPC's public ones, so Fargate tasks get a public IP directly and we
# avoid paying for a NAT Gateway.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  # At least 2 subnets (different AZs) are required for the RDS subnet group.
  subnet_ids = slice(data.aws_subnets.default.ids, 0, min(2, length(data.aws_subnets.default.ids)))
}

resource "aws_security_group" "midpoint" {
  name_prefix = "${var.name_prefix}-midpoint-"
  description = "midPoint ECS service - inbound UI access, outbound to RDS/EFS/ECR/Secrets/Logs"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "midPoint UI (manual checks only)"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    description = "all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "import" {
  name_prefix = "${var.name_prefix}-import-"
  description = "midpoint-import task - outbound to RDS/ECR/Secrets/Logs only, no inbound (DEVOPS.md S7: it never calls the midpoint API)"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "rds" {
  name_prefix = "${var.name_prefix}-rds-"
  description = "RDS Postgres - inbound 5432 from midpoint, midpoint-import, and the operator (manual checks)"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "from midpoint service"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.midpoint.id]
  }

  ingress {
    description     = "from midpoint-import task"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.import.id]
  }

  ingress {
    description = "operator (psql / manual checks)"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "efs" {
  name_prefix = "${var.name_prefix}-efs-"
  description = "EFS mount targets - inbound NFS from midpoint only (midpoint-import uses a throwaway home dir, no EFS, see DEVOPS.md S4)"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "NFS from midpoint service"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.midpoint.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}
