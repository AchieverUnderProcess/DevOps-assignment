# Task 2 - remote state + locking.
# Backend blocks cannot use variables: edit the values below, or pass them at init:
#   terraform init -backend-config="bucket=<your-state-bucket>" -backend-config="region=us-east-1"
# Create the bucket and lock table FIRST with ./bootstrap (the backend cannot create itself).
terraform {
  backend "s3" {
    bucket         = "CHANGE-ME-tfstate-000000000000"
    key            = "ec2-fleet/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-locks"
    encrypt        = true
  }
}
