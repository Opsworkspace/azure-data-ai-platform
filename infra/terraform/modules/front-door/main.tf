# ---------------------------------------------------------------------------
# Azure Front Door — global entry point, WAF, and the failover mechanism.
#
# This is the resource that turns two independent regional deployments into
# one highly available service. Everything about the 99.95% SLO depends on
# what happens here.
#
# --- how failover actually works -------------------------------------------
#
# Front Door is an anycast network: one IP announced from ~200 edge locations.
# A user connects to the nearest edge, and the edge decides which origin to
# forward to, based on:
#
#   1. Priority.  Lower number wins. All origins at priority 1 = active/active.
#   2. Health.    An origin failing its probe is removed from rotation.
#   3. Latency.   Among healthy origins of equal priority, the lowest-latency
#                 one within the latency sensitivity band.
#   4. Weight.    Among those, weighted round-robin.
#
# Failover time is therefore a function of the PROBE settings, not of DNS.
# This matters enormously: a DNS-based failover (Traffic Manager) is bounded
# below by the record TTL plus client-side DNS caching, which in practice
# means minutes and, with badly-behaved resolvers, much longer. Front Door
# fails over inside the connection, so the RTO is:
#
#     probe_interval x consecutive failures required  ~=  30-60 seconds
#
# That is the difference between a 5-minute RTO and a 30-second one, and it is
# why this design uses Front Door rather than Traffic Manager.
#
# --- the health probe is the whole design ----------------------------------
#
# A probe that hits a path returning a static 200 tells you the web server
# process is alive. It does not tell you the region can serve requests. If the
# region's Cosmos endpoint is unreachable, that origin will keep passing a
# shallow probe and Front Door will keep sending it traffic that fails.
#
# The probe path must therefore be a READINESS check that verifies the
# origin's own critical dependencies. services/api/app/health.py implements
# exactly that, and the split between /healthz/live and /healthz/ready is the
# reason it exists.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

resource "azurerm_cdn_frontdoor_profile" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  sku_name            = var.sku_name
  tags                = var.tags

  # How long Front Door waits for an origin to send the first response byte.
  # Lower than a typical application timeout on purpose: a request that will
  # fail should fail fast at the edge rather than holding an edge connection.
  response_timeout_seconds = 60
}

resource "azurerm_cdn_frontdoor_endpoint" "this" {
  name                     = "${var.name}-ep"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id
  tags                     = var.tags
  enabled                  = true
}

resource "azurerm_cdn_frontdoor_origin_group" "api" {
  name                     = "api-origins"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id

  session_affinity_enabled = false

  health_probe {
    path                = var.health_probe_path
    protocol            = "Https"
    request_type        = "GET"
    interval_in_seconds = 30
  }

  load_balancing {
    # Two consecutive successes to bring an origin back. Deliberately low:
    # a flapping origin is better excluded, and re-adding is cheap.
    sample_size = 4
    # Of those 4 samples, 3 must succeed for the origin to count as healthy.
    successful_samples_required = 3

    # Origins whose latency is within 50ms of the fastest are all considered
    # equivalent and share traffic. Widening this sends more traffic to the
    # remote region and improves resilience at the cost of latency; narrowing
    # it pins users to their nearest region.
    additional_latency_in_milliseconds = 50
  }

  # Front Door drains connections from an origin removed from rotation rather
  # than cutting them, so an in-flight request completes.
  restore_traffic_time_to_healed_or_new_endpoint_in_minutes = 5
}

resource "azurerm_cdn_frontdoor_origin" "regional" {
  for_each = var.origins

  name                          = "origin-${each.key}"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.api.id
  enabled                       = true

  host_name          = each.value.host_name
  origin_host_header = var.custom_domain
  http_port          = 80
  https_port         = 443
  priority           = each.value.priority
  weight             = each.value.weight

  # Certificate validation against the origin. Disabling it is a common
  # "fix" for a certificate mismatch and silently converts the edge-to-origin
  # leg into unauthenticated TLS.
  certificate_name_check_enabled = true

  # --- Private Link origin --------------------------------------------------
  # Premium only. Front Door reaches the origin over the Microsoft backbone
  # through a private endpoint, which means the AKS internal load balancer
  # needs NO public IP at all.
  #
  # This closes the last hole in the private design. Without it, the ingress
  # controller must be publicly reachable and protected only by an IP
  # allow-list of Front Door's service tag — which works, but leaves an
  # internet-facing listener.
  #
  # The link requires MANUAL approval on the origin side after creation; the
  # connection sits in Pending until then, and the origin is unreachable.
  # That approval step is documented in docs/runbooks/05-frontdoor-origin.md.
  dynamic "private_link" {
    for_each = each.value.private_link != null ? [each.value.private_link] : []
    content {
      location               = private_link.value.location
      private_link_target_id = private_link.value.private_link_target_id
      request_message        = private_link.value.request_message
    }
  }
}

resource "azurerm_cdn_frontdoor_route" "api" {
  name                          = "api-route"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.this.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.api.id
  cdn_frontdoor_origin_ids      = [for o in azurerm_cdn_frontdoor_origin.regional : o.id]

  enabled                = true
  forwarding_protocol    = "HttpsOnly"
  https_redirect_enabled = true
  patterns_to_match      = ["/*"]
  supported_protocols    = ["Http", "Https"]

  # Caching is off. This is an authenticated API returning per-user data;
  # caching it at a shared edge is a cross-tenant data leak waiting to happen.
  # A separate route with caching enabled would serve static assets.
  cache {
    query_string_caching_behavior = "IgnoreQueryString"
    compression_enabled           = false
  }

  link_to_default_domain = true
}
