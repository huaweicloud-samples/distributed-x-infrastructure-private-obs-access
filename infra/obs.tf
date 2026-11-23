# ===========================================================================
# 对象存储
#
# 一个演示用的桶，加一个对象，用来在客户端侧证明两条访问路径确实通了。
# 桶本身不开公共读，全部访问都要走签名请求 + 委托授权。
# ===========================================================================

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

locals {
  bucket_name = var.obs_bucket_name != "" ? var.obs_bucket_name : "${var.name_prefix}-demo-${random_id.bucket_suffix.hex}"

  # 内网访问域名。桶级访问采用虚拟主机风格：<bucket>.<obs 内网域名>
  obs_endpoint_domain = "obs.${var.region}.myhuaweicloud.com"
  obs_bucket_domain   = "${local.bucket_name}.obs.${var.region}.myhuaweicloud.com"
}

resource "huaweicloud_obs_bucket" "demo" {
  bucket = local.bucket_name
  acl    = "private"

  # 演示环境，允许 destroy 时连同对象一起删除，避免残留桶。
  force_destroy = true

  tags = {
    Scenario = "private-obs-access"
  }
}

resource "huaweicloud_obs_bucket_object" "hello" {
  bucket       = huaweicloud_obs_bucket.demo.bucket
  key          = "hello.txt"
  content      = "Reached the bucket without leaving the private network.\n"
  content_type = "text/plain"
}

# ---------------------------------------------------------------------------
# 桶策略：把 hello.txt 的读取权限显式授予 ECS 委托。
#
# 委托临时凭据虽然已带有 OBS OperateAccess，但桶 ACL 为 private 时，
# 对象级访问仍需要桶策略/ACL 显式放行。这里用最小权限原则，
# 只允许该委托读取单个对象。
# ---------------------------------------------------------------------------
resource "huaweicloud_obs_bucket_policy" "agency_get" {
  count = var.trust_domain_id != "" ? 1 : 0

  bucket = huaweicloud_obs_bucket.demo.bucket

  policy = jsonencode({
    Statement = [
      {
        Sid    = "AllowAgencyGetObject"
        Effect = "Allow"
        Principal = {
          ID = "domain/${var.trust_domain_id}:agency/${huaweicloud_identity_agency.ecs_obs.name}"
        }
        Action   = ["GetObject"]
        Resource = ["${huaweicloud_obs_bucket.demo.bucket}/hello.txt"]
      }
    ]
  })
}
