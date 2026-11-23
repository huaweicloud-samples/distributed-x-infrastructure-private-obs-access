# ===========================================================================
# 委托
#
# 客户端云服务器不携带任何长期密钥。它通过委托拿到临时凭据，
# 再由对象存储客户端工具用临时凭据发起签名请求。
#
# 对象存储是全局服务，权限授在 domain 级（domain_roles）而不是项目级。
# 授在 project_role 里不会报错，但运行期取到的临时凭据不含对象存储权限，
# 表现为 403，排查成本很高。
# ===========================================================================

resource "huaweicloud_identity_agency" "ecs_obs" {
  name                   = "${var.name_prefix}-ecs-obs-agency"
  description            = "Allows the client instance to access the demo bucket"
  delegated_service_name = "op_svc_ecs"
  duration               = "FOREVER"

  # OBS OperateAccess：桶与对象的读写权限，不含桶的创建与删除。
  # 比「完全控制」收敛，够本实践使用。
  domain_roles = ["OBS OperateAccess"]
}
