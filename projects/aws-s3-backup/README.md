# aws-s3-backup

Nightly, verified, encrypted backups from a Linux server to Amazon S3, using Bash, cron and an IAM role. There are no access keys on the box.

![aws-s3-backup](https://github.com/eswarsurya/devops-portfolio/actions/workflows/aws-s3-backup-ci.yml/badge.svg)

## Why this exists

Every team needs backups that actually restore. The script doesn't stop at copying files. It also:

- writes a **SHA-256 checksum** next to every archive and checks it on restore, so a corrupted file is caught;
- **verifies the upload** by comparing local and remote sizes with `head-object`;
- **encrypts at rest** (SSE-S3) and uses **STANDARD_IA**, which is cheaper for data you rarely read;
- uses an **S3 lifecycle rule** to move backups to Glacier Instant Retrieval after 30 days and delete them after 90, so cost stays flat;
- **authenticates with an IAM instance role**, never long-lived keys;
- **exits with clear codes** (1 config, 2 archive, 3 upload, 4 verify), so cron or a monitoring tool can alert on them.

## Architecture

```
 ┌──────────────── EC2 (Amazon Linux / Ubuntu) ────────────────┐
 │                                                              │
 │  cron 02:00 ──► backup.sh                                    │
 │                  │ 1. tar + gzip /var/www                    │
 │                  │ 2. sha256sum                              │
 │                  │ 3. aws s3 cp (SSE, STANDARD_IA)           │
 │                  │ 4. head-object → size check               │
 │                  │ 5. prune local copies (keep 3)            │
 │                  ▼                                           │
 │   IAM instance role: s3:PutObject/GetObject/ListBucket       │
 └──────────────────────────┬───────────────────────────────────┘
                            ▼
              ┌──── S3 bucket (private, versioned) ────┐
              │ host1/www-20261012T020000Z.tar.gz      │
              │ host1/www-20261012T020000Z.tar.gz.sha256│
              │ lifecycle: 30d → Glacier IR, 90d → delete│
              └────────────────────────────────────────┘
```

## Repo layout

```
scripts/backup.sh      archive → checksum → upload → verify → prune
scripts/restore.sh     download → verify checksum → extract (latest or a given key)
iam/backup-policy.json least-privilege policy (one bucket only)
iam/ec2-trust-policy.json  lets EC2 assume the role
iam/lifecycle.json     30d Glacier IR, 90d expire
cron/backup.cron       nightly schedule
tests/run-tests.sh     7 offline tests using a fake aws CLI (no AWS account needed)
(CI: /.github/workflows/aws-s3-backup-ci.yml) shellcheck + JSON validation + tests on every push
```

## Run the tests (no AWS needed)

```bash
bash tests/run-tests.sh
# PASS  backup uploads archive and checksum
# ...
# ---- 7 passed, 0 failed
```

## Deploy it on AWS (about 15 minutes, free tier)

Before you start, make sure you have the AWS CLI configured on your laptop (`aws configure`), with a billing alarm set.

```bash
export BUCKET=eswar-backup-demo-$RANDOM
export AWS_REGION=eu-west-1

# 1. Private, versioned bucket with public access blocked
aws s3api create-bucket --bucket $BUCKET --region $AWS_REGION \
  --create-bucket-configuration LocationConstraint=$AWS_REGION
aws s3api put-public-access-block --bucket $BUCKET \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-versioning --bucket $BUCKET --versioning-configuration Status=Enabled
aws s3api put-bucket-lifecycle-configuration --bucket $BUCKET --lifecycle-configuration file://iam/lifecycle.json

# 2. IAM role + instance profile scoped to this bucket only
sed "s/REPLACE_BUCKET_NAME/$BUCKET/g" iam/backup-policy.json > /tmp/policy.json
aws iam create-role --role-name s3-backup-role --assume-role-policy-document file://iam/ec2-trust-policy.json
aws iam put-role-policy --role-name s3-backup-role --policy-name s3-backup --policy-document file:///tmp/policy.json
aws iam create-instance-profile --instance-profile-name s3-backup-profile
aws iam add-role-to-instance-profile --instance-profile-name s3-backup-profile --role-name s3-backup-role

# 3. Launch a t3.micro / t2.micro with that instance profile (console or CLI), SSH in, then:
sudo mkdir -p /opt/aws-s3-backup && sudo cp -r scripts /opt/aws-s3-backup/
SOURCE_DIR=/etc BUCKET=$BUCKET /opt/aws-s3-backup/scripts/backup.sh   # manual run first
sed "s/REPLACE_BUCKET_NAME/$BUCKET/" cron/backup.cron | crontab -      # then schedule it

# 4. Prove it restores
BUCKET=$BUCKET PREFIX=$(hostname -s) DEST=/tmp/restore /opt/aws-s3-backup/scripts/restore.sh
```

Take a screenshot of the S3 console and of the log output, and add them to `docs/`. Real screenshots are what make a recruiter believe it ran.

## Teardown (do this, or you will pay)

```bash
aws ec2 terminate-instances --instance-ids <your-instance-id>
aws s3 rm s3://$BUCKET --recursive
aws s3api delete-objects --bucket $BUCKET --delete "$(aws s3api list-object-versions --bucket $BUCKET \
  --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json)"
aws s3api delete-bucket --bucket $BUCKET
aws iam remove-role-from-instance-profile --instance-profile-name s3-backup-profile --role-name s3-backup-role
aws iam delete-instance-profile --instance-profile-name s3-backup-profile
aws iam delete-role-policy --role-name s3-backup-role --policy-name s3-backup
aws iam delete-role --role-name s3-backup-role
```

## What I'd add next

- A CloudWatch alarm on a "last successful backup" custom metric. Silent failure is the real risk.
- KMS (SSE-KMS) instead of SSE-S3, for audit trails on key use.
- Rewriting the infrastructure part in Terraform (see `terraform-aws-webstack`).
