terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.33.0"
				}
		}
}

provider "aws" {
  region                      = var.aws_region
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    s3         = "http://localhost:4566"
    iam        = "http://localhost:4566"
    lambda     = "http://localhost:4566"
    dynamodb   = "http://localhost:4566"
    sts        = "http://localhost:4566"
    cloudwatch = "http://localhost:4566"
    logs       = "http://localhost:4566"
  }

  # 👇 This line forces S3 path-style URLs, fixing the “no such host” error
  s3_use_path_style = true
}

# provider block (falls noch nicht vorhanden)
#provider "aws" {
 # region = var.aws_region != "" ? var.aws_region : "eu-central-1"
#}

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

# IAM Role for Lambda
resource "aws_iam_role" "telegram_lambda_role" {
  name = "telegram-bot-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# Policy allowing Lambda to write logs to CloudWatch
resource "aws_iam_policy" "telegram_lambda_logging" {
  name        = "telegram-bot-lambda-logging"
  description = "Allow Lambda to create and write to CloudWatch Logs"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

# Attach policy to Lambda role
resource "aws_iam_role_policy_attachment" "telegram_lambda_logging_attach" {
  role       = aws_iam_role.telegram_lambda_role.name
  policy_arn = aws_iam_policy.telegram_lambda_logging.arn
}


resource "aws_lambda_function" "telegram_bot" {
  function_name = "telegram-bot"
  role          = aws_iam_role.telegram_lambda_role.arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.11"
  filename      = "./lambda_function.zip"
  timeout 		= 15
  environment {
    variables = {
      TELEGRAM_BOT_TOKEN = var.telegram_bot_token
      S3_BUCKET          = aws_s3_bucket.telegram_state.bucket
			}
		}

  depends_on = [
    aws_iam_role.telegram_lambda_role,
    aws_iam_role_policy_attachment.telegram_lambda_logging_attach
		]
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
