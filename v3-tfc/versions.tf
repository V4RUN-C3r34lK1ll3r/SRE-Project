terraform {
  required_version = ">= 1.5.0"

  cloud {
    organization = "varunzackv"

    workspaces {
      name = "SRE-Project"
    }
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}
