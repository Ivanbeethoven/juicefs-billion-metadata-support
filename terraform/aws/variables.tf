variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name prefix for AWS resources."
  type        = string
  default     = "juicefs-3tikv"
}

variable "vpc_cidr" {
  description = "CIDR for the generated VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "azs" {
  description = "Three availability zones. Leave empty to use the first three available zones in the region."
  type        = list(string)
  default     = []
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH to instances."
  type        = list(string)
  default     = []
}

variable "expose_rustfs_console" {
  description = "Expose RustFS console port 9001 to allowed_ssh_cidrs."
  type        = bool
  default     = false
}

variable "create_key_pair" {
  description = "Create an EC2 key pair and write the private key into generated/. Set false to use key_name."
  type        = bool
  default     = true
}

variable "key_name" {
  description = "Existing EC2 key pair name when create_key_pair is false."
  type        = string
  default     = ""
}

variable "ssh_private_key_path" {
  description = "Local private key path for SSH when create_key_pair is false."
  type        = string
  default     = ""
}

variable "instance_ami_id" {
  description = "AMI ID. Leave empty to use latest Ubuntu 22.04 amd64."
  type        = string
  default     = ""
}

variable "ssh_user" {
  description = "SSH user for the selected AMI."
  type        = string
  default     = "ubuntu"
}

variable "tikv_instance_type" {
  description = "Instance type for PD+TiKV nodes."
  type        = string
  default     = "m6i.xlarge"
}

variable "rustfs_instance_type" {
  description = "Instance type for the RustFS node."
  type        = string
  default     = "m6i.xlarge"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size."
  type        = number
  default     = 80
}

variable "tikv_data_volume_size_gb" {
  description = "TiKV data EBS volume size per node."
  type        = number
  default     = 512
}

variable "rustfs_data_volume_size_gb" {
  description = "RustFS data EBS volume size."
  type        = number
  default     = 1024
}

variable "data_volume_type" {
  description = "EBS data volume type."
  type        = string
  default     = "gp3"
}

variable "data_volume_iops" {
  description = "EBS gp3 IOPS for data volumes."
  type        = number
  default     = 3000
}

variable "data_volume_throughput" {
  description = "EBS gp3 throughput MB/s for data volumes."
  type        = number
  default     = 125
}

variable "juicefs_version" {
  description = "JuiceFS CE version."
  type        = string
  default     = "1.3.1"
}

variable "juicefs_arch" {
  description = "JuiceFS binary architecture."
  type        = string
  default     = "amd64"
}

variable "tidb_version" {
  description = "TiKV/PD version deployed by TiUP."
  type        = string
  default     = "v8.5.6"
}

variable "tidb_arch" {
  description = "TiKV/PD binary architecture."
  type        = string
  default     = "amd64"
}

variable "rustfs_download_url" {
  description = "RustFS binary archive URL."
  type        = string
  default     = "https://dl.rustfs.com/artifacts/rustfs/release/rustfs-linux-x86_64-musl-latest.zip"
}

variable "rustfs_access_key" {
  description = "RustFS access key used by JuiceFS."
  type        = string
  default     = "rustfsadmin"
  sensitive   = true

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]{3,}$", var.rustfs_access_key))
    error_message = "rustfs_access_key must contain only letters, numbers, dot, underscore, or dash."
  }
}

variable "rustfs_secret_key" {
  description = "RustFS secret key used by JuiceFS."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]{16,}$", var.rustfs_secret_key))
    error_message = "rustfs_secret_key must be at least 16 characters and contain only letters, numbers, dot, underscore, or dash."
  }
}

variable "rustfs_bucket" {
  description = "Bucket created on RustFS for JuiceFS."
  type        = string
  default     = "juicefs-prod"
}

variable "jfs_name" {
  description = "JuiceFS filesystem name."
  type        = string
  default     = "juicefs-prod"
}

variable "target_total_files" {
  description = "Total small-file target for distributed metadata benchmark."
  type        = number
  default     = 1000000
}

variable "files_per_dir" {
  description = "Files per directory for mdtest."
  type        = number
  default     = 10000
}

variable "test_threads" {
  description = "mdtest threads per node."
  type        = number
  default     = 64
}

variable "common_tags" {
  description = "Extra tags applied to resources."
  type        = map(string)
  default     = {}
}
