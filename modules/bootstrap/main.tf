resource "aws_ecr_repository" "bootstrap" {
  name                 = "${var.name_prefix}-vault-bootstrap"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "bootstrap" {
  name              = "/ecs/${var.name_prefix}-vault-bootstrap"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-bootstrap-exec"
  assume_role_policy = data.aws_iam_policy_document.assume.json
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
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "${var.name_prefix}-bootstrap-exec-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-bootstrap-task"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "task" {
  statement {
    sid       = "WriteRecoveryKeys"
    actions   = ["secretsmanager:PutSecretValue"]
    resources = [var.recovery_secret_arn]
  }
  statement {
    sid       = "DecryptRecoverySecret"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "${var.name_prefix}-bootstrap-task"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

resource "aws_ecs_task_definition" "bootstrap" {
  family                   = "${var.name_prefix}-vault-bootstrap"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "bootstrap"
      image     = "${aws_ecr_repository.bootstrap.repository_url}:${var.image_tag}"
      essential = true

      environment = [
        { name = "AWS_REGION", value = var.region },
        { name = "VAULT_ADDR", value = var.vault_addr },
        { name = "DB_HOST", value = var.db_host },
        { name = "DB_PORT", value = tostring(var.db_port) },
        { name = "DB_NAME", value = var.db_name },
        { name = "DB_USERNAME", value = var.db_username },
        { name = "RECOVERY_SECRET_ID", value = var.recovery_secret_arn },
        { name = "RECOVERY_SHARES", value = tostring(var.recovery_shares) },
        { name = "RECOVERY_THRESHOLD", value = tostring(var.recovery_threshold) },
      ]

      secrets = [
        { name = "DB_PASSWORD", valueFrom = "${var.db_credentials_secret_arn}:password::" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.bootstrap.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "bootstrap"
        }
      }
    }
  ])

  tags = var.tags
}
