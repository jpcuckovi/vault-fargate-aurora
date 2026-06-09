variable "name_prefix" {
  description = "Prefix applied to resource names / aliases."
  type        = string
}

variable "role" {
  description = "\"primary\" creates the multi-region seal key (the MRK primary). \"dr\" creates a replica of an existing MRK."
  type        = string
  validation {
    condition     = contains(["primary", "dr"], var.role)
    error_message = "role must be \"primary\" or \"dr\"."
  }
}

variable "primary_seal_key_arn" {
  description = "When role = \"dr\", the ARN of the primary multi-region seal key to replicate. Take this from the primary root's `seal_key_arn` output."
  type        = string
  default     = ""
}

variable "deletion_window_days" {
  description = "KMS key deletion window in days."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}
