variable "account_id" {
  description = "EAF-PROD account ID. Never changes after account creation."
  type        = string
  default     = "679090980132"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "management_account_id" {
  description = "The management account. Passed in by the pipeline to guard against wrong credentials."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.management_account_id))
    error_message = "management_account_id must be a 12-digit AWS account ID."
  }
}

variable "region" {
  description = "AWS region for baseline resources."
  type        = string
  default     = "eu-west-2"
}
