module "applicationLB" {
  count  = var.module_name == "applicationLB" ? 1 : 0

  source = "./modules/applicationLB"

  gcp_project_id = var.gcp_project_id
  lb_name        = var.lb_name
  exposure       = var.exposure
  scope          = var.scope
  gcp_region = var.gcp_region

}