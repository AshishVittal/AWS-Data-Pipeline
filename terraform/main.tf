terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {
    bucket       = "aws-data-pipeline-tfstate-965984381610-74cef762"
    key          = "aws-data-pipeline/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}
provider "aws" {
  region = var.aws_region
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Raw data bucket
resource "aws_s3_bucket" "raw" {
  bucket = "${var.project_name}-raw-${random_id.bucket_suffix.hex}"

  tags = {
    Name        = "Raw Data Bucket"
    Environment = "Development"
    Project     = var.project_name
  }
}

# Processed data bucket
resource "aws_s3_bucket" "processed" {
  bucket = "${var.project_name}-processed-${random_id.bucket_suffix.hex}"

  tags = {
    Name        = "Processed Data Bucket"
    Environment = "Development"
    Project     = var.project_name
  }
}

# Block public access
resource "aws_s3_bucket_public_access_block" "raw" {
  bucket = aws_s3_bucket.raw.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "processed" {
  bucket = aws_s3_bucket.processed.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enable encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "processed" {
  bucket = aws_s3_bucket.processed.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# IAM role assumed by AWS Glue
resource "aws_iam_role" "glue_execution" {
  name = "${var.project_name}-glue-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "glue.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

# Permissions required by the Glue job
resource "aws_iam_role_policy" "glue_execution" {
  name = "${var.project_name}-glue-execution-policy"
  role = aws_iam_role.glue_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadRawDataAndScripts"
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = [
          "${aws_s3_bucket.raw.arn}/*"
        ]
      },
      {
        Sid    = "ListRawBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.raw.arn
        ]
      },
      {
        Sid    = "WriteProcessedData"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ]
        Resource = [
          "${aws_s3_bucket.processed.arn}/*"
        ]
      },
      {
        Sid    = "ListProcessedBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.processed.arn
        ]
      },
      {
        Sid    = "WriteGlueLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:AssociateKmsKey"
        ]
        Resource = [
          "${aws_s3_bucket.processed.arn}/temp/*"
        ]
      }
    ]
  })
}

# AWS Glue ETL Job
resource "aws_glue_job" "orders_etl" {
  name     = "${var.project_name}-orders-etl"
  role_arn = aws_iam_role.glue_execution.arn

  glue_version      = "5.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  timeout           = 5
  max_retries       = 0

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.raw.bucket}/scripts/etl_job.py"
    python_version  = "3"
  }

  execution_property {
    max_concurrent_runs = 1
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--RAW_S3_PATH"                      = "s3://${aws_s3_bucket.raw.bucket}/orders/"
    "--PROCESSED_S3_PATH"                = "s3://${aws_s3_bucket.processed.bucket}/orders/"
    "--TempDir"                          = "s3://${aws_s3_bucket.processed.bucket}/temp/"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
  }

  tags = {
    Project     = var.project_name
    Environment = "Development"
  }
}

# Attach AWS-managed Glue service permissions
resource "aws_iam_role_policy_attachment" "glue_service_role" {
  role       = aws_iam_role.glue_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# Glue Data Catalog database
resource "aws_glue_catalog_database" "orders" {
  name = "${var.project_name}_catalog"

  description = "Data catalog for the AWS orders pipeline"
}

# Glue Data Catalog table
resource "aws_glue_catalog_table" "orders_processed" {
  name          = "orders_processed"
  database_name = aws_glue_catalog_database.orders.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL       = "TRUE"
    classification = "parquet"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.processed.bucket}/orders/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    columns {
      name = "order_id"
      type = "string"
    }

    columns {
      name = "customer_id"
      type = "string"
    }

    columns {
      name = "product"
      type = "string"
    }

    columns {
      name = "quantity"
      type = "int"
    }

    columns {
      name = "price"
      type = "double"
    }

    columns {
      name = "order_date"
      type = "date"
    }

    columns {
      name = "city"
      type = "string"
    }

    columns {
      name = "total_order_value"
      type = "double"
    }
  }
}


# IAM role assumed by EventBridge Scheduler
resource "aws_iam_role" "scheduler_execution" {
  name = "${var.project_name}-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "scheduler.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# Allow Scheduler to start our Glue ETL job
resource "aws_iam_role_policy" "scheduler_start_glue" {
  name = "${var.project_name}-scheduler-start-glue"
  role = aws_iam_role.scheduler_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "glue:StartJobRun"
      ]
      Resource = aws_glue_job.orders_etl.arn
    }]
  })
}

# Daily EventBridge schedule
resource "aws_scheduler_schedule" "daily_glue" {
  name                         = "${var.project_name}-daily-glue-run"
  description                  = "Starts the orders ETL Glue job every 24 hours"
  schedule_expression          = "rate(1 day)"
  schedule_expression_timezone = "Asia/Kolkata"
  state                        = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:glue:startJobRun"
    role_arn = aws_iam_role.scheduler_execution.arn

    input = jsonencode({
      JobName = aws_glue_job.orders_etl.name
    })
  }
}

# CloudWatch log group for Glue errors
resource "aws_cloudwatch_log_group" "glue_error" {
  name              = "/aws-glue/jobs/error"
  retention_in_days = 3
}

# CloudWatch log group for Glue continuous logs
resource "aws_cloudwatch_log_group" "glue_logs_v2" {
  name              = "/aws-glue/jobs/logs-v2"
  retention_in_days = 3
}

# CloudWatch log group for Glue job output
resource "aws_cloudwatch_log_group" "glue_output" {
  name              = "/aws-glue/jobs/output"
  retention_in_days = 3
}

# Log group for Glue failure events
resource "aws_cloudwatch_log_group" "glue_failures" {
  name              = "/aws-data-pipeline/glue-failures"
  retention_in_days = 3
}

# EventBridge rule for Glue job failures
resource "aws_cloudwatch_event_rule" "glue_failures" {
  name        = "${var.project_name}-glue-failures"
  description = "Detects failed, timed-out or stopped Glue job runs"

  event_pattern = jsonencode({
    source      = ["aws.glue"]
    detail-type = ["Glue Job State Change"]

    detail = {
      jobName = [aws_glue_job.orders_etl.name]
      state   = ["FAILED", "TIMEOUT", "STOPPED"]
    }
  })
}

# Allow EventBridge to write failure events to CloudWatch Logs
resource "aws_cloudwatch_log_resource_policy" "glue_failures" {
  policy_name = "${var.project_name}-eventbridge-logs"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowEventBridgeToWrite"
      Effect = "Allow"

      Principal = {
        Service = "events.amazonaws.com"
      }

      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]

      Resource = "${aws_cloudwatch_log_group.glue_failures.arn}:*"
    }]
  })
}

# Route matching failure events to CloudWatch Logs
resource "aws_cloudwatch_event_target" "glue_failures" {
  rule = aws_cloudwatch_event_rule.glue_failures.name
  arn  = aws_cloudwatch_log_group.glue_failures.arn

  depends_on = [
    aws_cloudwatch_log_resource_policy.glue_failures
  ]
}
