# This module deliberately creates nothing. It is a pure function:
# inputs are facts about a deployment, outputs are the names and tags that
# every other module must use.

terraform {
  required_version = ">= 1.5.0"
}

locals {
  # Region abbreviations. Azure has no official short-code list, so the
  # platform owns one. Adding a region means adding it here — which is the
  # point: it forces a deliberate decision rather than a typo.
  region_abbreviations = {
    eastus        = "eus"
    eastus2       = "eus2"
    centralus     = "cus"
    westus2       = "wus2"
    westus3       = "wus3"
    northeurope   = "neu"
    westeurope    = "weu"
    uksouth       = "uks"
    southeastasia = "sea"
    australiaeast = "aue"
  }

  # Produce an obviously-broken name rather than a silent "null" if someone
  # passes an unmapped region: the validation below turns it into an error.
  region = lookup(local.region_abbreviations, var.location, "UNMAPPED")

  # Environments are abbreviated because "stage" costs three characters in
  # every name, and Key Vault only allows 24.
  env_abbreviations = {
    dev   = "dev"
    stage = "stg"
    prod  = "prod"
  }
  env = local.env_abbreviations[var.environment]

  # ---------------------------------------------------------------- naming ---

  # Hyphenated base, used by the ~90% of Azure resource types that allow it.
  base = join("-", compact([
    var.prefix,
    var.workload,
    local.env,
    local.region,
    var.instance,
  ]))

  # Compact base for resource types that forbid hyphens.
  base_compact = lower(join("", compact([
    var.prefix,
    var.workload,
    local.env,
    local.region,
    var.instance,
  ])))

  # Deterministic six-character suffix for globally-unique namespaces.
  # Derived from the seed plus the full compact base, so two environments in
  # one subscription never collide, and the value is stable across machines
  # and CI runners. It is a collision-avoidance device, not a secret.
  unique = substr(sha1(join("|", [var.uniqueness_seed, local.base_compact])), 0, 6)

  # Storage accounts: 3-24 chars, lowercase alphanumeric only.
  #
  # Same hazard as the Key Vault name below: truncating the ASSEMBLED string
  # would cut into the uniqueness suffix once the prefix is long enough, and a
  # partially-truncated hash in a GLOBAL namespace is a collision waiting to
  # happen. Reserve the suffix first, then fit as much stem as remains.
  storage_account_name = "${substr(local.base_compact, 0, 24 - length(local.unique))}${local.unique}"

  # Key Vault: 3-24 chars, alphanumerics and hyphens, must start with a letter,
  # and MUST NOT end with a hyphen.
  #
  # The naive form "${base}-kv-${unique}" is 30 characters and gets truncated to
  # 24, which fails twice over: it cuts the uniqueness suffix off entirely (so
  # two subscriptions collide in a GLOBAL namespace), and depending on prefix
  # length it can leave a trailing hyphen — an invalid Key Vault name that ARM
  # rejects with a message about the name format rather than about length.
  #
  # Reserve room for the suffix FIRST, then fit as much of the stem as remains.
  # trimsuffix guards the case where the truncation lands exactly on a hyphen.
  key_vault_suffix = "-${local.unique}"
  key_vault_stem   = trimsuffix(substr(local.base, 0, 24 - length(local.key_vault_suffix)), "-")
  key_vault_name   = "${local.key_vault_stem}${local.key_vault_suffix}"

  # Container Registry: 5-50 chars, alphanumeric only.
  container_registry_name = substr("${local.base_compact}acr${local.unique}", 0, 50)

  # Cosmos DB account: 3-44 chars, lowercase alphanumerics and hyphens.
  cosmosdb_account_name = substr("${local.base}-cosmos-${local.unique}", 0, 44)

  # ------------------------------------------------------------------ tags ---

  tags = merge(
    {
      environment         = var.environment
      workload            = var.workload
      owner               = var.owner
      cost_center         = var.cost_center
      data_classification = var.data_classification
      managed_by          = "terraform"
    },
    var.extra_tags,
  )
}

# A module with no resources still deserves a guard rail. This turns an
# unmapped region from a silently-ugly name into a plan-time failure.
resource "terraform_data" "region_must_be_mapped" {
  lifecycle {
    precondition {
      condition     = local.region != "UNMAPPED"
      error_message = "Region '${var.location}' has no abbreviation. Add it to local.region_abbreviations in modules/naming/main.tf — deliberately, so the short code is chosen rather than guessed."
    }
  }
}
