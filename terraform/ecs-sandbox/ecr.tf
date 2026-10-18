resource "aws_ecr_repository" "midpoint" {
  name                 = "${var.name_prefix}-midpoint"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # sandbox: allow destroy even with images pushed

  image_scanning_configuration {
    scan_on_push = true
  }
}
