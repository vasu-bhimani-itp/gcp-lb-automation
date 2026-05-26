variable "gcp_zone" {
  
}

variable "gcp_project_id" {
  
}

variable "gcp_region" {
  
}



variable "lb_name" {
  type        = string
  description = "Name of the Load Balancer"
}

variable "yaml_content" {
  type        = string
  description = "Raw YAML configuration string pasted from GitHub Actions UI"
}


