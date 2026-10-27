# DevOps Assignment - Notes

Built with AI assistance. Validation runs automatically via `.github/workflows/validate.yml`. Assumptions are stated where the brief was ambiguous.

## Layout

```
task1-2-ec2/        Terraform root + modules/ec2-fleet (Task 1), backend.tf + bootstrap/ (Task 2)
task3-iam/          account-a/ (groups, users, roleA, roleB) and account-b/ (roleC)
task4-ci-policy/    ci-policy.json (least-privilege policy for the ci user)
task5-bugfix/       fixed.tf (corrected) and broken.tf.txt (original snippet, kept as .txt so it does not clash)
```

---

## Task 1 - Multi-instance EC2

**How it works:** one variable, `instances`, is a map of name -> config (type, key pair, root volume type/size/iops, `protected` flag). The module uses `for_each` over it. The 5 defaults differ on every axis:

| name | type | root volume | size | key pair |
|---|---|---|---|---|
| bastion | t3.micro | gp2 | 10 | kp-bastion |
| app | t3.small | gp3 | 20 | kp-app |
| worker | t3.medium | standard | 30 | kp-worker |
| batch | m5.large | io1 (2000 iops) | 40 | kp-batch |
| db | r5.large | io2 (3000 iops) | 50 | kp-db |

Validation blocks enforce: at least one io1/io2, io1/io2 must set iops, no duplicate key pairs or instance types. Tags (`Name`, `Environment`, `Owner`) are applied to every instance. Outputs `instance_ids` and `private_ips` are maps of name -> value.

**Protected instance: `db`.** It is the only stateful node (the io2 volume is the expensive, tuned one and holds data that cannot be rebuilt from code). The other four are stateless and recreatable, so an accidental destroy there is an inconvenience; on `db` it is data loss.

**Why there are two resource blocks:** `lifecycle { prevent_destroy }` only accepts a literal `true`/`false`, so it cannot vary per element inside one `for_each`. I split the single input map into protected and unprotected maps with a `protected` flag, and each feeds its own `aws_instance` block. Outputs merge the two. The input is still one variable.

**Limits of prevent_destroy (worth knowing):**
- It only stops Terraform plans that would destroy the resource. Deleting the resource block from the code removes the lifecycle rule with it, and it does nothing against the console or CLI. That is why `db` also sets `disable_api_termination = true`, which blocks termination at the AWS API level.
- Flipping `protected` on an existing instance changes its address (`this[...]` <-> `protected[...]`), which Terraform sees as destroy + create. Use a `moved` block or `terraform state mv`.
- To tear the whole thing down, remove `prevent_destroy` and `disable_api_termination` from the protected block and apply first.

**Prerequisites:** the five key pairs must already exist in the region. I did not create them in Terraform, because generating them there would put private keys in state. The default AMI is the latest Amazon Linux 2023 x86_64. Cost note: r5.large and m5.large are not free-tier, so destroy after testing.

---

## Task 2 - Remote state and locking

**Setup:** `bootstrap/` creates the S3 bucket (versioned, encrypted, public access blocked) and a DynamoDB table (`LockID` string hash key, on-demand billing). It is applied once with local state, because a backend cannot create itself. `backend.tf` in the root config points at them, then `terraform init -migrate-state` moves existing state to S3.

**What happens today with local state if two people run apply at the same time:**
Each person has their own `terraform.tfstate` on their own machine, so neither knows what the other is doing. Both plan against a stale view, both try to create the same 5 instances, and you get duplicate instances or "already exists" errors. Afterwards there are two diverging state files, each missing the other's resources, so later applies or destroys leave orphans or try to recreate things. If they share one directory (shared drive, or a state file committed to git), the only lock is a local file lock on that one filesystem. It is unreliable on network filesystems and does nothing across machines, so the result is last-writer-wins or a corrupted state file, or merge conflicts in git.

**How the backend change prevents it:**
- State lives in one place (S3), so everyone plans against the same truth. Versioning gives rollback if state is damaged.
- Before any state-changing operation, Terraform writes an item to DynamoDB with `LockID` = `<bucket>/<key>` as a conditional write that only succeeds if the item does not exist. The second person's apply fails with "Error acquiring the state lock", which shows who holds it, when it started and the operation. `-lock-timeout=5m` makes it wait instead of failing. The lock is deleted when the run ends.
- A crashed run can leave a stale lock; clear it with `terraform force-unlock <ID>` after confirming nobody is running.

Note: from Terraform 1.10 the S3 backend can lock with a lock file in S3 (`use_lockfile = true`), and `dynamodb_table` is deprecated in newer versions. I used DynamoDB because the brief asks for it.

---

## Task 3 - Multi-account IAM

**Account A**
- `group1` (engine, ci): programmatic only, meaning the users have no login profile, so no console password exists. Its only permission is `sts:AssumeRole` on roleB.
- `group2` (alice, bob): console login with forced password reset, plus self-service for their own password/MFA/keys. Assumption: the brief says "full console + CLI access" without saying what permissions, and giving them AdministratorAccess directly would make roleA pointless. So group2's real power is assuming roleA.
- `roleA`: Allow `*`, plus an explicit Deny on `iam:*`. Trust is limited to alice and bob's ARNs and requires MFA. An explicit deny wins over any other allow attached later, which is stricter than allowing with `NotAction`. Side effect: it also denies `iam:PassRole` and `iam:CreateServiceLinkedRole`, so roleA cannot create EC2 instance profiles, Lambda execution roles or ECS task roles and will break on some first-time service setups. That is the cost of "everything except IAM".
- `roleB`: its only permission is `sts:AssumeRole` on `arn:aws:iam::111111111111:role/roleC`. Trust names engine and ci specifically.

**Account B:** `roleC` has `s3:*` on one named bucket and its objects only. Its trust policy names `arn:aws:iam::000000000000:role/roleB` only.

**Apply order:** Account A first, then Account B. IAM rejects a trust policy naming a principal that does not exist yet.

**Q: Would I give engine and ci IAM users with access keys in production?**
No. Long-lived access keys are the most common cause of credential leaks: they sit in env vars, CI settings and laptops, never expire on their own, bypass MFA, and rotation is manual and usually skipped. What I would do instead:
- `ci`: use OIDC federation from the CI system (GitHub Actions, GitLab, etc.) so each pipeline run assumes a role and gets credentials valid for about an hour. No stored secret exists. The trust policy is scoped to the exact repo and branch.
- `engine` (assuming it is a service or application): use an IAM role on the compute it runs on (instance profile, ECS task role, IRSA/EKS Pod Identity). For on-prem workloads, IAM Roles Anywhere with certificates.
- Humans: IAM Identity Center (SSO) with short-lived sessions and MFA, rather than IAM users.

If a key truly cannot be avoided (a legacy vendor integration, say), I would restrict it by least privilege plus source IP/condition keys, store it in Secrets Manager, alert on key age and last use, and rotate on a schedule. Terraform here also deliberately does not create the keys, since the secret would be written to state.

**Q: Why trust roleB's specific ARN in roleC's trust policy rather than the Account A root?**
Trusting `arn:aws:iam::000000000000:root` does not trust "the account root user"; it means "any principal in Account A that Account A's own IAM policies allow to call `sts:AssumeRole` on roleC". That hands control of who can reach roleC to whoever administers IAM in Account A. Anyone there who can attach an `sts:AssumeRole` permission to a user or role (including a compromised admin, or a future team adding a new role) can reach Account B's bucket, and Account B's owner never sees or approves it. Trusting roleB's exact ARN makes Account B's trust policy itself the control: only that one role, nothing else in Account A, regardless of what Account A's admins do. It is also safer on role re-creation: IAM stores the principal as a unique ID behind the ARN, so if roleB is deleted and recreated, the trust stops matching until someone in Account B deliberately re-applies it. Note both sides are required cross-account: roleC's trust must allow roleB, and roleB's identity policy must allow `sts:AssumeRole` on roleC, which it does.

---

## Task 4 - Least-privilege policy for `ci`

`task4-ci-policy/ci-policy.json` is a custom policy attached to the ci user. Names (repo `app-repo`, cluster `prod-cluster`, service `app-service`, bucket `my-build-artifacts`, region us-east-1, account 000000000000) are placeholders to replace.

Actions included:
- **Push to ECR:** `GetAuthorizationToken` (cannot be scoped to a resource, AWS requires `*`), plus the five layer-upload and `PutImage` actions on the one repository ARN.
- **Deploy to ECS:** `RegisterTaskDefinition` and `DescribeTaskDefinition` (neither supports resource-level permissions, so `*` is unavoidable), `UpdateService` and `DescribeServices` on the one service ARN, and `iam:PassRole` limited to the two specific task roles with `iam:PassedToService = ecs-tasks.amazonaws.com`. Registering a task definition that names task or execution roles fails without PassRole.
- **Read-only S3:** `GetObject` on the bucket's objects and `ListBucket` on the bucket.

Deliberately left out:
- **ECR pull actions** (`BatchGetImage`, `GetDownloadUrlForLayer`): pushing does not need them. Add them only if the pipeline pulls from this repo (layer cache, retagging).
- **`ecr:CreateRepository`, `DeleteRepository`, `BatchDeleteImage`, lifecycle/policy changes:** repos are created by infrastructure code. A compromised CI should not be able to delete or overwrite repos' policies.
- **`ecs:CreateService`, `DeleteService`, `RunTask`, `StopTask`, `ExecuteCommand`, `DeregisterTaskDefinition`, and `UpdateService` on any other service:** CI deploys one service, it does not manage the cluster or run arbitrary tasks.
- **Any S3 write/delete** (`PutObject`, `DeleteObject`, bucket policy changes) and `ListAllMyBuckets`: the brief says read, not write.
- **`iam:PassRole` on `*`:** this is the classic privilege-escalation path (pass an admin role to a new task). It is pinned to two roles and one service.
- **Wildcard actions (`ecr:*`, `ecs:*`, `s3:*`) and any `Resource: "*"` beyond the three actions that require it.**
- **CloudWatch Logs, `ecs:TagResource`, KMS:** not needed for the described tasks. Add `ecs:TagResource` if the pipeline tags task definitions, and KMS permissions if the repo or bucket uses a customer managed key.

---

## Task 5 - Find and fix the bug

Fixed version: `task5-bugfix/fixed.tf`.

**Issue 1 - trust policy:** the principal is `arn:aws:iam::000000000000:user/roleB`. roleB is a role, not a user, so the ARN should be `...:role/roleB`. As written, it names an IAM user called "roleB", which does not exist. Depending on timing, IAM either rejects the role with a `MalformedPolicyDocument: Invalid principal` error, or (if a user with that name ever existed) trusts that user instead of the role. Either way roleB's sessions are not trusted by roleC, so `sts:AssumeRole` returns AccessDenied.

**Issue 2 - permissions policy:** `Action = "s3:*"` with `Resource = "*"` grants full control of every S3 bucket in Account B, not the one named bucket the design requires. It does not stop the role working, but it breaks least privilege: a compromised roleB could read or delete every bucket. The fix lists exactly two resources: the bucket ARN (needed for bucket-level actions such as `ListBucket`) and `bucket/*` (needed for object-level actions such as `GetObject` and `PutObject`).
