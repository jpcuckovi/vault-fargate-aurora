locals {
  az_count = length(var.azs)
}

# ---------------------------------------------------------------------------
# VPC + Internet / NAT egress
# ---------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "${var.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-igw" })
}

resource "aws_subnet" "public" {
  count                   = local.az_count
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = merge(var.tags, { Name = "${var.name_prefix}-public-${var.azs[count.index]}" })
}

resource "aws_subnet" "private" {
  count             = local.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]
  tags              = merge(var.tags, { Name = "${var.name_prefix}-private-${var.azs[count.index]}" })
}

resource "aws_eip" "nat" {
  count  = local.az_count
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-nat-${var.azs[count.index]}" })
}

resource "aws_nat_gateway" "this" {
  count         = local.az_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(var.tags, { Name = "${var.name_prefix}-nat-${var.azs[count.index]}" })
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = merge(var.tags, { Name = "${var.name_prefix}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count          = local.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  count  = local.az_count
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[count.index].id
  }
  tags = merge(var.tags, { Name = "${var.name_prefix}-private-rt-${var.azs[count.index]}" })
}

resource "aws_route_table_association" "private" {
  count          = local.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "Vault ALB - client traffic on ${var.vault_api_port}"
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-alb" })
}

resource "aws_security_group_rule" "alb_ingress_client" {
  type              = "ingress"
  security_group_id = aws_security_group.alb.id
  from_port         = var.vault_api_port
  to_port           = var.vault_api_port
  protocol          = "tcp"
  cidr_blocks       = var.client_ingress_cidrs
  description       = "Client API traffic to Vault (HTTP)"
}

resource "aws_security_group_rule" "alb_ingress_https" {
  count             = var.certificate_arn != "" ? 1 : 0
  type              = "ingress"
  security_group_id = aws_security_group.alb.id
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = var.client_ingress_cidrs
  description       = "HTTPS client traffic"
}

resource "aws_security_group_rule" "alb_ingress_http_redirect" {
  count             = var.certificate_arn != "" ? 1 : 0
  type              = "ingress"
  security_group_id = aws_security_group.alb.id
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = var.client_ingress_cidrs
  description       = "HTTP redirect to HTTPS"
}

resource "aws_security_group_rule" "alb_egress_tasks" {
  type                     = "egress"
  security_group_id        = aws_security_group.alb.id
  from_port                = var.vault_api_port
  to_port                  = var.vault_api_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.vault.id
  description              = "ALB to Vault tasks"
}

resource "aws_security_group" "vault" {
  name        = "${var.name_prefix}-vault-tasks"
  description = "Vault Fargate tasks"
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-vault-tasks" })
}

resource "aws_security_group_rule" "vault_ingress_api_from_alb" {
  type                     = "ingress"
  security_group_id        = aws_security_group.vault.id
  from_port                = var.vault_api_port
  to_port                  = var.vault_api_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  description              = "API traffic from ALB"
}

resource "aws_security_group_rule" "vault_ingress_cluster_self" {
  type              = "ingress"
  security_group_id = aws_security_group.vault.id
  from_port         = var.vault_cluster_port
  to_port           = var.vault_cluster_port
  protocol          = "tcp"
  self              = true
  description       = "Inter-node cluster / request forwarding (8201)"
}

resource "aws_security_group_rule" "vault_egress_all" {
  type              = "egress"
  security_group_id = aws_security_group.vault.id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Egress to KMS, Secrets Manager, Aurora, ECR via NAT"
}

# ---------------------------------------------------------------------------
# Application Load Balancer (client traffic on 8200)
# ---------------------------------------------------------------------------
resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  internal           = var.alb_internal
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.alb_internal ? aws_subnet.private[*].id : aws_subnet.public[*].id
  tags               = merge(var.tags, { Name = "${var.name_prefix}-alb" })
}

resource "aws_lb_target_group" "vault" {
  name        = "${var.name_prefix}-vault"
  port        = var.vault_api_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip"

  # health_check_path carries query parameters so /v1/sys/health returns 200 for
  # every alive node (active, standby, uninitialized, sealed). This target group
  # governs both ALB routing and ECS task lifecycle: a bare matcher = "200"
  # leaves a fresh Vault (501) with no healthy target (bootstrap deadlock) and
  # lets ECS kill standby tasks (429). Keep the query parameters on the path.
  health_check {
    path                = var.health_check_path
    matcher             = "200"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
    timeout             = 5
  }

  deregistration_delay = 10
  tags                 = merge(var.tags, { Name = "${var.name_prefix}-vault" })
}

resource "aws_lb_listener" "vault" {
  load_balancer_arn = aws_lb.this.arn
  port              = var.vault_api_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vault.arn
  }
  tags = var.tags
}

resource "aws_lb_listener" "https" {
  count             = var.certificate_arn != "" ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vault.arn
  }
  tags = var.tags
}

resource "aws_lb_listener" "http_redirect" {
  count             = var.certificate_arn != "" ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
  tags = var.tags
}
