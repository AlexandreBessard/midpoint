output "ecr_repository_url" {
  value = aws_ecr_repository.midpoint.repository_url
}

output "ecr_login_command" {
  value = "aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${aws_ecr_repository.midpoint.repository_url}"
}

output "docker_build_push_commands" {
  value = <<-EOT
    docker build -t ${aws_ecr_repository.midpoint.repository_url}:${var.image_tag} -f ../../Dockerfile ../..
    docker push ${aws_ecr_repository.midpoint.repository_url}:${var.image_tag}
  EOT
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "rds_endpoint" {
  value = aws_db_instance.midpoint.address
}

output "psql_command" {
  description = "Manual check from your allowed_cidr IP, after `terraform output -raw rds_password`."
  value       = "PGPASSWORD=$(terraform output -raw rds_password) psql -h ${aws_db_instance.midpoint.address} -U midpoint -d midpoint"
}

output "rds_password" {
  value     = random_password.rds.result
  sensitive = true
}

output "admin_password" {
  value     = random_password.admin.result
  sensitive = true
}

output "midpoint_ui_url_hint" {
  description = "Public IP is only known once the task is running - see `aws ecs describe-tasks` in the README walkthrough."
  value       = "http://<task-public-ip>:8080/midpoint"
}

output "bootstrap_schema_load_command" {
  description = "Run once, before the midpoint service ever starts (DEVOPS.md S6.1/S8). Uses the generated generated/bootstrap-overrides.json (see bootstrap.tf) instead of an inline --overrides string, to avoid nested shell/JSON quoting."
  value       = <<-EOT
    aws ecs run-task \
      --cluster ${aws_ecs_cluster.this.name} \
      --task-definition ${aws_ecs_task_definition.import.family} \
      --launch-type FARGATE \
      --network-configuration "awsvpcConfiguration={subnets=[${join(",", local.subnet_ids)}],securityGroups=[${aws_security_group.import.id}],assignPublicIp=ENABLED}" \
      --overrides file://generated/bootstrap-overrides.json
  EOT
}

output "create_service_note" {
  value = "The midpoint ECS service is already created by this stack (unlike DEVOPS.md S8 step 2, which assumes you create it after the schema load) - run bootstrap_schema_load_command, THEN `aws ecs update-service --cluster ${aws_ecs_cluster.this.name} --service ${aws_ecs_service.midpoint.name} --desired-count 1 --force-new-deployment` to (re)start it cleanly against the now-initialized schema."
}

output "run_import_task_command" {
  value = <<-EOT
    aws ecs run-task \
      --cluster ${aws_ecs_cluster.this.name} \
      --task-definition ${aws_ecs_task_definition.import.family} \
      --launch-type FARGATE \
      --network-configuration "awsvpcConfiguration={subnets=[${join(",", local.subnet_ids)}],securityGroups=[${aws_security_group.import.id}],assignPublicIp=ENABLED}"
  EOT
}

output "force_new_deployment_command" {
  value = "aws ecs update-service --cluster ${aws_ecs_cluster.this.name} --service ${aws_ecs_service.midpoint.name} --force-new-deployment && aws ecs wait services-stable --cluster ${aws_ecs_cluster.this.name} --services ${aws_ecs_service.midpoint.name}"
}
