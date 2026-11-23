# ===========================================================================
# 访问路径二：接口型终端节点
#
# 云平台预置的「接口」型终端节点服务只有内网解析一项，对象存储不在其中。
# 想拿到「在子网里落一张网卡、通过固定内网地址访问对象存储」这种形态，
# 需要自己把一台云服务器发布成接口型终端节点服务，再为它创建终端节点。
#
# 换来的能力与云平台预置的接口型终端节点一致：
#   固定内网地址、可跨 VPC 与跨账号被消费、可加白名单、可与专线/VPN 打通。
# 代价是多一台转发节点，以及它的可用性要自己兜。
#
# 以上为本路径的设计取舍。
# ===========================================================================

# ---------------------------------------------------------------------------
# 把转发节点发布成终端节点服务
#
# port_id 取云服务器网卡的端口 ID。server_type 用 VM 而不是 LB，
# 因为本实践只有一个后端，没有分担流量的需要。
# ---------------------------------------------------------------------------
resource "huaweicloud_vpcep_service" "obs_relay" {
  count = var.enable_interface_path ? 1 : 0

  # 名称上限 16 字符
  name        = "${var.name_prefix}-obs"
  vpc_id      = huaweicloud_vpc.main.id
  server_type = "VM"
  port_id     = huaweicloud_compute_instance.relay[0].network[0].port
  description = "Relay to the object storage internal address"

  # 本账号自用，不需要审批流程
  approval = false

  port_mapping {
    protocol      = "TCP"
    service_port  = 443
    terminal_port = 443
  }

  tags = {
    Scenario = "private-obs-access"
  }
}

# ---------------------------------------------------------------------------
# 为该服务创建终端节点
#
# ip_address 显式指定：地址固定下来后，客户端侧的域名指向在 apply 之前
# 就能确定，重建也不会漂移。
#
# enable_dns 关闭：云侧会生成一个 *.vpcep.myhuaweicloud.com 的默认域名，
# 但对象存储的证书不覆盖这个域名，用它访问会证书校验失败。
# 正确做法是让客户端继续使用对象存储的原始域名，只把解析结果指过来。
# ---------------------------------------------------------------------------
resource "huaweicloud_vpcep_endpoint" "obs_interface" {
  count = var.enable_interface_path ? 1 : 0

  service_id  = huaweicloud_vpcep_service.obs_relay[0].id
  vpc_id      = huaweicloud_vpc.main.id
  network_id  = huaweicloud_vpc_subnet.main.id
  ip_address  = var.endpoint_ip
  enable_dns  = false
  description = "Interface endpoint for object storage"

  # 访问控制：只放通本 VPC 网段
  enable_whitelist = true
  whitelist        = [var.vpc_cidr]

  tags = {
    Scenario = "private-obs-access"
    Path     = "interface"
  }
}
