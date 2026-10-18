resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}-cluster"
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

locals {
  rds_jdbc_url = "jdbc:postgresql://${aws_db_instance.midpoint.address}:5432/midpoint"
}

# --- midpoint (permanent service) ---------------------------------------

resource "aws_ecs_task_definition" "midpoint" {
  family                   = "${var.name_prefix}-midpoint"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.midpoint_cpu
  memory                   = var.midpoint_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.midpoint_task.arn

  volume {
    name = "midpoint-home"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.midpoint_home.id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.midpoint_home.id
        iam             = "DISABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name      = "midpoint"
      image     = "${aws_ecr_repository.midpoint.repository_url}:${var.image_tag}"
      essential = true

      portMappings = [
        { containerPort = 8080, protocol = "tcp" }
      ]

      environment = [
        { name = "MP_SET_midpoint_repository_jdbcUsername", value = "midpoint" },
        { name = "MP_SET_midpoint_repository_jdbcUrl", value = local.rds_jdbc_url },
        { name = "MP_SET_midpoint_repository_database", value = "postgresql" },
        { name = "MP_UNSET_midpoint_repository_hibernateHbm2ddl", value = "1" },
        { name = "MP_NO_ENV_COMPAT", value = "1" },
        { name = "MP_MEM_MAX", value = var.midpoint_jvm_max_heap },
        { name = "MP_MEM_INIT", value = var.midpoint_jvm_init_heap },
      ]

      secrets = [
        { name = "MP_SET_midpoint_repository_jdbcPassword", valueFrom = aws_secretsmanager_secret.rds_password.arn },
        { name = "MP_SET_midpoint_administrator_initialPassword", valueFrom = aws_secretsmanager_secret.admin_password.arn },
      ]

      mountPoints = [
        { sourceVolume = "midpoint-home", containerPath = "/opt/midpoint/var", readOnly = false }
      ]

      # Same fix as docker-compose.yml: /midpoint/ 302-redirects to a relative
      # Location BusyBox wget can't follow - probe /actuator/health instead.
      healthCheck = {
        command     = ["CMD-SHELL", "wget --spider -q http://localhost:8080/midpoint/actuator/health || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 10
        startPeriod = 90
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.midpoint.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "midpoint"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "midpoint" {
  name                   = "${var.name_prefix}-midpoint"
  cluster                = aws_ecs_cluster.this.id
  task_definition        = aws_ecs_task_definition.midpoint.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = true # lets `aws ecs execute-command` open a shell in the running container

  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = [aws_security_group.midpoint.id]
    assign_public_ip = true
  }

  depends_on = [
    aws_efs_mount_target.midpoint_home,
    aws_iam_role_policy_attachment.execution_managed,
    aws_iam_role_policy.execution_secrets,
  ]
}

# --- midpoint-import (one-off task, run via `aws ecs run-task`) ---------

resource "aws_ecs_task_definition" "import" {
  family                   = "${var.name_prefix}-midpoint-import"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.import_cpu
  memory                   = var.import_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.import_task.arn

  container_definitions = jsonencode([
    {
      name      = "midpoint-import"
      image     = "${aws_ecr_repository.midpoint.repository_url}:${var.image_tag}"
      essential = true
      command   = ["/opt/midpoint/import-config-ecs.sh"]

      environment = [
        { name = "MIDPOINT_JDBC_URL", value = local.rds_jdbc_url },
        { name = "MIDPOINT_JDBC_USERNAME", value = "midpoint" },
      ]

      secrets = [
        { name = "MIDPOINT_JDBC_PASSWORD", valueFrom = aws_secretsmanager_secret.rds_password.arn },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.import.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "import"
        }
      }
    }
  ])
}
