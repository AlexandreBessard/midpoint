resource "aws_db_subnet_group" "midpoint" {
  name_prefix = "${var.name_prefix}-"
  subnet_ids  = local.subnet_ids
}

resource "aws_db_instance" "midpoint" {
  identifier_prefix = "${var.name_prefix}-"

  engine         = "postgres"
  engine_version = var.rds_engine_version
  instance_class = var.rds_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "midpoint"
  username = "midpoint"
  password = random_password.rds.result

  db_subnet_group_name   = aws_db_subnet_group.midpoint.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  # Public on purpose for this disposable sandbox (no bastion/VPN in this
  # stack, and psql_command in outputs.tf relies on direct reachability) -
  # access is still restricted to var.allowed_cidr by the security group.
  # The real ANETT-DEV RDS must stay private; don't carry this over.
  publicly_accessible = true

  multi_az                = false
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true
}
