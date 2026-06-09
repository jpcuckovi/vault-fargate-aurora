resource "aws_route53_zone" "this" {
  name = var.zone_name

  vpc {
    vpc_id = var.vpc_id
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-private-zone" })
}

resource "aws_route53_record" "vault" {
  zone_id = aws_route53_zone.this.zone_id
  name    = var.record_name
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}
