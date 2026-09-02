output "resource_group_name" {
  description = "Resource group holding every resource in this stack."
  value       = azurerm_resource_group.this.name
}

output "acr_login_server" {
  description = "Registry host. Tag and push the image here, then set image_tag and apply again."
  value       = azurerm_container_registry.this.login_server
}

output "acr_name" {
  description = "Registry name, for `az acr login --name <name>`."
  value       = azurerm_container_registry.this.name
}

output "deployed_image" {
  description = "Image the current revision runs. Shows the public placeholder while image_tag is unset."
  value       = local.container_image
}

output "bootstrap_mode" {
  description = "True while no image_tag is set: the app serves a placeholder and health probes are disabled."
  value       = local.bootstrap
}

output "container_app_name" {
  description = "Container App name, for `az containerapp logs show`."
  value       = azurerm_container_app.api.name
}

output "api_url" {
  description = "Public HTTPS endpoint of the model-serving API."
  value       = "https://${azurerm_container_app.api.ingress[0].fqdn}"
}

output "health_url" {
  description = "Health endpoint used by the liveness and readiness probes. Only serves once a real image is deployed."
  value       = "https://${azurerm_container_app.api.ingress[0].fqdn}/health"
}

output "log_analytics_workspace" {
  description = "Workspace where container logs are queryable via KQL."
  value       = azurerm_log_analytics_workspace.this.name
}
