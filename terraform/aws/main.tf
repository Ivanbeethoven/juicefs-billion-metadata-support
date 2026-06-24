terraform {
  required_version = ">= 1.6.0"

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

locals {
  cluster_name = var.cluster_name
  az_count     = length(var.subnet_ids)
  common_tags = merge(
    var.tags,
    {
      Cluster = local.cluster_name
      Project = "juicefs-billion-metadata"
    }
  )
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_security_group" "tikv" {
  name        = "${local.cluster_name}-sg"
  description = "JuiceFS TiKV metadata cluster"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_cidr_blocks
  }

  ingress {
    description = "PD client"
    from_port   = 2379
    to_port     = 2379
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "PD peer"
    from_port   = 2380
    to_port     = 2380
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "TiKV client"
    from_port   = 20160
    to_port     = 20160
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "TiKV status"
    from_port   = 20180
    to_port     = 20180
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "Node exporter"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-sg"
  })
}

resource "aws_instance" "pd" {
  count         = var.pd_count
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.pd_instance_type
  subnet_id     = var.subnet_ids[count.index % local.az_count]
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.tikv.id]

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
    iops        = var.root_volume_iops
    throughput  = var.root_volume_throughput
  }

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-pd-${count.index + 1}"
    Role = "pd"
    Zone = tostring(count.index % local.az_count)
  })
}

resource "aws_instance" "tikv" {
  count         = var.tikv_count
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.tikv_instance_type
  subnet_id     = var.subnet_ids[count.index % local.az_count]
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.tikv.id]

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
    iops        = var.root_volume_iops
    throughput  = var.root_volume_throughput
  }

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-tikv-${count.index + 1}"
    Role = "tikv"
    Zone = tostring(count.index % local.az_count)
  })
}

