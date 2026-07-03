output "profiling_host_public_ip" {
  description = "Public IP of the Universal Profiling EC2 host"
  value       = aws_instance.profiling_host.public_ip
}

output "profiling_host_instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.profiling_host.id
}

output "ssm_connect_command" {
  description = "Shell into the instance without SSH (requires aws CLI + session-manager-plugin)"
  value       = "aws ssm start-session --target ${aws_instance.profiling_host.id} --region ${var.aws_region}"
}
