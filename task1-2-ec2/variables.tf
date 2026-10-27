variable "region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "owner" {
  type    = string
  default = "venugopal"
}

variable "subnet_id" {
  type    = string
  default = null
}

variable "instances" {
  description = "The single input that drives all five instances."
  type = map(object({
    instance_type = string
    key_name      = string
    volume_type   = string
    volume_size   = number
    iops          = optional(number)
    throughput    = optional(number)
    protected     = optional(bool, false)
  }))

  # 5 instances, all different on every axis the task lists.
  # Key pairs must already exist: aws ec2 create-key-pair --key-name kp-bastion ...
  default = {
    bastion = { instance_type = "t3.micro", key_name = "kp-bastion", volume_type = "gp2", volume_size = 10 }
    app     = { instance_type = "t3.small", key_name = "kp-app", volume_type = "gp3", volume_size = 20 }
    worker  = { instance_type = "t3.medium", key_name = "kp-worker", volume_type = "standard", volume_size = 30 }
    batch   = { instance_type = "m5.large", key_name = "kp-batch", volume_type = "io1", volume_size = 40, iops = 2000 }
    db      = { instance_type = "r5.large", key_name = "kp-db", volume_type = "io2", volume_size = 50, iops = 3000, protected = true }
  }
}
