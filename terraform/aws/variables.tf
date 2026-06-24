variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Cluster name used for tags and resource names."
  type        = string
  default     = "juicefs-tikv-meta-prod"
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets across availability zones."
  type        = list(string)
}

variable "key_name" {
  description = "EC2 key pair name."
  type        = string
}

variable "ssh_cidr_blocks" {
  description = "CIDR blocks allowed to SSH to nodes."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "pd_count" {
  description = "PD node count."
  type        = number
  default     = 3
}

variable "tikv_count" {
  description = "TiKV node count."
  type        = number
  default     = 24
}

variable "pd_instance_type" {
  description = "PD EC2 instance type."
  type        = string
  default     = "m7i.xlarge"
}

variable "tikv_instance_type" {
  description = "TiKV EC2 instance type."
  type        = string
  default     = "i4i.8xlarge"
}

variable "root_volume_size_gb" {
  description = "Root volume size in GiB."
  type        = number
  default     = 200
}

variable "root_volume_iops" {
  description = "Root gp3 IOPS."
  type        = number
  default     = 6000
}

variable "root_volume_throughput" {
  description = "Root gp3 throughput in MB/s."
  type        = number
  default     = 250
}

variable "tags" {
  description = "Additional tags."
  type        = map(string)
  default     = {}
}

