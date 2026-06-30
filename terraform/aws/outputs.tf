output "tikv_private_ips" {
  value = local.tikv_private_ips
}

output "tikv_public_ips" {
  value = aws_instance.tikv[*].public_ip
}

output "rustfs_private_ip" {
  value = local.rustfs_private_ip
}

output "rustfs_public_ip" {
  value = aws_instance.rustfs.public_ip
}

output "control_host" {
  value = aws_instance.tikv[0].public_ip
}

output "rustfs_endpoint" {
  value = local.rustfs_endpoint
}

output "meta_url" {
  value = local.meta_url
}

output "juicefs_bucket" {
  value = local.juicefs_bucket_url
}

output "generated_env_file" {
  value = abspath(local_sensitive_file.env.filename)
}

output "generated_topology_file" {
  value = abspath(local_file.tiup_topology.filename)
}

output "private_key_file" {
  value     = var.create_key_pair ? abspath(local_sensitive_file.private_key[0].filename) : null
  sensitive = true
}

output "next_steps" {
  value = [
    "source terraform/aws/generated/juicefs-aws.env",
    "scripts/run_aws_deploy.sh",
    "scripts/run_metadata_test_all_nodes.sh",
  ]
}
