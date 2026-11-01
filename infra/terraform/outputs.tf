output "midpoint_url_http" {
  value = "http://${aws_eip.midpoint.public_ip}:8080/midpoint"
}

output "midpoint_url_https" {
  value = "https://${aws_eip.midpoint.public_ip}:8443/midpoint"
}

output "ec2_instance_id" {
  value = aws_instance.midpoint.id
}

output "ec2_public_ip" {
  value = aws_eip.midpoint.public_ip
}

output "ssm_connect_command" {
  value = "aws ssm start-session --target ${aws_instance.midpoint.id} --region ${var.aws_region}"
}

output "rds_endpoint" {
  value = aws_db_instance.midpoint.endpoint
}

output "db_password" {
  value     = var.db_password
  sensitive = true
}

output "efs_file_system_id" {
  value = aws_efs_file_system.midpoint_home.id
}

output "bootstrap_log_hint" {
  value = "After connecting (SSM or SSH), check /var/log/midpoint-bootstrap.log for install progress and 'journalctl -u midpoint -f' for app logs."
}
