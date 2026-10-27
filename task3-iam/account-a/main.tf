# Apply with credentials for Account A (000000000000).
# ORDER: apply Account A first (creates roleB). Account B's roleC trust names roleB's ARN,
# and IAM rejects a trust policy whose principal does not exist yet.
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40, < 7.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

locals {
  account_b_id = "111111111111"
  group2_users = ["alice", "bob"] # the two named console+CLI users
}

############ Groups ############
resource "aws_iam_group" "group1" { name = "group1" } # CLI/programmatic only
resource "aws_iam_group" "group2" { name = "group2" } # console + CLI

############ Users ############
resource "aws_iam_user" "engine" { name = "engine" }
resource "aws_iam_user" "ci" { name = "ci" }

resource "aws_iam_user" "group2" {
  for_each = toset(local.group2_users)
  name     = each.key
}

resource "aws_iam_group_membership" "group1" {
  name  = "group1-membership"
  group = aws_iam_group.group1.name
  users = [aws_iam_user.engine.name, aws_iam_user.ci.name]
}

resource "aws_iam_group_membership" "group2" {
  name  = "group2-membership"
  group = aws_iam_group.group2.name
  users = [for u in aws_iam_user.group2 : u.name]
}

# group1 = programmatic only: engine/ci deliberately get NO login profile (no console password).
# Access keys are NOT created here: Terraform would store the secret in state. See NOTES.md.

# group2 = console access: login profiles, forced password reset on first sign-in.
# The generated password lands in state unless pgp_key is set - encrypt it in real use.
resource "aws_iam_user_login_profile" "group2" {
  for_each                = aws_iam_user.group2
  user                    = each.value.name
  password_reset_required = true
}

############ Group permissions ############
# group1 can do exactly one thing: assume roleB.
resource "aws_iam_group_policy" "group1_assume_roleB" {
  name  = "assume-roleB-only"
  group = aws_iam_group.group1.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = aws_iam_role.roleB.arn
    }]
  })
}

# group2 can assume roleA, and manage their own password / MFA / access keys.
resource "aws_iam_group_policy" "group2_access" {
  name  = "assume-roleA-and-self-service"
  group = aws_iam_group.group2.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AssumeRoleA"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = aws_iam_role.roleA.arn
      },
      {
        Sid    = "SelfServiceCredentials"
        Effect = "Allow"
        Action = [
          "iam:ChangePassword",
          "iam:GetUser",
          "iam:CreateAccessKey",
          "iam:DeleteAccessKey",
          "iam:ListAccessKeys",
          "iam:UpdateAccessKey",
          "iam:CreateVirtualMFADevice",
          "iam:EnableMFADevice",
          "iam:ListMFADevices",
          "iam:ResyncMFADevice",
          "iam:DeactivateMFADevice",
          "iam:DeleteVirtualMFADevice"
        ]
        Resource = [
          "arn:aws:iam::*:user/$${aws:username}",
          "arn:aws:iam::*:mfa/$${aws:username}"
        ]
      },
      {
        Sid      = "ListMFADevicesForSetup"
        Effect   = "Allow"
        Action   = ["iam:ListVirtualMFADevices"]
        Resource = "*"
      }
    ]
  })
}

############ roleA: admin on everything except IAM ############
data "aws_iam_policy_document" "roleA_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [for u in aws_iam_user.group2 : u.arn]
    }
    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role" "roleA" {
  name               = "roleA"
  assume_role_policy = data.aws_iam_policy_document.roleA_trust.json
}

resource "aws_iam_role_policy" "roleA_admin_except_iam" {
  name = "admin-except-iam"
  role = aws_iam_role.roleA.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "AllowEverything", Effect = "Allow", Action = "*", Resource = "*" },
      { Sid = "ExplicitlyDenyIAM", Effect = "Deny", Action = "iam:*", Resource = "*" }
    ]
  })
}

############ roleB: can ONLY assume roleC in Account B ############
data "aws_iam_policy_document" "roleB_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_user.engine.arn, aws_iam_user.ci.arn]
    }
  }
}

resource "aws_iam_role" "roleB" {
  name               = "roleB"
  assume_role_policy = data.aws_iam_policy_document.roleB_trust.json
}

resource "aws_iam_role_policy" "roleB_assume_roleC" {
  name = "assume-roleC-in-account-b"
  role = aws_iam_role.roleB.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = "arn:aws:iam::${local.account_b_id}:role/roleC"
    }]
  })
}

############ Task 4: custom least-privilege policy attached to ci ############
resource "aws_iam_user_policy" "ci" {
  name   = "ci-least-privilege"
  user   = aws_iam_user.ci.name
  policy = file("${path.module}/../../task4-ci-policy/ci-policy.json")
}

output "roleB_arn" {
  value = aws_iam_role.roleB.arn
}
