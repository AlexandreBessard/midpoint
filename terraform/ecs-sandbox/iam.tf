data "aws_iam_policy_document" "ecs_tasks_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: used by the ECS agent itself to pull the image, resolve
# `secrets` into env vars, and ship logs - not the app's own identity.
resource "aws_iam_role" "execution" {
  name_prefix        = "${var.name_prefix}-exec-"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  statement {
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.rds_password.arn,
      aws_secretsmanager_secret.admin_password.arn,
    ]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "read-sandbox-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

# Task roles: the app's own runtime identity. Neither midpoint nor ninja
# calls AWS APIs in this flow, so these stay empty except for the ECS Exec
# permissions below - present only because ECS task definitions expect a
# task_role_arn.
resource "aws_iam_role" "midpoint_task" {
  name_prefix        = "${var.name_prefix}-midpoint-task-"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

resource "aws_iam_role" "import_task" {
  name_prefix        = "${var.name_prefix}-import-task-"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

# `aws ecs execute-command` tunnels through an SSM Session Manager channel
# that the container agent opens using the task role - without this, enabling
# enable_execute_command on the service still fails to actually open a shell.
data "aws_iam_policy_document" "ecs_exec" {
  statement {
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"] # SSM Session Manager channel actions don't support resource-level restriction
  }
}

resource "aws_iam_role_policy" "midpoint_task_ecs_exec" {
  name   = "ecs-exec"
  role   = aws_iam_role.midpoint_task.id
  policy = data.aws_iam_policy_document.ecs_exec.json
}

# --- GitHub Actions OIDC: lets .github/workflows/release.yml assume an AWS
# role to push images to ECR, with no long-lived AWS keys stored in GitHub.
#
# NOTE: an OIDC provider for a given URL is a single, account-wide resource.
# If this AWS account already trusts token.actions.githubusercontent.com
# (e.g. from another project's Terraform), importing that existing provider
# instead of creating a second one here.

data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # AWS requires every trust policy for this provider to scope `sub` (or
    # job_workflow_ref) to something other than "all" - a repository/ref-only
    # policy is rejected with MalformedPolicyDocument. GitHub's sub claim now
    # embeds immutable owner/repo IDs (repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:...)
    # instead of the plain "repo:owner/repo:ref:..." this used to be - confirmed
    # by decoding the actual token in CI (sub was
    # "repo:AlexandreBessard@31587248/midpoint@1424507427:ref:refs/heads/main").
    # Wildcard just the numeric IDs, which aren't worth hardcoding here.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${split("/", var.github_repository)[0]}@*/${split("/", var.github_repository)[1]}@*:ref:refs/heads/main"]
    }

    # Belt-and-suspenders on top of the sub pattern above: repository/ref are
    # separate top-level claims in the token, unaffected by the owner/repo ID
    # suffixes and any future changes to the sub format.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:repository"
      values   = [var.github_repository]
    }

    # Scoped to pushes on main only - not PRs, not other branches, not forks.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:ref"
      values   = ["refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_actions_deploy" {
  name_prefix        = "${var.name_prefix}-gha-deploy-"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json
}

# Scoped to this sandbox's own ECR repo only - matches release.yml, which
# just builds and pushes an image (no ECS/task-def/Secrets Manager access).
data "aws_iam_policy_document" "github_actions_ecr_push" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      # Needed even for a push-only flow: docker/build-push-action pushes a
      # manifest list referencing the provenance/SBOM attestation manifest,
      # and buildx reads back manifests during that push (confirmed by a real
      # CI failure: "denied: ... not authorized to perform: ecr:BatchGetImage").
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = [aws_ecr_repository.midpoint.arn]
  }
}

resource "aws_iam_role_policy" "github_actions_ecr_push" {
  name   = "push-to-ecr"
  role   = aws_iam_role.github_actions_deploy.id
  policy = data.aws_iam_policy_document.github_actions_ecr_push.json
}

# Lets release.yml's run_import/restart_midpoint jobs run the one-off import
# task and force-redeploy the midpoint service - mirrors run_import/
# restart_midpoint from .gitlab-ci.yml, minus register_task_defs (this
# sandbox's task definitions float on the :latest image tag - var.image_tag -
# rather than being re-registered per build, so there's nothing to register).
data "aws_iam_policy_document" "github_actions_ecs_deploy" {
  statement {
    actions = [
      "ecs:DescribeTasks",
      "ecs:DescribeServices",
    ]
    resources = ["*"] # ECS describe actions don't support resource-level restriction
  }

  statement {
    actions   = ["ecs:RunTask"]
    resources = ["${aws_ecs_task_definition.import.arn_without_revision}:*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.this.arn]
    }
  }

  statement {
    actions   = ["ecs:UpdateService"]
    resources = [aws_ecs_service.midpoint.id]
  }

  # RunTask uses the import task's execution/task roles - the caller needs
  # PassRole for both, scoped to the ECS tasks service to prevent reuse
  # elsewhere.
  statement {
    actions = ["iam:PassRole"]
    resources = [
      aws_iam_role.execution.arn,
      aws_iam_role.import_task.arn,
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "github_actions_ecs_deploy" {
  name   = "ecs-import-and-restart"
  role   = aws_iam_role.github_actions_deploy.id
  policy = data.aws_iam_policy_document.github_actions_ecs_deploy.json
}
