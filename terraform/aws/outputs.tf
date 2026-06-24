output "pd_private_ips" {
  description = "Private IPs of PD nodes."
  value       = aws_instance.pd[*].private_ip
}

output "tikv_private_ips" {
  description = "Private IPs of TiKV nodes."
  value       = aws_instance.tikv[*].private_ip
}

output "juicefs_meta_url" {
  description = "JuiceFS TiKV metadata URL."
  value       = "tikv://${join(",", [for ip in aws_instance.pd[*].private_ip : "${ip}:2379"])}/juicefs-prod"
}

output "aerospike_private_ips" {
  description = "Private IPs of optional Aerospike nodes."
  value       = aws_instance.aerospike[*].private_ip
}

output "juicefs_aerospike_meta_url" {
  description = "Experimental JuiceFS Aerospike metadata URL shape."
  value       = var.aerospike_count > 0 ? "aerospike://${join(",", [for ip in aws_instance.aerospike[*].private_ip : "${ip}:3000"])}/juicefs-prod?set=metadata" : null
}
