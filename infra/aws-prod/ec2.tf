data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ── IAM role for SSM access (no SSH key needed) ───────────────────────────────

resource "aws_iam_role" "prod_app" {
  name = "ecomm-otel-prod-app"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = local.required_tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.prod_app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "prod_app" {
  name = "ecomm-otel-prod-app"
  role = aws_iam_role.prod_app.name
  tags = local.required_tags
}

# ── Security group ────────────────────────────────────────────────────────────
# Egress only. The value of this host is the telemetry it forwards to Elastic
# Cloud, not inbound access to the storefront — so nothing is exposed publicly.
# Access for debugging is via SSM (no open ports). If you want to browse the
# storefront live, add a scoped ingress rule for your own IP on 3000.

resource "aws_security_group" "prod_app" {
  name_prefix = "ecomm-otel-prod-app-"
  description = "ecomm-otel prod app host"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.required_tags

  lifecycle {
    create_before_destroy = true
  }
}

# ── EC2 instance ──────────────────────────────────────────────────────────────

resource "aws_instance" "prod_app" {
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = var.prod_instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.prod_app.id]
  iam_instance_profile        = aws_iam_instance_profile.prod_app.name
  associate_public_ip_address = true
  key_name                    = var.key_pair_name != "" ? var.key_pair_name : null

  # Root volume sized for building/running ~10 container images.
  root_block_device {
    volume_size = 40
    volume_type = "gp3"
  }

  # NOTE: the ingest API key is passed via user_data (base64, readable via the
  # instance-metadata / describe-instance-attribute API to principals with EC2
  # read access). Consistent with how infra/aws passes the Fleet token today.
  # Hardening path: store the key in AWS Secrets Manager and fetch it on boot
  # via the instance role. Out of scope for A1.
  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    prod_repo_url   = var.prod_repo_url
    prod_repo_ref   = var.prod_repo_ref
    ingest_endpoint = var.elastic_ingest_endpoint
    ingest_api_key  = var.elastic_ingest_api_key
    aws_region      = var.aws_region
  })

  tags = merge(local.required_tags, { Name = "ecomm-otel-prod-app" })
}
