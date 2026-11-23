# ===========================================================================
# 访问路径一：网关型终端节点（可选）
#
# 网关型终端节点服务由云平台预置，账号侧不需要（也无法）创建，只能查询后引用。
# 创建终端节点后，云平台会往默认路由表里注入一条指向对象存储的路由，
# 子网内的流量因此在不出 VPC 的前提下抵达对象存储。
#
# 注意（环境限制）：在 cn-south-1 的当前账号下，该终端节点的路由注入在华为云端失败、
# 终端节点创建后进入 failed 且无明细报错，属账号/区域级限制，非配置缺陷。
# 因此用 var.enable_gateway_path 默认关闭；如遇「终端节点 failed」，可改用路径二。
# ===========================================================================

data "huaweicloud_vpcep_public_services" "obs" {
  service_name = "obs"
}

locals {
  # 按服务类型精确挑出网关型的那一条，避免区域内同时存在多个同名候选时取错。
  # 不用下标硬取，是因为返回顺序没有排序契约。
  obs_gateway_services = [
    for s in data.huaweicloud_vpcep_public_services.obs.services :
    s if lower(s.service_type) == "gateway"
  ]
}

locals {
  # 终端节点策略：只放通读取，写入被显式拒绝 —— 用来演示策略确实生效，
  # 从客户端做 PUT 会被拒，做 GET 正常。
  # 仅当 var.enable_gateway_policy 为 true（且区域 OBS 网关服务 enable_policy=true）时才传入，
  # 否则会让网关型终端节点创建失败。
  gateway_policy_json = jsonencode([
    {
      Effect = "Allow"
      Action = [
        "obs:bucket:ListBucket",
        "obs:bucket:GetBucketLocation",
        "obs:object:GetObject"
      ]
      Resource = [
        "obs:*:*:bucket:${local.bucket_name}",
        "obs:*:*:object:${local.bucket_name}/*"
      ]
    }
  ])
}

resource "huaweicloud_vpcep_endpoint" "obs_gateway" {
  count = var.enable_gateway_path ? 1 : 0

  service_id  = local.obs_gateway_services[0].id
  vpc_id      = huaweicloud_vpc.main.id
  description = "Gateway endpoint for object storage"

  # 终端节点策略：默认不传。详见 var.enable_gateway_policy 说明。
  # 传 null 等同于不设置该字段，避免对不支持策略的 OBS 网关服务传入导致失败。
  policy_statement = var.enable_gateway_policy ? local.gateway_policy_json : null

  # 部署前置校验：区域内必须存在网关型的对象存储终端节点服务。
  # 部分区域未开放，用 precondition 在 plan 阶段就以可读原因中断，
  # 而不是等到 apply 时报一个「service_id 取不到」的底层错误。
  # 这里用 precondition 而非 check 块 —— check 只产生告警，不阻断。
  lifecycle {
    precondition {
      condition     = length(local.obs_gateway_services) > 0
      error_message = "当前区域未查询到「网关」型的对象存储终端节点服务。请更换区域，或提交工单向运维获取该服务的 ID 后改为显式传参。"
    }
  }
}
