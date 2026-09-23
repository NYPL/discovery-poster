provider "aws" {
  region     = "us-east-1"
}

locals {
  tags = {
    Project = "Research Catalog"
    BusinessUnit = "LSP"
    Environment = "${var.environment}"
    OtherProjects = "MyLibraryNyc"
  }

  log_metric_name = "${var.function_name}LogError-${var.environment}"
}

variable "environment" {
  type = string
  default = "qa"
  description = "The name of the environment (qa, production). This controls the name of lambda and the env vars loaded."

  validation {
    condition     = contains(["qa", "production"], var.environment)
    error_message = "The environment must be 'qa' or 'production'."
  }
}

variable "vpc_config" {
  type = map
  description = "VPC config params"
}

variable "function_name" {
  type        = string
  description = "The name of the function (e.g. BibPoster or ItemPoster)"
}

# Package the app as a zip:
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/dist.zip"
  source_dir  = "../../"
  excludes    = [".git", ".terraform", "provisioning", "test", "scripts"]
}

# Upload the zipped app to S3:
resource "aws_s3_object" "uploaded_zip" {
  bucket = "nypl-github-actions-builds-${var.environment}"
  key    = "discovery-poster-${var.environment}-dist.zip"
  acl    = "private"
  source = data.archive_file.lambda_zip.output_path
  etag   = filemd5(data.archive_file.lambda_zip.output_path)
  tags = local.tags
}

# Create the lambda:
resource "aws_lambda_function" "lambda_instance" {
  description   = "Lambda for posting to the Bib/Item API"
  function_name = "${var.function_name}-${var.environment}"
  handler       = "index.handler"
  memory_size   = 512
  role          = "arn:aws:iam::946183545209:role/lambda-full-access"
  runtime       = "nodejs24.x"
  timeout       = 300

  # Location of the zipped code in S3:
  s3_bucket     = aws_s3_object.uploaded_zip.bucket
  s3_key        = aws_s3_object.uploaded_zip.key

    # Trigger pulling code from S3 when the zip has changed:
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256


  # Load ENV vars from config and explicitly inject FUNCTION_NAME / ENVIRONMENT
  environment {
    variables = {
        FUNCTION_NAME = var.function_name
        ENVIRONMENT   = var.environment
      }
  }
  
  vpc_config {
    subnet_ids         = var.vpc_config.subnet_ids
    security_group_ids = var.vpc_config.security_group_ids
  }
  
  tags = local.tags
}

data "aws_sns_topic" "rc_alarms" {
  name = "research-catalog-team-alarms-${var.environment}"

  tags = local.tags
}

resource "aws_cloudwatch_log_metric_filter" "error_metric_filter" {
  name           = local.log_metric_name
  pattern        = "{ $.level = \"error\" }"
  log_group_name = "/aws/lambda/${aws_lambda_function.lambda_instance.function_name}"

  metric_transformation {
    name      = local.log_metric_name
    namespace = "LogMetrics"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_log_errors" {
  alarm_name          = "${var.function_name}LogErrorAlarm-${var.environment}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = local.log_metric_name
  namespace           = "LogMetrics"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Lambda function ${aws_lambda_function.lambda_instance.function_name} has error logs"
  alarm_actions       = [data.aws_sns_topic.rc_alarms.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.lambda_instance.function_name
  }

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.function_name}LambdaErrorAlarm-${var.environment}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Lambda function ${aws_lambda_function.lambda_instance.function_name} has invocation errors"
  alarm_actions       = [data.aws_sns_topic.rc_alarms.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.lambda_instance.function_name
  }

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "kinesis_iterator_age" {
  alarm_name          = "${var.function_name}KinesisIteratorAgeAlarm-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "IteratorAge"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Maximum"
  threshold           = 3600000 # 1 hour
  alarm_description   = "Triggered when Kinesis iterator age of lambda function ${aws_lambda_function.lambda_instance.function_name} exceeds 1 hour"
  alarm_actions       = [data.aws_sns_topic.rc_alarms.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.lambda_instance.function_name
  }

  tags = local.tags
}
