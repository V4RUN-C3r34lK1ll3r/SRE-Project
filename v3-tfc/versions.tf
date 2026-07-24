terraform {
  required_version = ">= 1.5.0"

  cloud {
    organization = "REPLACE_WITH_YOUR_TFC_ORG"

    workspaces {
      name = "sre-takehome-hcf"
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
