# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

terraform {

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.51"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }

    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }

  }

  required_version = ">= 1.5.7"
}

