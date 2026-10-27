output "instance_ids" {
  description = "Map of instance name => instance ID."
  value = merge(
    { for name, i in aws_instance.this : name => i.id },
    { for name, i in aws_instance.protected : name => i.id },
  )
}

output "private_ips" {
  description = "Map of instance name => private IP."
  value = merge(
    { for name, i in aws_instance.this : name => i.private_ip },
    { for name, i in aws_instance.protected : name => i.private_ip },
  )
}
