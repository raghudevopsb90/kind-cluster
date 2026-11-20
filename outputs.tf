output "instance_id" {
  description = "ID of the spot EC2 instance."
  value       = aws_instance.kind.id
}

output "public_ip" {
  description = "Public IPv4 address used by the remote-exec provisioner."
  value       = aws_instance.kind.public_ip
}

output "kind_context" {
  description = "kubectl context created on the instance."
  value       = "kind-${var.kind_cluster_name}"
}
