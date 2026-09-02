locals {
  # Resource names must be globally unique for the registry, so a short random
  # suffix is appended rather than relying on the project name alone.
  name_prefix = "${var.project}-${var.environment}"
  acr_name    = "acr${var.project}${var.environment}${random_string.suffix.result}"

  # Bootstrap mode. On the first apply the registry exists but is empty, so
  # pointing the app at <acr>/<image>:<tag> would create a revision that can never
  # pull. Until image_tag is set the app runs a public placeholder instead, which
  # keeps the first apply green. Push an image, set image_tag, apply again.
  bootstrap = var.image_tag == null

  container_image = local.bootstrap ? var.bootstrap_image : "${azurerm_container_registry.this.login_server}/${var.image_name}:${var.image_tag}"

  # The placeholder serves plain HTTP on its own port and has no /health, so
  # ingress and the probes follow whichever image is actually running.
  app_port = local.bootstrap ? var.bootstrap_port : var.container_port

  tags = merge(var.tags, {
    environment = var.environment
    project     = var.project
  })
}

resource "random_string" "suffix" {
  length  = 5
  special = false
  upper   = false
  numeric = true
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name_prefix}"
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------------------
# Container registry - holds the model-serving image
# ---------------------------------------------------------------------------

resource "azurerm_container_registry" "this" {
  name                = local.acr_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Basic"

  # Admin credentials are disabled deliberately. The container app pulls using a
  # managed identity instead, so no registry password exists to leak or rotate.
  admin_enabled = false

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Identity - lets the container app pull from the registry without secrets
# ---------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "app" {
  name                = "id-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                            = azurerm_container_registry.this.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_user_assigned_identity.app.principal_id
  skip_service_principal_aad_check = true
}

# ---------------------------------------------------------------------------
# Observability - container stdout/stderr and platform logs land here
# ---------------------------------------------------------------------------

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days

  # Cost guardrail: a chatty container can otherwise bill unbounded ingestion.
  daily_quota_gb = var.log_daily_quota_gb

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Container Apps environment and the model-serving app itself
# ---------------------------------------------------------------------------

resource "azurerm_container_app_environment" "this" {
  name                       = "cae-${local.name_prefix}"
  resource_group_name        = azurerm_resource_group.this.name
  location                   = azurerm_resource_group.this.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  tags                       = local.tags
}

resource "azurerm_container_app" "api" {
  name                         = "ca-${local.name_prefix}"
  resource_group_name          = azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    container {
      name   = var.image_name
      image  = local.container_image
      cpu    = var.cpu
      memory = var.memory

      env {
        name  = "PORT"
        value = tostring(local.app_port)
      }

      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }

      # Probes are skipped in bootstrap mode: the placeholder has no /health, so
      # probing it would fail a revision that is doing exactly what it should.
      #
      # Kills a replica that has stopped serving rather than leaving it in
      # rotation returning errors - the failure mode monitoring is meant to catch.
      dynamic "liveness_probe" {
        for_each = local.bootstrap ? [] : [1]

        content {
          transport = "HTTP"
          port      = var.container_port
          path      = "/health"

          initial_delay           = 10
          interval_seconds        = 30
          timeout                 = 5
          failure_count_threshold = 3
        }
      }

      # Holds traffic back until the model has finished loading into memory.
      dynamic "readiness_probe" {
        for_each = local.bootstrap ? [] : [1]

        content {
          transport = "HTTP"
          port      = var.container_port
          path      = "/health"

          interval_seconds        = 10
          timeout                 = 5
          failure_count_threshold = 3
          success_count_threshold = 1
        }
      }
    }

    # Scale on concurrent requests so inference latency does not degrade under load.
    http_scale_rule {
      name                = "http-concurrency"
      concurrent_requests = 20
    }
  }

  ingress {
    external_enabled = true
    target_port      = local.app_port
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  depends_on = [azurerm_role_assignment.acr_pull]
}
