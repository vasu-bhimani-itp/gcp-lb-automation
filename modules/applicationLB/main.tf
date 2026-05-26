locals {
  lb_config = jsondecode(file(var.json_file_path))
  config    = local.lb_config.config
  backends  = local.lb_config.backends
  routing   = local.lb_config.routing
  
  # NEW: Split the backends based on type
  compute_backends = { for k, v in local.backends : k => v if lookup(v, "backend_type", "") != "BUCKET" }
  bucket_backends  = { for k, v in local.backends : k => v if lookup(v, "backend_type", "") == "BUCKET" }

  # Filter health checks ONLY from the compute backends
  health_checks = { 
    for k, v in local.compute_backends : k => v 
    if lookup(v, "health_check", null) != null 
  }

  is_global         = var.scope == "global"
  is_regional       = var.scope == "regional"
  is_cross_regional = var.scope == "cross-regional"

  use_global_resources = local.is_global || local.is_cross_regional
  use_region_resources = local.is_regional

  use_global_forwarding_rule = local.is_global
  use_region_forwarding_rule = local.is_regional || local.is_cross_regional

  lb_scheme = var.exposure == "external" ? "EXTERNAL_MANAGED" : "INTERNAL_MANAGED"
}

locals {
  all_backend_ids = merge(
    { for k, v in google_compute_backend_service.global : k => v.id },
    { for k, v in google_compute_backend_bucket.buckets : k => v.id }
  )
}
data "google_compute_global_address" "static_ip" {
  count   = lookup(local.config, "frontend_ip_type", "ephemeral") == "static" ? 1 : 0
  name    = local.config.frontend_ip_name
  project = var.gcp_project_id
}


# ------------------------------------------------------------------------------
# 1. HEALTH CHECKS & BACKENDS (Split by Region vs Global)
# ------------------------------------------------------------------------------
resource "google_compute_health_check" "global" {
  for_each = { for k, v in local.health_checks : k => v if local.use_global_resources }
  name     = "${var.lb_name}-${each.key}-hc"
  project  = var.gcp_project_id
  http_health_check {
    port         = each.value.health_check.port
    request_path = each.value.health_check.path
  }
}

resource "google_compute_region_health_check" "regional" {
  for_each = { for k, v in local.health_checks : k => v if local.use_region_resources }
  name     = "${var.lb_name}-${each.key}-hc"
  project  = var.gcp_project_id
  region   = var.region
  http_health_check {
    port         = each.value.health_check.port
    request_path = each.value.health_check.path
  }
}

resource "google_compute_backend_service" "global" {
  for_each              = { for k, v in local.compute_backends : k => v if local.use_global_resources }
  name                  = "${var.lb_name}-${each.key}"
  project               = var.gcp_project_id
  load_balancing_scheme = local.lb_scheme
  
  log_config {
    enable      = lookup(each.value, "enable_logging", false)
    sample_rate = 1.0
  }

  health_checks = lookup(each.value, "health_check", null) != null ? [google_compute_health_check.global[each.key].id] : []
}

resource "google_compute_region_backend_service" "regional" {
  for_each = { for k, v in local.backends : k => v if local.use_region_resources }
  name                  = "${var.lb_name}-${each.key}"
  project               = var.gcp_project_id
  region                = var.region
  load_balancing_scheme = local.lb_scheme
  health_checks         = lookup(each.value, "health_check", null) != null ? [google_compute_region_health_check.regional[each.key].id] : []
}


resource "google_compute_backend_bucket" "buckets" {
  for_each    = { for k, v in local.bucket_backends : k => v if local.use_global_resources }
  name        = "${var.lb_name}-${each.key}"
  project     = var.gcp_project_id
  
  # NEW: Look for an explicit bucket name in the JSON. If not found, fall back to the key.
  bucket_name = lookup(each.value, "bucket_name", each.key) 
  
  enable_cdn  = lookup(each.value, "enable_cdn", false)
}

# ------------------------------------------------------------------------------
# 2. URL MAPS & ROUTING
# ------------------------------------------------------------------------------
resource "google_compute_url_map" "global" {
  count           = local.use_global_resources ? 1 : 0
  name            = "${var.lb_name}-url-map"
  project         = var.gcp_project_id
  
  # Fetch the ID safely from the merged master list
  default_service = try(local.all_backend_ids[keys(local.backends)[0]], "")

  dynamic "host_rule" {
    for_each = try(local.routing.host_rules, [])
    content {
      hosts        = [host_rule.value.host]
      path_matcher = "matcher-${host_rule.key}"
    }
  }
  
  dynamic "path_matcher" {
    for_each = try(local.routing.host_rules, [])
    content {
      name            = "matcher-${path_matcher.key}"
      default_service = try(local.all_backend_ids[path_matcher.value.backend], "")
      
      dynamic "path_rule" {
        for_each = try(local.routing.path_rules, [])
        content {
          paths   = [path_rule.value.path]
          service = try(local.all_backend_ids[path_rule.value.backend], "")
        }
      }
    }
  }
}


# NEW: URL map specifically for redirecting HTTP to HTTPS
resource "google_compute_url_map" "https_redirect" {
  count   = lookup(local.config, "enable_http_redirect", false) ? 1 : 0
  name    = "${var.lb_name}-https-redirect"
  project = var.gcp_project_id

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}


resource "google_compute_region_url_map" "regional" {
  count           = local.use_region_resources ? 1 : 0
  name            = "${var.lb_name}-url-map"
  project         = var.gcp_project_id
  region          = var.region
  default_service = try(google_compute_region_backend_service.regional[keys(local.backends)[0]].id, "")

  dynamic "host_rule" {
    for_each = try(local.routing.host_rules, [])
    content {
      hosts        = [host_rule.value.host]
      path_matcher = "matcher-${host_rule.key}"
    }
  }
  dynamic "path_matcher" {
    for_each = try(local.routing.host_rules, [])
    content {
      name            = "matcher-${path_matcher.key}"
      default_service = try(google_compute_region_backend_service.regional[path_matcher.value.backend].id, "")
      dynamic "path_rule" {
        for_each = try(local.routing.path_rules, [])
        content {
          paths   = [path_rule.value.path]
          service = try(google_compute_region_backend_service.regional[path_rule.value.backend].id, "")
        }
      }
    }
  }
}

# ------------------------------------------------------------------------------
# 3. PROXIES
# ------------------------------------------------------------------------------
# 1. HTTPS Proxy (Created if HTTPS is enabled)
resource "google_compute_target_https_proxy" "https" {
  count            = local.use_global_resources && lookup(local.config, "enable_https", false) ? 1 : 0
  name             = "${var.lb_name}-https-proxy"
  project          = var.gcp_project_id
  url_map          = google_compute_url_map.global[0].id
  ssl_certificates = [lookup(local.config, "ssl_certificate", "")]
}

# 2. HTTP Proxy (Created for pure HTTP load balancers, OR for HTTP-to-HTTPS redirects)
resource "google_compute_target_http_proxy" "global" {
  count   = local.use_global_resources && (!lookup(local.config, "enable_https", false) || lookup(local.config, "enable_http_redirect", false)) ? 1 : 0
  name    = "${var.lb_name}-http-proxy"
  project = var.gcp_project_id
  
  # If redirect is enabled, point to the redirect map. Otherwise, point to the main routing map.
  url_map = lookup(local.config, "enable_http_redirect", false) ? google_compute_url_map.https_redirect[0].id : google_compute_url_map.global[0].id
}

resource "google_compute_region_target_http_proxy" "regional" {
  count   = local.use_region_resources && !lookup(local.config, "enable_https", false) ? 1 : 0
  name    = "${var.lb_name}-http-proxy"
  project = var.gcp_project_id
  region  = var.region
  url_map = google_compute_region_url_map.regional[0].id
}

# ------------------------------------------------------------------------------
# 4. FORWARDING RULES (The Entry Points)
# ------------------------------------------------------------------------------
# 1. Primary Forwarding Rule (Port 443 if HTTPS, Port 80 if HTTP only)
resource "google_compute_global_forwarding_rule" "global" {
  count                 = local.use_global_forwarding_rule ? 1 : 0
  name                  = "${var.lb_name}-frontend"
  project               = var.gcp_project_id
  load_balancing_scheme = local.lb_scheme
  
  # Dynamically pick the port based on HTTPS toggle
  port_range = lookup(local.config, "enable_https", false) ? "443" : "80"
  
  # Dynamically pick the target proxy based on HTTPS toggle
  target     = lookup(local.config, "enable_https", false) ? google_compute_target_https_proxy.https[0].id : google_compute_target_http_proxy.global[0].id

  # Attach static IP if defined, otherwise ephemeral
  ip_address = lookup(local.config, "frontend_ip_type", "ephemeral") == "static" ? data.google_compute_global_address.static_ip[0].address : null
}

# 2. Secondary Forwarding Rule for HTTP -> HTTPS Redirect
# (Only created if both HTTPS and HTTP Redirect are true)
resource "google_compute_global_forwarding_rule" "http_redirect" {
  count                 = local.use_global_forwarding_rule && lookup(local.config, "enable_https", false) && lookup(local.config, "enable_http_redirect", false) ? 1 : 0
  name                  = "${var.lb_name}-http-redirect-frontend"
  project               = var.gcp_project_id
  load_balancing_scheme = local.lb_scheme
  
  port_range = "80"
  target     = google_compute_target_http_proxy.global[0].id # Points to the redirect proxy
  
  # Must share the EXACT same IP address as the primary forwarding rule
  ip_address = lookup(local.config, "frontend_ip_type", "ephemeral") == "static" ? data.google_compute_global_address.static_ip[0].address : google_compute_global_forwarding_rule.global[0].ip_address
}

resource "google_compute_forwarding_rule" "regional" {
  count                 = local.use_region_forwarding_rule ? 1 : 0
  name                  = "${var.lb_name}-frontend"
  project               = var.gcp_project_id
  region                = var.region
  load_balancing_scheme = local.lb_scheme
  port_range            = lookup(local.config, "enable_https", false) ? "443" : "80"
  
  # Cross-region needs the global target proxy, standard regional needs the regional target proxy
  target = local.use_global_resources ? google_compute_target_http_proxy.global[0].id : google_compute_region_target_http_proxy.regional[0].id
  
  # Required for Internal Load Balancers
  network    = local.lb_scheme == "INTERNAL_MANAGED" ? lookup(local.config, "network", null) : null
  subnetwork = local.lb_scheme == "INTERNAL_MANAGED" ? lookup(local.config, "subnetwork", null) : null
}