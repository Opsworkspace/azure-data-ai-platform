# tflint configuration.
#
# tflint catches what `terraform validate` cannot. validate checks that the
# configuration is syntactically correct and internally consistent; it does not
# know that `Standard_D99_v9` is not a real VM size, or that a variable has no
# description.

config {
  # Recurse into modules/ and environments/ from the repository root.
  call_module_type = "local"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "azurerm" {
  enabled = true
  version = "0.27.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

# --- documentation -----------------------------------------------------------
# Every variable and output must carry a description. This is not style: a
# module's variables ARE its API, and an undocumented input is one the next
# person has to read the implementation to understand.

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

# --- correctness -------------------------------------------------------------

rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_deprecated_interpolation" {
  enabled = true
}

rule "terraform_deprecated_index" {
  enabled = true
}

rule "terraform_comment_syntax" {
  enabled = true
}

# Naming convention for Terraform identifiers themselves — snake_case for
# resources, variables and outputs. Distinct from the AZURE resource naming
# handled by modules/naming.
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# --- version pinning ---------------------------------------------------------
# An unpinned provider means a build today and a build next month can produce
# different plans from identical code.

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

# --- deliberately disabled ---------------------------------------------------

# Requires a `versions.tf` / `main.tf` / `variables.tf` / `outputs.tf` layout.
# This repository splits larger modules further — network-hub has firewall.tf,
# bastion.tf, nsg.tf and diagnostics.tf — because a 900-line main.tf is worse
# for a reader than four named files.
rule "terraform_standard_module_structure" {
  enabled = false
}
