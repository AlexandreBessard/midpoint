data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  db_engine_major_version = split(".", var.db_engine_version)[0]
}

resource "aws_instance" "midpoint" {
  ami           = data.aws_ssm_parameter.al2023_ami.value
  instance_type = var.instance_type
  subnet_id     = aws_subnet.public.id

  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  key_name               = var.enable_ssh && var.ssh_key_name != "" ? var.ssh_key_name : null

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    midpoint_version = var.midpoint_version
    db_host          = aws_db_instance.midpoint.address
    db_port          = aws_db_instance.midpoint.port
    db_name          = var.db_name
    db_username      = var.db_username
    db_password      = var.db_password
    pg_major_version = local.db_engine_major_version
    efs_id           = aws_efs_file_system.midpoint_home.id
  })
  user_data_replace_on_change = true

  depends_on = [aws_db_instance.midpoint, aws_efs_mount_target.midpoint_home]

  tags = { Name = "${local.name}-ec2" }
}

resource "aws_eip" "midpoint" {
  instance = aws_instance.midpoint.id
  domain   = "vpc"

  tags = { Name = "${local.name}-ec2" }
}
