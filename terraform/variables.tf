variable "project" {
  description = "Short project name. Used as the prefix for every resource name."
  type        = string
  default     = "mlopsapi"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,11}$", var.project))
    error_message = "project must be 3-12 chars, lowercase letters and digits, starting with a letter (Azure Container Registry names are restrictive)."
  }
}

variable "environment" {
  description = "Deployment environment. Kept in resource names so dev and prod cannot collide."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment must be one of: dev, test, prod."
  }
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "uksouth"
}

variable "image_name" {
  description = "Container image repository name inside the registry (without the registry host)."
  type        = string
  default     = "readmission-api"
}

variable "image_tag" {
  description = "Image tag to deploy. Pin a digest or explicit tag in prod rather than 'latest'."
  type        = string
  default     = "latest"
}

variable "container_port" {
  description = "Port the FastAPI process listens on inside the container."
  type        = number
  default     = 8000
}

variable "cpu" {
  description = "vCPU per replica. Container Apps requires cpu/memory to be a supported pair (e.g. 0.5/1Gi, 1.0/2Gi)."
  type        = number
  default     = 0.5
}

variable "memory" {
  description = "Memory per replica, must pair with cpu."
  type        = string
  default     = "1Gi"
}

variable "min_replicas" {
  description = "Minimum replicas. 0 allows scale-to-zero, which removes idle cost but adds cold-start latency."
  type        = number
  default     = 0
}

variable "max_replicas" {
  description = "Maximum replicas under load."
  type        = number
  default     = 3
}

variable "log_retention_days" {
  description = "Log Analytics retention. 30 is the minimum billable tier."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    managed_by = "terraform"
    workload   = "ml-model-serving"
  }
}
