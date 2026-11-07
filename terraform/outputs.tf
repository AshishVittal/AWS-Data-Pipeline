
output "raw_bucket_name" {
  value = aws_s3_bucket.raw.bucket
}

output "processed_bucket_name" {
  value = aws_s3_bucket.processed.bucket
}
output "glue_execution_role_arn" {
  value = aws_iam_role.glue_execution.arn
}