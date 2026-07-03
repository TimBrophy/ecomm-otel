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

resource "aws_iam_role" "profiling_host" {
  name = "ecomm-otel-profiling-host"

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
  role       = aws_iam_role.profiling_host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "profiling_host" {
  name = "ecomm-otel-profiling-host"
  role = aws_iam_role.profiling_host.name
  tags = local.required_tags
}

# ── Security group ─────────────────────────────────────────────────────────────

resource "aws_security_group" "profiling_host" {
  name_prefix = "ecomm-otel-profiling-host-"
  description = "ecomm-otel profiling host"
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

# ── EC2 instance ───────────────────────────────────────────────────────────────

resource "aws_instance" "profiling_host" {
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.profiling_host.id]
  iam_instance_profile        = aws_iam_instance_profile.profiling_host.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    fleet_url        = var.fleet_url
    enrollment_token = var.fleet_enrollment_token
    agent_version    = var.agent_version
  })

  tags = merge(local.required_tags, { Name = "ecomm-otel-profiling-host" })
}
