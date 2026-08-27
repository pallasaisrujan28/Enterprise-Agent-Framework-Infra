variable "account_id" {
  description = "EAF-DEV account ID."
  type        = string
  default     = "718438899462"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-west-2"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "eaf-dev"
}

variable "cluster_version" {
  description = "Kubernetes version."
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS worker nodes."
  type        = string
  default     = "t3.medium"
}

# Primary model for reasoning and generation.
variable "bedrock_primary_model" {
  description = "Bedrock model ID for primary agent reasoning."
  type        = string
  default     = "anthropic.claude-sonnet-4-6"
}

# Fast model for tool selection and cheap operations.
variable "bedrock_fast_model" {
  description = "Bedrock model ID for fast/cheap operations."
  type        = string
  default     = "anthropic.claude-haiku-4-5-20251001-v1:0"
}

