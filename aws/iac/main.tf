terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# vpc
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_caller_identity" "me" {}

data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# ---------- Security groups ----------
# monitoring server
resource "aws_security_group" "monitoring" {
  name   = "todo-monitoring-sg"
  vpc_id = data.aws_vpc.default.id

  # SSH: my IP + Jenkins agent (same VPC)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip, data.aws_vpc.default.cidr_block]
  }

  # Grafana, Prometheus: my IP only
  dynamic "ingress" {
    for_each = [3000, 9090]
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = [var.my_ip]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# app server
resource "aws_security_group" "app" {
  name   = "todo-app-sg"
  vpc_id = data.aws_vpc.default.id

  # SSH: my IP + Jenkins agent (same VPC)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip, data.aws_vpc.default.cidr_block]
  }

  # web app: anyone
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # metrics (backend, cadvisor, node-exporter): monitoring server only
  dynamic "ingress" {
    for_each = [8080, 8081, 9100]
    content {
      from_port       = ingress.value
      to_port         = ingress.value
      protocol        = "tcp"
      security_groups = [aws_security_group.monitoring.id]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# database: app server only
resource "aws_security_group" "rds" {
  name   = "todo-rds-sg"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
}

# ---------- RDS MySQL (private) ----------
resource "aws_db_subnet_group" "db" {
  name       = "todo-db-subnets"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_db_instance" "mysql" {
  identifier              = "todo-mysql"
  engine                  = "mysql"
  engine_version          = "8.0"
  instance_class          = var.db_instance_class
  allocated_storage       = 20
  db_name                 = "todo_db"
  username                = "todo"
  password                = var.db_password
  db_subnet_group_name    = aws_db_subnet_group.db.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  publicly_accessible     = false
  backup_retention_period = 0 # use 7 if your account allows backups
  skip_final_snapshot     = true
}

# ---------- Secrets in SSM Parameter Store ----------
# Parameter names are the environment variable names the app expects
locals {
  secrets = {
    SPRING_DATASOURCE_URL      = "jdbc:mysql://${aws_db_instance.mysql.address}:3306/todo_db"
    SPRING_DATASOURCE_USERNAME = "todo"
    SPRING_DATASOURCE_PASSWORD = var.db_password
    COHERE_API_KEY             = var.cohere_key
    SLACK_WEBHOOK_URL          = var.slack_url
    GRAFANA_ADMIN_PASSWORD     = var.grafana_password
    APP_PRIVATE_IP             = aws_instance.server["app"].private_ip
  }
}

resource "aws_ssm_parameter" "secret" {
  for_each = nonsensitive(toset(keys(local.secrets)))
  name     = "/todo/prod/${each.key}"
  type     = "SecureString"
  value    = local.secrets[each.key]
}

# ---------- IAM role (no access keys on servers) ----------
resource "aws_iam_role" "ec2" {
  name = "todo-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# GetParametersByPath is used by the Jenkins deploy stages to load all secrets at once
resource "aws_iam_role_policy" "read_secrets" {
  role = aws_iam_role.ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:GetParametersByPath", "ssm:GetParameter", "ssm:GetParameters"]
      Resource = [
        "arn:aws:ssm:${var.region}:${data.aws_caller_identity.me.account_id}:parameter/todo/prod",
        "arn:aws:ssm:${var.region}:${data.aws_caller_identity.me.account_id}:parameter/todo/prod/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "todo-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ---------- EC2: app + monitoring (same setup, so one resource with for_each) ----------
resource "aws_instance" "server" {
  for_each = {
    app        = aws_security_group.app.id
    monitoring = aws_security_group.monitoring.id
  }

  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.instance_type
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  vpc_security_group_ids = [each.value]

  root_block_device {
    volume_size = 20
  }

  # Docker + Compose from apt, AWS CLI from snap, 2 GB swap
  user_data = <<-EOT
    #!/bin/bash
    apt-get update
    apt-get install -y docker.io docker-compose-v2
    usermod -aG docker ubuntu
    snap wait system seed.loaded
    snap install aws-cli --classic
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    mkdir -p /opt/todo && chown ubuntu:ubuntu /opt/todo
  EOT

  tags = {
    Name = "todo-${each.key}"
  }
}

# ---------- Outputs ----------
output "public_ips" {
  value = { for name, server in aws_instance.server : name => server.public_ip }
}

output "private_ips" {
  value = { for name, server in aws_instance.server : name => server.private_ip }
}

output "rds_endpoint" {
  value = aws_db_instance.mysql.address
}