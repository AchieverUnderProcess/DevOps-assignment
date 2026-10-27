provider "aws" {
  region = var.region
}

module "ec2_fleet" {
  source = "./modules/ec2-fleet"

  environment = var.environment
  owner       = var.owner
  subnet_id   = var.subnet_id
  instances   = var.instances
}
