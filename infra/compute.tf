# ===========================================================================
# 云服务器
#
# 两台机器都在私有子网里，都没有弹性公网 IP：
#   client —— 发起访问的一方，挂委托，用来验证两条路径。
#   relay  —— 只在启用路径二时创建，作为接口型终端节点服务的后端。
#
# 登录方式是控制台的「远程登录（VNC）」。它走管理面，不经过 VPC 网络，
# 因此不需要跳板机、不需要弹性公网 IP、也不需要为「能登进去」这件事
# 额外创建任何终端节点。这是本实践能做到零公网出口的关键前提之一。
# ===========================================================================

data "huaweicloud_images_image" "ecs" {
  name        = var.ecs_image_name
  visibility  = "public"
  most_recent = true
}

locals {
  # user-data 的组织方式：
  #   前缀部分由 Terraform 生成，只负责把参数写进配置文件；
  #   主体部分用 file() 原样嵌入 src/ 下的静态脚本。
  #
  # 不用 templatefile() 是因为脚本里大量出现 ${...}（Shell 变量展开）和
  # %{...}（curl 输出格式），这两个都是 Terraform 模板语法的保留写法，
  # 用 templatefile() 就得逐个转义，改一次脚本错一次。file() 不解析内容，
  # 从根上避免这类问题。
  client_user_data = join("\n", [
    "#!/bin/bash",
    "set -euo pipefail",
    "mkdir -p /etc/obs-demo",
    "cat > /etc/obs-demo/env <<'OBSDEMOCONF'",
    "BUCKET=${local.bucket_name}",
    "REGION=${var.region}",
    "OBS_DOMAIN=${local.obs_endpoint_domain}",
    "BUCKET_HOST=${local.obs_bucket_domain}",
    "ENDPOINT_IP=${var.endpoint_ip}",
    "INTERFACE_PATH_ENABLED=${var.enable_interface_path}",
    "OBSDEMOCONF",
    file("${path.module}/../src/client-init.sh"),
  ])

  relay_user_data = join("\n", [
    "#!/bin/bash",
    "set -euo pipefail",
    "cat > /etc/obs-relay.conf <<'OBSRELAYCONF'",
    "OBS_DOMAIN=${local.obs_endpoint_domain}",
    "OBSRELAYCONF",
    file("${path.module}/../src/obs-relay-init.sh"),
  ])
}

# ---------------------------------------------------------------------------
# 客户端
# ---------------------------------------------------------------------------
resource "huaweicloud_compute_instance" "client" {
  name              = "${var.name_prefix}-client"
  availability_zone = var.availability_zone

  # 实例规格：1 vCPU / 1 GiB，按需
  flavor_id = var.ecs_flavor
  image_id  = data.huaweicloud_images_image.ecs.id

  # 实例规格：系统盘 SAS 40 GiB
  system_disk_type = var.system_disk_type
  system_disk_size = var.system_disk_size

  security_group_ids = [huaweicloud_networking_secgroup.client.id]

  # 委托：实例元数据接口据此下发临时凭据，实例上不落任何长期密钥
  agency_name = huaweicloud_identity_agency.ecs_obs.name

  admin_pass = var.ecs_admin_password
  user_data  = local.client_user_data

  network {
    uuid        = huaweicloud_vpc_subnet.main.id
    fixed_ip_v4 = var.client_private_ip
  }

  tags = {
    Scenario = "private-obs-access"
    Role     = "client"
  }

  # 注：客户端开机不阻塞于网关型终端节点。路径一启用时，路由注入可能在开机后短暂完成，
  # obs-check 为手动执行，时序无影响；路径二（接口型中继）与本依赖无关。
}

# ---------------------------------------------------------------------------
# 转发节点
#
# source_dest_check 必须关闭。这台机器要转发目的地址不是自己的报文，
# 开着源/目的检查会在网卡层面被丢掉，且没有任何日志，只表现为连接超时。
# ---------------------------------------------------------------------------
resource "huaweicloud_compute_instance" "relay" {
  count = var.enable_interface_path ? 1 : 0

  name              = "${var.name_prefix}-relay"
  availability_zone = var.availability_zone

  # 实例规格：1 vCPU / 1 GiB，按需
  flavor_id = var.ecs_flavor
  image_id  = data.huaweicloud_images_image.ecs.id

  # 实例规格：系统盘 SAS 40 GiB
  system_disk_type = var.system_disk_type
  system_disk_size = var.system_disk_size

  security_group_ids = [huaweicloud_networking_secgroup.proxy[0].id]

  admin_pass = var.ecs_admin_password
  user_data  = local.relay_user_data

  network {
    uuid              = huaweicloud_vpc_subnet.main.id
    fixed_ip_v4       = var.proxy_private_ip
    source_dest_check = false
  }

  tags = {
    Scenario = "private-obs-access"
    Role     = "relay"
  }
}
