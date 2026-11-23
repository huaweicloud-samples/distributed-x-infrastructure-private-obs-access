terraform {
  required_version = ">= 1.3.0"

  required_providers {
    huaweicloud = {
      source  = "huaweicloud/huaweicloud"
      version = ">= 1.60.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.4.0"
    }
  }
}

# 凭据只从环境变量注入，不写进代码与 tfvars：
#   export HW_ACCESS_KEY=<HW_ACCESS_KEY>
#   export HW_SECRET_KEY=<HW_SECRET_KEY>
#   export HW_REGION_NAME=cn-south-1
provider "huaweicloud" {
  region = var.region
}
