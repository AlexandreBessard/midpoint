# midpoint-home (keystore, logs, local config) lives on EFS rather than the
# instance's root volume: it survives instance replacement/termination, and
# if this ever grows into a multi-node cluster it's already shared storage.
resource "aws_efs_file_system" "midpoint_home" {
  creation_token = "${local.name}-home"
  encrypted      = true

  tags = { Name = "${local.name}-home" }
}

resource "aws_efs_mount_target" "midpoint_home" {
  file_system_id  = aws_efs_file_system.midpoint_home.id
  subnet_id       = aws_subnet.public.id
  security_groups = [aws_security_group.efs.id]
}
