# Passwords are generated here (fixed, not left to midPoint's own
# auto-generation) so CI/ninja can authenticate without scraping logs - same
# reasoning as DEVOPS.md S6.2. Special characters are disabled on purpose:
# both passwords get interpolated into shell -D"..." constructs by
# midpoint.sh/ninja.sh (see import-config-ecs.sh comments) and a stray quote
# or backslash would break that quoting. Alphanumeric + enforced
# upper/lower/digit satisfies midPoint's default password policy without
# that risk.

resource "random_password" "rds" {
  length      = 32
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "random_password" "admin" {
  length      = 24
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "aws_secretsmanager_secret" "rds_password" {
  name                    = "${var.name_prefix}/rds-password"
  recovery_window_in_days = 0 # sandbox: allow immediate deletion on destroy
}

resource "aws_secretsmanager_secret_version" "rds_password" {
  secret_id     = aws_secretsmanager_secret.rds_password.id
  secret_string = random_password.rds.result
}

resource "aws_secretsmanager_secret" "admin_password" {
  name                    = "${var.name_prefix}/admin-password"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "admin_password" {
  secret_id     = aws_secretsmanager_secret.admin_password.id
  secret_string = random_password.admin.result
}
