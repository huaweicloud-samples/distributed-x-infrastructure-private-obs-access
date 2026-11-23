variable "region" {
  description = "部署区域。终端节点服务的开放范围随区域不同，更换区域前先确认该区域已开放 OBS 网关型终端节点服务。"
  type        = string
  default     = "cn-south-1"
}

variable "availability_zone" {
  description = "云服务器所在可用区。单可用区即可，本实践不演示跨可用区容灾。cn-south-1 可用区为 c/e/f/g（不含 a）。"
  type        = string
  default     = "cn-south-1c"
}

variable "name_prefix" {
  description = "资源名称前缀，用于在同一账号下区分多次部署。"
  type        = string
  default     = "obsep"
}

# ---------------------------------------------------------------------------
# 网络
#
# 网段不得与 198.19.128.0/17 重叠 —— 那是终端节点的内部转发网段，
# 重叠会让接口型终端节点的回程报文进不来。
# ---------------------------------------------------------------------------
variable "vpc_cidr" {
  description = "虚拟私有云网段。"
  type        = string
  default     = "10.1.0.0/16"
}

variable "subnet_cidr" {
  description = "业务子网网段。子网内不分配弹性公网 IP，全部走内网。"
  type        = string
  default     = "10.1.1.0/24"
}

variable "subnet_gateway" {
  description = "业务子网网关地址。"
  type        = string
  default     = "10.1.1.1"
}

variable "client_private_ip" {
  description = "客户端云服务器的固定内网地址。固定下来是为了让验证步骤可复现。"
  type        = string
  default     = "10.1.1.10"
}

variable "proxy_private_ip" {
  description = "转发节点云服务器的固定内网地址。"
  type        = string
  default     = "10.1.1.20"
}

variable "endpoint_ip" {
  description = "接口型终端节点的固定内网地址。固定下来后，客户端侧的域名指向在 apply 前即可确定。"
  type        = string
  default     = "10.1.1.100"
}

# ---------------------------------------------------------------------------
# 资源规格：一律显式写死
# ---------------------------------------------------------------------------
variable "ecs_flavor" {
  description = "云服务器规格。s6.small.1 = 1 vCPU / 1 GiB，是能跑通本实践的最小规格。"
  type        = string
  default     = "s6.small.1"
}

variable "system_disk_type" {
  description = "系统盘类型。SAS 为高 IO，单价低于 SSD；本实践无 IO 压力。"
  type        = string
  default     = "SAS"
}

variable "system_disk_size" {
  description = "系统盘容量（GiB）。取镜像要求的下限。"
  type        = number
  default     = 40
}

variable "ecs_image_name" {
  description = "云服务器公共镜像名称。使用云厂商自维护的操作系统，无需联网即可完成本实践的全部初始化动作。"
  type        = string
  default     = "Huawei Cloud EulerOS 2.0 Standard 64 bit"
}

# ---------------------------------------------------------------------------
# 访问路径开关
# ---------------------------------------------------------------------------
variable "enable_interface_path" {
  description = <<-EOT
    是否部署「接口型终端节点」访问路径。
    关闭时只保留网关型路径。
  EOT
  type        = bool
  default     = true
}

variable "enable_gateway_path" {
  description = <<-EOT
    是否部署「网关型终端节点」访问路径（对象存储私网访问路径一）。
    默认关闭：在 cn-south-1 的当前账号下，网关型终端节点的路由注入会在华为云端失败、
    终端节点进入 failed 且无明细报错，属账号/区域级限制，非配置缺陷。
    如遇该限制，请改用路径二（接口型中继），或在本变量设为 true 前确认账号已具备该能力。
  EOT
  type        = bool
  default     = false
}

variable "enable_gateway_policy" {
  description = <<-EOT
    是否对网关型终端节点启用访问策略。
    注意：华为云 OBS 网关服务的策略能力由该服务的 enable_policy 开关控制，
    且仅当其为 true 时才能传 policy_statement；cn-south-1 该值为 false，
    传策略会导致终端节点创建失败（进入 failed 且无明细报错）。因此默认关闭。
    若你部署的区域 OBS 网关服务 enable_policy=true，可改为 true 以演示「PUT 被拒、GET 放行」。
  EOT
  type        = bool
  default     = false
}

variable "obs_bucket_name" {
  description = "对象存储桶名称。桶名全局唯一，留空则自动拼接账号无关的随机后缀。"
  type        = string
  default     = ""
}

variable "ecs_admin_password" {
  description = <<-EOT
    云服务器初始登录密码。仅用于控制台远程登录（VNC）验证。
    通过环境变量注入：export TF_VAR_ecs_admin_password='<YOUR_PASSWORD>'
    不要写进 tfvars 文件。
  EOT
  type        = string
  sensitive   = true
}

variable "trust_domain_id" {
  description = <<-EOT
    当前华为云账号的 domain_id（账号 ID）。
    桶策略需要用它构造 Principal：domain/<trust_domain_id>:agency/<agency_name>。
    可在已部署的 ECS 内执行以下命令获取：
      curl -s http://169.254.169.254/meta-data/latest/instance-identity/document | python3 -c "import sys,json; print(json.load(sys.stdin).get('domain_id'))"
    留空则跳过桶策略资源创建（验证时会因缺少对象授权而 403）。
  EOT
  type        = string
  default     = ""
}
