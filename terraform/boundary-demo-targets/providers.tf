terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>2.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~>2.0"
    }
    hcp = {
      source  = "hashicorp/hcp"
      version = "0.79.0"
    }
    boundary = {
      source  = "hashicorp/boundary"
      version = "1.1.12"
    }
    vault = {
      version = "3.23.0"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "tfe" {}

provider "boundary" {
  addr                   = data.terraform_remote_state.boundary_demo_init.outputs.boundary_url
  auth_method_id         = data.terraform_remote_state.boundary_demo_init.outputs.boundary_admin_auth_method
  auth_method_login_name = "admin"
  auth_method_password   = data.terraform_remote_state.boundary_demo_init.outputs.boundary_admin_password
}

provider "vault" {
  address   = data.terraform_remote_state.boundary_demo_init.outputs.vault_pub_url
  token     = data.terraform_remote_state.boundary_demo_init.outputs.vault_token
  namespace = "admin"
}

provider "hcp" {}
