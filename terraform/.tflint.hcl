# Bundled ruleset: unused declarations, undocumented variables/outputs, untyped
# variables, deprecated syntax, naming convention, required_version/providers.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Provider-aware rules: invalid regions, SKUs, and other values that `terraform
# validate` accepts because they are only rejected by the Azure API at apply time.
plugin "azurerm" {
  enabled = true
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}
