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
  description = <<-EOT
    Immutable tag or digest of the image to deploy, e.g. a build SHA. Leave null on
    the first apply: the registry is still empty at that point, so the app runs
    bootstrap_image instead of an image that cannot be pulled. Because the tag is
    part of the container spec, changing it is what produces a new revision - a
    mutable tag such as "latest" produces no Terraform diff and therefore no deploy.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.image_tag != "latest"
    error_message = "image_tag must be immutable. Re-pushing 'latest' changes nothing in the plan, so the running revision would never pick the new image up. Use a build SHA, a version tag, or a sha256 digest."
  }
}

variable "bootstrap_image" {
  description = "Public image the app runs until image_tag is set. Only needs to exist and serve HTTP; it is replaced by the real image on the next apply."
  type        = string
  default     = "mcr.microsoft.com/k8se/quickstart:latest"
}

variable "bootstrap_port" {
  description = "Port bootstrap_image listens on. Ingress follows this while no real image is deployed."
  type        = number
  default     = 80
}

variable "container_port" {
  description = "Port the FastAPI process listens on inside the container."
  type        = number
  default     = 8000
}

variable "cpu" {
  description = "vCPU per replica. Container Apps only accepts specific cpu/memory pairs; see the memory validation."
  type        = number
  default     = 0.5
}

variable "memory" {
  description = "Memory per replica. Must pair with cpu - Container Apps requires memory to be exactly 2Gi per vCPU."
  type        = string
  default     = "1Gi"

  validation {
    condition     = contains(["0.25:0.5Gi", "0.5:1Gi", "0.75:1.5Gi", "1:2Gi", "1.25:2.5Gi", "1.5:3Gi", "1.75:3.5Gi", "2:4Gi"], "${var.cpu}:${var.memory}")
    error_message = "Unsupported cpu/memory pair. Container Apps allows 0.25/0.5Gi, 0.5/1Gi, 0.75/1.5Gi, 1/2Gi, 1.25/2.5Gi, 1.5/3Gi, 1.75/3.5Gi or 2/4Gi."
  }
}

variable "min_replicas" {
  description = "Minimum replicas. 0 allows scale-to-zero, which removes idle cost but adds cold-start latency."
  type        = number
  default     = 0

  validation {
    condition     = var.min_replicas >= 0 && var.min_replicas <= var.max_replicas
    error_message = "min_replicas must be >= 0 and no greater than max_replicas."
  }
}

variable "max_replicas" {
  description = "Maximum replicas under load."
  type        = number
  default     = 3

  validation {
    condition     = var.max_replicas >= 1 && var.max_replicas <= 300
    error_message = "max_replicas must be between 1 and 300."
  }
}

variable "log_retention_days" {
  description = "Log Analytics retention. 30 is the minimum billable tier for PerGB2018."
  type        = number
  default     = 30

  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "log_retention_days must be between 30 and 730 for the PerGB2018 SKU."
  }
}

variable "log_daily_quota_gb" {
  description = "Hard cap on Log Analytics ingestion per day. Ingestion is the one line item here that can run away unbounded; -1 removes the cap."
  type        = number
  default     = 1

  validation {
    condition     = var.log_daily_quota_gb == -1 || var.log_daily_quota_gb > 0
    error_message = "log_daily_quota_gb must be a positive number, or -1 for no cap."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    managed_by = "terraform"
    workload   = "ml-model-serving"
  }
}
