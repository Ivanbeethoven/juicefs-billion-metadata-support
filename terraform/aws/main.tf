data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  count       = var.instance_ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  azs                = length(var.azs) > 0 ? var.azs : slice(data.aws_availability_zones.available.names, 0, 3)
  ami_id             = var.instance_ami_id != "" ? var.instance_ami_id : data.aws_ami.ubuntu[0].id
  tags               = merge(var.common_tags, { Project = var.project_name })
  tikv_private_ips   = [for i in range(3) : cidrhost(cidrsubnet(var.vpc_cidr, 8, i), 11)]
  rustfs_private_ip  = cidrhost(cidrsubnet(var.vpc_cidr, 8, 0), 21)
  pd_hosts           = [for ip in local.tikv_private_ips : "${ip}:2379"]
  meta_url           = "tikv://${join(",", local.pd_hosts)}/${var.jfs_name}"
  rustfs_endpoint    = "http://${local.rustfs_private_ip}:9000"
  juicefs_bucket_url = "${local.rustfs_endpoint}/${var.rustfs_bucket}"
  target_per_node    = ceil(var.target_total_files / 4)
  key_name           = var.create_key_pair ? aws_key_pair.generated[0].key_name : var.key_name
  run_dir            = abspath("${path.module}/../../run/${var.project_name}")
}

resource "tls_private_key" "generated" {
  count     = var.create_key_pair ? 1 : 0
  algorithm = "ED25519"
}

resource "aws_key_pair" "generated" {
  count      = var.create_key_pair ? 1 : 0
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.generated[0].public_key_openssh
  tags       = local.tags
}

resource "local_sensitive_file" "private_key" {
  count           = var.create_key_pair ? 1 : 0
  filename        = "${local.run_dir}/${var.project_name}.pem"
  content         = tls_private_key.generated[0].private_key_openssh
  file_permission = "0600"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = merge(local.tags, { Name = var.project_name })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = var.project_name })
}

resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags = merge(local.tags, {
    Name = "${var.project_name}-public-${count.index + 1}"
    Role = "public"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${var.project_name}-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "cluster" {
  name        = "${var.project_name}-cluster"
  description = "JuiceFS TiKV RustFS test cluster"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.tags, { Name = "${var.project_name}-cluster" })
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each          = toset(var.allowed_ssh_cidrs)
  security_group_id = aws_security_group.cluster.id
  cidr_ipv4         = each.value
  from_port         = 22
  ip_protocol       = "tcp"
  to_port           = 22
  description       = "SSH"
}

resource "aws_vpc_security_group_ingress_rule" "internal_all" {
  security_group_id            = aws_security_group.cluster.id
  referenced_security_group_id = aws_security_group.cluster.id
  ip_protocol                  = "-1"
  description                  = "Cluster internal traffic"
}

resource "aws_vpc_security_group_ingress_rule" "rustfs_console" {
  for_each          = var.expose_rustfs_console ? toset(var.allowed_ssh_cidrs) : toset([])
  security_group_id = aws_security_group.cluster.id
  cidr_ipv4         = each.value
  from_port         = 9001
  ip_protocol       = "tcp"
  to_port           = 9001
  description       = "RustFS console"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.cluster.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Outbound"
}

resource "aws_instance" "tikv" {
  count                       = 3
  ami                         = local.ami_id
  instance_type               = var.tikv_instance_type
  subnet_id                   = aws_subnet.public[count.index].id
  private_ip                  = local.tikv_private_ips[count.index]
  vpc_security_group_ids      = [aws_security_group.cluster.id]
  key_name                    = local.key_name
  associate_public_ip_address = true
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    role                = "tikv"
    hostname            = "${var.project_name}-tikv-${count.index + 1}"
    data_mount          = "/data/tikv"
    juicefs_version     = var.juicefs_version
    juicefs_arch        = var.juicefs_arch
    rustfs_download_url = var.rustfs_download_url
    rustfs_access_key   = var.rustfs_access_key
    rustfs_secret_key   = var.rustfs_secret_key
    rustfs_bucket       = var.rustfs_bucket
  })

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  ebs_block_device {
    device_name           = "/dev/sdf"
    volume_size           = var.tikv_data_volume_size_gb
    volume_type           = var.data_volume_type
    iops                  = var.data_volume_type == "gp3" ? var.data_volume_iops : null
    throughput            = var.data_volume_type == "gp3" ? var.data_volume_throughput : null
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(local.tags, {
    Name = "${var.project_name}-tikv-${count.index + 1}"
    Role = "tikv"
    Zone = local.azs[count.index]
  })
}

resource "aws_instance" "rustfs" {
  ami                         = local.ami_id
  instance_type               = var.rustfs_instance_type
  subnet_id                   = aws_subnet.public[0].id
  private_ip                  = local.rustfs_private_ip
  vpc_security_group_ids      = [aws_security_group.cluster.id]
  key_name                    = local.key_name
  associate_public_ip_address = true
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    role                = "rustfs"
    hostname            = "${var.project_name}-rustfs-1"
    data_mount          = "/data/rustfs"
    juicefs_version     = var.juicefs_version
    juicefs_arch        = var.juicefs_arch
    rustfs_download_url = var.rustfs_download_url
    rustfs_access_key   = var.rustfs_access_key
    rustfs_secret_key   = var.rustfs_secret_key
    rustfs_bucket       = var.rustfs_bucket
  })

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  ebs_block_device {
    device_name           = "/dev/sdf"
    volume_size           = var.rustfs_data_volume_size_gb
    volume_type           = var.data_volume_type
    iops                  = var.data_volume_type == "gp3" ? var.data_volume_iops : null
    throughput            = var.data_volume_type == "gp3" ? var.data_volume_throughput : null
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(local.tags, {
    Name = "${var.project_name}-rustfs-1"
    Role = "rustfs"
    Zone = local.azs[0]
  })
}

resource "local_file" "tiup_topology" {
  filename = "${local.run_dir}/topology.aws.generated.yaml"
  content = templatefile("${path.module}/templates/topology.yaml.tftpl", {
    tikv_private_ips = local.tikv_private_ips
    zones            = local.azs
  })
}

resource "local_sensitive_file" "env" {
  filename        = "${local.run_dir}/juicefs-aws.env"
  file_permission = "0600"
  content = templatefile("${path.module}/templates/env.tftpl", {
    tidb_version          = var.tidb_version
    tidb_arch             = var.tidb_arch
    cluster_name          = var.project_name
    topology              = abspath(local_file.tiup_topology.filename)
    ssh_user              = var.ssh_user
    ssh_key               = var.create_key_pair ? abspath(local_sensitive_file.private_key[0].filename) : var.ssh_private_key_path
    pd_endpoint           = "http://${local.tikv_private_ips[0]}:2379"
    juicefs_version       = var.juicefs_version
    juicefs_arch          = var.juicefs_arch
    jfs_name              = var.jfs_name
    meta_url              = local.meta_url
    jfs_bucket            = local.juicefs_bucket_url
    rustfs_endpoint       = local.rustfs_endpoint
    rustfs_bucket         = var.rustfs_bucket
    rustfs_access_key     = var.rustfs_access_key
    rustfs_secret_key     = var.rustfs_secret_key
    control_host          = aws_instance.tikv[0].public_ip
    juicefs_test_hosts    = join(" ", concat(aws_instance.tikv[*].public_ip, [aws_instance.rustfs.public_ip]))
    target_files_per_node = local.target_per_node
    files_per_dir         = var.files_per_dir
    test_threads          = var.test_threads
  })
}
