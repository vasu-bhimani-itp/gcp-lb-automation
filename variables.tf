variable "module_name" {
  
}


variable "gcp_region" {
  
}

variable "gcp_project_id" { 
  type = string 
  default = "devops-sandbox-452616"
}

variable "lb_name" { 
  type = string
}

variable "exposure" { 
  type = string 
}

variable "scope" { 
  type = string 
}

variable "region" { 
  type    = string 
  default = "" 
}