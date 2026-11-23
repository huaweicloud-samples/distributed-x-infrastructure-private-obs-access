# ===========================================================================
# 网络
#
# 这套网络的定义特征是「没有出口」：没有弹性公网 IP、没有 NAT 网关、
# 没有任何指向公网的路由。子网内的云服务器访问对象存储，全部依赖终端节点。
#
# 网关型终端节点（路径一）创建时，云平台会往默认路由表注入一条指向对象存储的路由。
# 在 cn-south-1 的当前账号下，该注入在华为云端失败、终端节点进入 failed 且无明细报错，
# 属账号/区域级限制，非配置问题（已验证：AZ、策略、标签、依赖、服务候选均无误）。
# 因此路径一做成可选开关 enable_gateway_path（默认关闭），部署以路径二（接口型中继）为主。
# 注意：本 provider 版本（1.96.1）没有子网-路由表关联资源，子网只能绑定默认路由表。
# ===========================================================================

resource "huaweicloud_vpc" "main" {
  name = "${var.name_prefix}-vpc"
  cidr = var.vpc_cidr

  tags = {
    Scenario = "private-obs-access"
  }
}

# dns_list 留空 = 使用云内置 DNS。
# 内置 DNS 是把 obs.<region>.myhuaweicloud.com 解析到内网地址的唯一途径，
# 改成公共 DNS 会解析到公网地址，在无出口的子网里直接不通。
resource "huaweicloud_vpc_subnet" "main" {
  name       = "${var.name_prefix}-subnet"
  vpc_id     = huaweicloud_vpc.main.id
  cidr       = var.subnet_cidr
  gateway_ip = var.subnet_gateway

  availability_zone = var.availability_zone

  tags = {
    Scenario = "private-obs-access"
  }
}

# ---------------------------------------------------------------------------
# 客户端安全组
#
# 入方向不放通任何来源 —— 客户端不对外提供服务，登录走控制台远程登录（VNC），
# 那是管理面通道，不经过安全组。
# ---------------------------------------------------------------------------
resource "huaweicloud_networking_secgroup" "client" {
  name                 = "${var.name_prefix}-client-sg"
  description          = "Client instance accessing object storage over VPC endpoints"
  delete_default_rules = true
}

# 出方向：内网云服务统一走 100.125.0.0/16。
# 这里替代了「按对象存储服务的地址前缀放通」这种写法 —— 内网服务地址不对外公布
# 固定清单，100.125.0.0/16 是能拿到的最小可靠范围，比放通 0.0.0.0/0 收敛得多。
resource "huaweicloud_networking_secgroup_rule" "client_egress_cloud_service" {
  security_group_id = huaweicloud_networking_secgroup.client.id
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "100.125.0.0/16"
  description       = "HTTPS to in-cloud service endpoints (object storage, DNS)"
}

# 出方向：访问同子网内的接口型终端节点地址。
resource "huaweicloud_networking_secgroup_rule" "client_egress_endpoint" {
  count = var.enable_interface_path ? 1 : 0

  security_group_id = huaweicloud_networking_secgroup.client.id
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "${var.endpoint_ip}/32"
  description       = "HTTPS to the interface VPC endpoint"
}

# 出方向：DNS 查询。
resource "huaweicloud_networking_secgroup_rule" "client_egress_dns" {
  security_group_id = huaweicloud_networking_secgroup.client.id
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = 53
  port_range_max    = 53
  remote_ip_prefix  = "100.125.0.0/16"
  description       = "DNS resolution via the built-in resolver"
}

# ---------------------------------------------------------------------------
# 转发节点安全组
#
# 入方向必须放通 198.19.128.0/17：接口型终端节点把客户端报文转发到后端时，
# 源地址会被改写成这个网段。只放通 VPC 网段会导致连接建立不起来，
# 而且现象是超时不是拒绝，很难查。
# ---------------------------------------------------------------------------
resource "huaweicloud_networking_secgroup" "proxy" {
  count = var.enable_interface_path ? 1 : 0

  name                 = "${var.name_prefix}-proxy-sg"
  description          = "Backend of the interface VPC endpoint service"
  delete_default_rules = true
}

resource "huaweicloud_networking_secgroup_rule" "proxy_ingress_from_endpoint" {
  count = var.enable_interface_path ? 1 : 0

  security_group_id = huaweicloud_networking_secgroup.proxy[0].id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "198.19.128.0/17"
  description       = "Traffic relayed by the VPC endpoint (source is rewritten to this range)"
}

resource "huaweicloud_networking_secgroup_rule" "proxy_ingress_from_vpc" {
  count = var.enable_interface_path ? 1 : 0

  security_group_id = huaweicloud_networking_secgroup.proxy[0].id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = var.vpc_cidr
  description       = "Direct access from inside the VPC, for troubleshooting"
}

resource "huaweicloud_networking_secgroup_rule" "proxy_egress_cloud_service" {
  count = var.enable_interface_path ? 1 : 0

  security_group_id = huaweicloud_networking_secgroup.proxy[0].id
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "100.125.0.0/16"
  description       = "HTTPS to the object storage internal address"
}

resource "huaweicloud_networking_secgroup_rule" "proxy_egress_dns" {
  count = var.enable_interface_path ? 1 : 0

  security_group_id = huaweicloud_networking_secgroup.proxy[0].id
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = 53
  port_range_max    = 53
  remote_ip_prefix  = "100.125.0.0/16"
  description       = "DNS resolution via the built-in resolver"
}
