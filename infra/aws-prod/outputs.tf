output "prod_host_public_ip" {
  description = "Public IP of the prod app EC2 host"
  value       = aws_instance.prod_app.public_ip
}

output "prod_host_instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.prod_app.id
}

output "ssm_connect_command" {
  description = "Shell into the instance without SSH (requires aws CLI + session-manager-plugin)"
  value       = "aws ssm start-session --target ${aws_instance.prod_app.id} --region ${var.aws_region}"
}
