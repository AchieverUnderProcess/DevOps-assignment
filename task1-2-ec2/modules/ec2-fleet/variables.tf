variable "instances" {
  description = <<-EOT
    Map of instance name => configuration. The map key becomes the Name tag
    and the key used in the outputs. One variable drives every instance.
  EOT

  type = map(object({
    instance_type = string
    key_name      = string # must be an EXISTING EC2 key pair in the region
    volume_type   = string # gp2 | gp3 | io1 | io2 | standard (st1/sc1 cannot be root volumes)
    volume_size   = number # GiB
    iops          = optional(number)
    throughput    = optional(number) # gp3 only
    protected     = optional(bool, false)
  }))

  validation {
    condition     = alltrue([for v in values(var.instances) : contains(["gp2", "gp3", "io1", "io2", "standard"], v.volume_type)])
    error_message = "volume_type must be one of gp2, gp3, io1, io2, standard (st1/sc1 cannot be used as root volumes)."
  }

  validation {
    condition     = alltrue([for v in values(var.instances) : contains(["io1", "io2"], v.volume_type) ? v.iops != null : true])
    error_message = "io1/io2 volumes require an explicit iops value."
  }

  validation {
    condition     = anytrue([for v in values(var.instances) : contains(["io1", "io2"], v.volume_type)])
    error_message = "At least one instance must use io1 or io2 root storage."
  }

  validation {
    condition     = length(distinct([for v in values(var.instances) : v.key_name])) == length(var.instances)
    error_message = "Every instance must use a different key pair."
  }

  validation {
    condition     = length(distinct([for v in values(var.instances) : v.instance_type])) == length(var.instances)
    error_message = "Every instance must use a different instance type."
  }
}

variable "environment" {
  description = "Value for the Environment tag."
  type        = string
}

variable "owner" {
  description = "Value for the Owner tag."
  type        = string
}

variable "ami_id" {
  description = "AMI to use. If null, the latest Amazon Linux 2023 x86_64 AMI is looked up."
  type        = string
  default     = null
}

variable "subnet_id" {
  description = "Subnet to launch into. If null, the default VPC is used."
  type        = string
  default     = null
}

variable "vpc_security_group_ids" {
  description = "Security groups to attach. If empty, the VPC default security group is used."
  type        = list(string)
  default     = []
}
