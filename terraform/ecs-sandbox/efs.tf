# Mirrors docker-compose.yml's midpoint_home volume: config.xml, keystore,
# logs, and (in the real deployment) the CEGID/ADP/HQZ CSV feeds. Only the
# "midpoint" service mounts this - midpoint-import uses its own throwaway
# MIDPOINT_HOME inside the container (see DEVOPS.md S4), no EFS needed there.

resource "aws_efs_file_system" "midpoint_home" {
  creation_token = "${var.name_prefix}-midpoint-home"
  encrypted      = true

  lifecycle_policy {
    transition_to_ia = "AFTER_7_DAYS"
  }
}

resource "aws_efs_mount_target" "midpoint_home" {
  for_each = toset(local.subnet_ids)

  file_system_id  = aws_efs_file_system.midpoint_home.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_access_point" "midpoint_home" {
  file_system_id = aws_efs_file_system.midpoint_home.id

  posix_user {
    uid = 0 # midpoint container now runs as root (Dockerfile fix, see DEVOPS.md/CLAUDE context)
    gid = 0
  }

  root_directory {
    path = "/midpoint-home"
    creation_info {
      owner_uid   = 0
      owner_gid   = 0
      permissions = "0755"
    }
  }
}
