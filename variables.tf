# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-2"
}

variable "cluster_name_prefix" {
  description = "Prefix for the EKS cluster name"
  type        = string
  default     = "eks-starter"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnets" {
  description = "Private subnet CIDR blocks"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnets" {
  description = "Public subnet CIDR blocks"
  type        = list(string)
  default     = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.35"
}

variable "ami_type" {
  description = "AMI type for managed node group instances"
  type        = string
  default     = "AL2023_x86_64_STANDARD"
}

variable "instance_types" {
  description = "EC2 instance types for managed node group instances"
  type        = list(string)
  default     = ["t3.small"]
}

variable "lbc_chart_version" {
  description = "Helm chart version for the AWS Load Balancer Controller"
  type        = string
  default     = "1.8.2"
}

variable "eso_chart_version" {
  description = "Helm chart version for External Secrets Operator"
  type        = string
  default     = "0.14.4"
}

variable "eso_secret_arns" {
  description = "AWS Secrets Manager ARN patterns ESO is permitted to read. Defaults to all secrets. Scope to 'arn:aws:secretsmanager:*:*:secret:myapp/*' in production."
  type        = list(string)
  default     = ["*"]
}
