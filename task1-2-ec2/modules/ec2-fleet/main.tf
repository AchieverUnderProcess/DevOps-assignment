data "aws_ami" "al2023" {
  count       = var.ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

locals {
  ami_id = coalesce(var.ami_id, one(data.aws_ami.al2023[*].id))

  common_tags = {
    Environment = var.environment
    Owner       = var.owner
  }

  # lifecycle { prevent_destroy } must be a literal true/false. It cannot be set
  # per-element inside a single for_each block. So the single input variable is
  # split into two maps by the `protected` flag, each feeding its own resource block.
  protected_instances   = { for name, cfg in var.instances : name => cfg if cfg.protected }
  unprotected_instances = { for name, cfg in var.instances : name => cfg if !cfg.protected }
}

resource "aws_instance" "this" {
  for_each = local.unprotected_instances

  ami                    = local.ami_id
  instance_type          = each.value.instance_type
  key_name               = each.value.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = length(var.vpc_security_group_ids) > 0 ? var.vpc_security_group_ids : null

  root_block_device {
    volume_type = each.value.volume_type
    volume_size = each.value.volume_size
    iops        = each.value.iops
    throughput  = each.value.throughput
    encrypted   = true
  }

  tags = merge(local.common_tags, { Name = each.key })
}

resource "aws_instance" "protected" {
  for_each = local.protected_instances

  ami                    = local.ami_id
  instance_type          = each.value.instance_type
  key_name               = each.value.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = length(var.vpc_security_group_ids) > 0 ? var.vpc_security_group_ids : null

  # Also blocks termination from the console/CLI, not just from Terraform.
  disable_api_termination = true

  root_block_device {
    volume_type = each.value.volume_type
    volume_size = each.value.volume_size
    iops        = each.value.iops
    throughput  = each.value.throughput
    encrypted   = true
  }

  tags = merge(local.common_tags, { Name = each.key })

  lifecycle {
    prevent_destroy = true
  }
}
