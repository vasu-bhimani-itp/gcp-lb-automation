terraform {
  backend "gcs" {
    # Intentionally empty. Configured dynamically via CI/CD.
  }
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0" # Keeps you on the latest major 7.x provider version
    }
  }
}