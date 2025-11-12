# provider block (falls noch nicht vorhanden)
provider "aws" {
  region = var.aws_region != "" ? var.aws_region : "eu-central-1"
}

# optional: zufälliger suffix, damit Name eindeutig wird
resource "random_id" "suffix" {
  byte_length = 3
}

# S3 Bucket
resource "aws_s3_bucket" "telegram_state" {
  bucket = "${var.s3_bucket_name}-${random_id.suffix.hex}"
  acl    = "private"

  versioning {
    enabled = false
  }
}

# minimal IAM policy allowing access only to this bucket
data "aws_iam_policy_document" "s3_policy" {
  statement {
    actions = [
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.telegram_state.arn
    ]
  }

  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]
    resources = [
      "${aws_s3_bucket.telegram_state.arn}/*"
    ]
  }
}

# create an IAM user for local testing (programmatic access)
resource "aws_iam_user" "telegram_user" {
  name = "telegram-bot-user"
}

resource "aws_iam_user_policy" "telegram_user_policy" {
  name   = "telegram-bot-s3-policy"
  user   = aws_iam_user.telegram_user.name
  policy = data.aws_iam_policy_document.s3_policy.json
}

# create access key for the user (you will get the secret in Terraform output — treat it carefully)
resource "aws_iam_access_key" "telegram_user_key" {
  user = aws_iam_user.telegram_user.name
}

# outputs
output "s3_bucket_name" {
  description = "Name of the S3 bucket to set as S3_BUCKET env var"
  value       = aws_s3_bucket.telegram_state.bucket
}

output "iam_access_key_id" {
  description = "Access key id (for local testing only)"
  value       = aws_iam_access_key.telegram_user_key.id
  sensitive   = false
}

output "iam_secret_access_key" {
  description = "Secret access key (for local testing). Treat as secret!"
  value       = aws_iam_access_key.telegram_user_key.secret
  sensitive   = true
}
