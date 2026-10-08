resource "aws_cloudwatch_log_group" "vault" {
  name              = "/ecs/${var.name_prefix}-vault"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}-vault"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = var.tags
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

resource "aws_ecs_task_definition" "vault" {
  family                   = "${var.name_prefix}-vault"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64" # CE 2.0.1 lacks some non-amd64 artifacts
  }

  container_definitions = jsonencode([
    {
      name      = "vault"
      image     = var.vault_image
      essential = true

      # Run as root: the entrypoint strips the cap_ipc_lock file capability from
      # the vault 2.0.x binary (which Fargate cannot grant), and setcap needs
      # CAP_SETFCAP. With disable_mlock the capability is not needed at runtime.
      user = "0"

      # Override the image entrypoint with the metadata-aware bootstrap script.
      entryPoint = ["/bin/sh", "-c", file("${path.module}/entrypoint.sh")]

      portMappings = [
        { name = "vault-api", containerPort = 8200, protocol = "tcp" },
        { name = "vault-cluster", containerPort = 8201, protocol = "tcp" },
      ]

      environment = [
        { name = "AWS_REGION", value = var.region },
        { name = "VAULT_SEAL_KMS_KEY_ID", value = var.seal_kms_key_id },
        { name = "DB_HOST", value = var.db_host },
        { name = "DB_PORT", value = tostring(var.db_port) },
        { name = "DB_NAME", value = var.db_name },
        { name = "DB_USERNAME", value = var.db_username },
        { name = "DB_SSLMODE", value = "require" },
        { name = "SKIP_SETCAP", value = "true" },
      ]

      secrets = [
        { name = "DB_PASSWORD", valueFrom = "${var.db_credentials_secret_arn}:password::" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.vault.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "vault"
        }
      }
    }
  ])

  tags = var.tags
}

resource "aws_ecs_service" "vault" {
  name                              = "${var.name_prefix}-vault"
  cluster                           = aws_ecs_cluster.this.id
  task_definition                   = aws_ecs_task_definition.vault.arn
  desired_count                     = var.desired_count
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 120

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.vault_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "vault"
    container_port   = 8200
  }

  # Service Connect exposes the cluster port (8201) for inter-node forwarding.
  service_connect_configuration {
    enabled   = true
    namespace = var.service_connect_namespace_arn

    service {
      port_name      = "vault-cluster"
      discovery_name = "vault-cluster"
      client_alias {
        port = 8201
      }
    }
  }

  lifecycle {
    ignore_changes = [desired_count] # allow failover / autoscaling to manage count
  }

  tags = var.tags
}
