
variable "aws_region" {
  description = "AWS region for the data pipeline"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "aws-data-pipeline"
}
