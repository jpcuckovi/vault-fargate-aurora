data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: pull image, write logs, read the injected secret.
resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-vault-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_credentials_secret_arn]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = [var.kms_data_key_arn]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "${var.name_prefix}-vault-exec-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

# Task role: the running Vault process. Needs KMS for auto-unseal only.
resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-vault-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "task_kms" {
  statement {
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [var.seal_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "task_kms" {
  name   = "${var.name_prefix}-vault-task-kms"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_kms.json
}
