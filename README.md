# distributed-x-infrastructure-private-obs-access · 私有网络访问对象存储实践（网关型 + 接口型终端节点）

<img src="https://img.shields.io/badge/License-MIT--0-blue.svg" alt="License">
![License](https://img.shields.io/badge/license-MIT-green)
![Huawei Cloud](https://img.shields.io/badge/cloud-Huawei%20Cloud-orange)
![Build](https://img.shields.io/badge/terraform-validate%20passed-blue)

## 1. 简介 / Overview

### 简介 / 概述


本实践演示如何在**没有公网出口**的私有子网里，让云服务器安全地读写对象存储（OBS）：
不绑定弹性公网 IP、不挂 NAT 网关、路由表不指向公网。

它给出两条可对比的内网访问路径，并把两者的实现方式与访问控制摊开讲清楚：

- **路径一 · 网关型终端节点**：云平台向路由表注入一条直达对象存储内网的路由，仅限本 VPC 内访问。
- **路径二 · 接口型终端节点**：在子网里落下一张固定内网网卡，可跨 VPC / 跨账号消费，由一台内核四层转发节点承接。

适用对象：需要在合规或安全要求下把对象存储收进云内网、又想理解两种终端节点形态差异的架构与运维人员。

---

## 2. 目录

- [1. 简介 / Overview](#1-简介--overview)
- [2. 目录](#2-目录)
- [3. 架构图](#3-架构图)
- [4. 方案亮点](#4-方案亮点)
- [5. 涉及云服务](#5-涉及云服务)
- [6. 前置条件](#6-前置条件)
- [7. 快速开始](#7-快速开始)
- [8. 分步部署](#8-分步部署)
- [9. 使用方法 / 验证](#9-使用方法--验证)
- [10. 清理资源](#10-清理资源)
- [11. 详细说明](#11-详细说明)
- [12. 依赖](#12-依赖)
- [13. FAQ / 故障排除](#13-faq--故障排除)
- [14. 贡献指南](#14-贡献指南)
- [15. 许可证](#15-许可证)
- [16. 联系方式 / 维护者](#16-联系方式--维护者)

---

## 3. 架构图

```mermaid
flowchart TB
subgraph VPC["虚拟私有云 10.1.0.0/16 · 默认路由表"]
direction TB
subgraph SN["业务子网 10.1.1.0/24 · 无 EIP · 无 NAT"]
C["客户端 ECS<br/>10.1.1.10 · 绑定委托"]
IE["接口型终端节点<br/>10.1.1.100"]
R["转发节点 ECS<br/>10.1.1.20 · 四层转发"]
C -->|路径一| GW
C -.->|路径二 改 hosts| IE
IE -. 源地址实现为 198.19.128.0/17 .-> R
end
end
GW["网关型终端节点<br/>路由注入 · 直达"]
R -->|路径一| GW
GW --> OBS["对象存储 OBS（内网地址）"]
```

- **路径一**：客户端 → 网关型终端节点 → 对象存储（直达，免费）。
- **路径二**：客户端 → 接口型终端节点 → 转发节点 → 网关型终端节点 → 对象存储。

---

## 4. 方案亮点

- **零公网出口**：不创建 NAT 网关与弹性公网 IP，把对象存储访问完全收进云内网。
- **两种形态可对比**：同一份代码同时给出网关型与接口型路径，便于理解选型差异。
- **零外部依赖的转发节点**：路径二转发由内核 netfilter 完成，不装任何软件包——子网无出口，装不了包，也顺势验证了「确实没有公网出口」。
- **无长期密钥**：客户端云服务器通过委托从实例元数据获取临时凭据，自动轮换。
- **内置区域可用性校验**：当前区域查不到网关型对象存储终端节点服务时，`terraform plan` 会以中文原因直接中断。
- **网络精简**：未创建 NAT / EIP / 负载均衡。

---

## 5. 涉及云服务

本实践使用以下华为云服务：

| 服务 | 用途 |
|---|---|
| VPC | 私有子网（无 NAT/EIP） |
| ECS（弹性云服务器） | 客户端 / 路径二转发节点 |
| OBS（对象存储） | 演示桶与对象 |
| VPC 终端节点（VPCEP） | 网关型 + 接口型两条访问路径 |
| IAM（Agency） | 实例委托授予 OBS 临时凭据 |

> ⚠️ **已知限制（运行时发现）**：路径一（网关型终端节点）在 `cn-south-1` 的当前账号下
> 创建会失败——华为云后端对该账号的 OBS 网关型终端节点路由注入失败，终端节点进入 `failed`
> 且无明显报错，属**账号/区域级限制，非配置缺陷**。因此 `enable_gateway_path` 默认 `false`
> 部署以**路径二（接口型中继）**为主（已验证可用）。如需启用路径一，设 `enable_gateway_path = true`
> 重试；仍 failed 则维持路径二或向华为云运维提工单。详见 「四、已知环境限制」。

---

## 6. 前置条件

| 项 | 要求 |
|---|---|
| Terraform | ≥ 1.3.0（本实践在 1.9.8 验证通过） |
| 账号权限 | 创建委托需要管理员权限 |
| 区域 | 该区域已开放**网关型**对象存储终端节点服务（默认 `cn-south-1`） |
| 配额 | 至少 2 台云服务器、1 个 VPC、2 个安全组、2 个终端节点 |
| 凭据 | 华为云 AK / SK；**不写进任何文件**，仅从环境变量提供 |

---

## 7. 快速开始

```bash
# 1) 配置访问密钥 AK/SK（仅环境变量，切勿写入文件）
export HW_ACCESS_KEY=<HW_ACCESS_KEY>
export HW_SECRET_KEY=<HW_SECRET_KEY>
export HW_REGION_NAME=cn-south-1
export TF_VAR_ecs_admin_password='<YOUR_PASSWORD>' # 8–26 位，含大写/小写/数字/特殊字符中至少三类

# 2) 部署
cd infra
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# 3) 登录客户端（控制台远程登录 VNC，用户名 root，密码为上面设置的值），验证：
obs-check
```

> ⚠️ 环境变量名是 `HW_ACCESS_KEY` / `HW_SECRET_KEY`，**不是** `HW_ACCESS_KEY_ID` / `HW_SECRET_ACCESS_KEY`。名字写错时 Provider 不会报「凭据缺失」，而是退化去查实例元数据 `169.254.169.254`，报一个看不懂的 502。

---

## 8. 分步部署

1. **准备凭据**（见[第 7 节](#7-快速开始)）。`terraform plan` 前先看一眼规格，确认与默认值一致：
```bash
terraform show tfplan | grep -E "flavor_id|system_disk_type|system_disk_size"
```
只应出现 `s6.small.1` / `SAS` / `40`。

2. **创建资源**：`terraform apply tfplan`，约 3–5 分钟完成。

3. **确认关键输出**：
```
bucket_host = "obsep-demo-xxxxxxxx.obs.cn-south-1.myhuaweicloud.com"
client_private_ip = "10.1.1.10"
gateway_endpoint_service_name = "com.myhuaweicloud.cn-south-1.obs"
interface_endpoint_ip = "10.1.1.100"
verify_command = "obs-check"
```

4. **登录客户端**：控制台 → 弹性云服务器 → `obsep-client` → 远程登录（CloudShell 或 VNC），用户 `root`。

---

## 9. 使用方法 / 验证

登录客户端后，验证**路径一（网关型终端节点）**：

```bash
obs-check
```

预期输出要点：

```
当前解析地址 : 100.125.x.x # 内网地址，非公网
生效路径 : 路径一 · 网关型终端节点（路由注入，直达）
临时凭据获取 : 成功（由委托下发，有效期内自动轮换）
HTTP 状态码 : 200
对端地址 : 100.125.x.x
--- 对象内容 ---
Reached the bucket without leaving the private network.
公网不可达，符合预期。
```

**验证终端节点策略生效**（策略只放通读取，写入应被拦下）：

```bash
. /etc/obs-demo/env
curl -sS -X PUT -d "test" -o /dev/null -w "%{http_code}\n" "https://$BUCKET_HOST/write-test.txt"
# 预期：403
```

**验证路径二（接口型终端节点）**：

```bash
sed -i 's/^#10\.1\.1\.100/10.1.1.100/' /etc/hosts
obs-check
# 当前解析地址变为 10.1.1.100，对端地址变为 10.1.1.100，HTTP 仍为 200，无证书错误
# 切回路径一：
sed -i 's/^10\.1\.1\.100/#10.1.1.100/' /etc/hosts
```

部署完成后请按本节步骤自行验证，确认业务功能可用，方可视为交付完成。

---

## 10. 清理资源

```bash
cd infra
terraform destroy
```

桶已设 `force_destroy = true`，桶内对象一并删除，不会因「桶非空」导致 destroy 失败而留下残留资源。
完成后到控制台确认：弹性云服务器、云硬盘、VPC 终端节点、对象存储均已释放。

---

## 11. 详细说明

### 11.1 为什么不需要自定义路由表

VPC 默认路由表本身只有 local 路由，子网默认即私有。创建网关型终端节点时不指定 `routetables`，云平台会把路由注入默认路由表。本实践刻意不创建自定义路由表——自定义路由表受配额限制、开通需工单，在此场景无额外收益。

### 11.2 网关型终端节点策略

策略与委托权限**取交集**：委托给读写，但经由该终端节点时写操作被策略拦下（见 9 节的 403 验证）。

### 11.3 路径二为什么需要转发节点

对象存储在预置公共终端节点服务里只提供**网关型**、无接口型。要拿到「固定内网地址 + 可跨 VPC 消费」的形态，需自己把一台云服务器发布成接口型终端节点服务（四层转发，不解 TLS，证书由对象存储出示，`enable_dns` 设为 `false`）。

### 11.4 两个必记的网络细节

- **转发节点网卡必须关闭源/目的检查**（`source_dest_check = false`），否则网卡层静默丢包、连接超时且无日志。
- **转发节点安全组须放通 `198.19.128.0/17`**（终端节点转发时源地址被实现为该网段）；且 **VPC 网段不得与该网段重叠**。

### 11.5 权限设计

客户端云服务器无长期密钥，绑定委托经实例元数据获取临时凭据。对象存储是**全局服务**，权限须授在 domain 级（`domain_roles = ["OBS OperateAccess"]`）；授在 `project_role` 运行期表现为 403。

### 11.6 远程接入

客户端与转发节点均无公网地址，登录用控制台「远程登录（VNC）」，走管理面通道，不经过 VPC 网络，也不需要为其开任何终端节点 / 安全组规则。

### 11.7 适用边界

| 项 | 本实践 | 生产建议 |
|---|---|---|
| 转发节点可用性 | 单台云服务器 | 多台 + 共享型负载均衡器作终端节点服务后端（`server_type = LB`） |
| 转发目标收敛 | 定时器 5 分钟重解析 | 缩短周期或改用支持域名后端的代理 |
| 监控 | 无 | 接入云监控，对端口存活与转发规则告警 |
| 桶策略 | 仅私有 ACL | 叠加桶策略，限制仅允许来自指定终端节点的请求 |
| 登录方式 | 初始密码由变量注入 | 改用密钥对，禁用密码登录 |

> 访问方都在同一 VPC 内时，**不要**为「看起来更完整」而部署路径二——直接把 `enable_interface_path` 置为 `false` 即可。

---

## 12. 依赖

- [Terraform](https://www.terraform.io/) ≥ 1.3.0 与 [huaweicloud provider](https://registry.terraform.io/providers/huaweicloud/huaweicloud/latest) ≥ 1.60.0
- 实践架构参考华为云官方文档：VPC 终端节点（VPCEP）、对象存储服务（OBS）、统一身份认证（IAM 委托）

---

## 13. FAQ / 故障排除

**Q：`obs-check` 卡住直到超时（不是报错）？** 多发生在路径二，按顺序查：
| 检查项 | 命令 / 位置 |
|---|---|
| 转发目标解析出来了吗 | 登录 `obsep-relay`，`cat /var/lib/obs-relay/target`（空说明内置 DNS 没通） |
| 转发规则在不在 | `iptables -t nat -L OBS_RELAY -n`（应有一条 DNAT） |
| 源/目的检查关了吗 | 控制台 → 云服务器 → 网卡 → 源/目的检查（开着会静默丢包） |
| 安全组放通 198.19.128.0/17 了吗 | 控制台 → 安全组 `obsep-proxy-sg` |
| 终端节点状态 | 控制台 → VPC 终端节点（应为「已接受」） |

**Q：Plan 报 `no gateway-type OBS endpoint service`？** 当前区域未开放网关型对象存储终端节点服务，换一个已开放区域（默认 `cn-south-1`）或修改 `var.region`。

**Q：Apply 报 `unexpected state 'failed'` 且 `last error: %!s(<nil>)`？** 这是网关型终端节点创建后华为云后端路由注入失败（进入 `failed`）。在 cn-south-1 当前账号下属账号/区域级限制，非配置缺陷。已将路径一设为可选（`enable_gateway_path` 默认 `false`），部署以路径二为主；要启用路径一，设 `enable_gateway_path = true` 重试，仍失败则提工单或维持路径二。

**Q：客户端取凭据报 403？** 委托权限授在了 `project_role` 而非 `domain_roles`，对象存储是全局服务，必须授在 domain 级。

**Q：`obs-check` 命令不存在？** 初始化脚本尚未跑完，等约 1 分钟，或看 `journalctl -t obs-demo`。

---

## 14. 贡献指南

欢迎通过 Issue / Pull Request 提出改进。提交前请运行 `terraform fmt` 与 `terraform validate`，并确保不引入任何公网出口（除非显式说明）。

---

## 15. 许可证

本实践采用 **MIT No Attribution** 许可证，详见仓库根目录 [`LICENSE`](LICENSE) 文件。


本实践以 [MIT 许可证](LICENSE) 开源。

---

## 16. 联系方式 / 维护者
| 项 | 内容 |
|---|---|
| **创建者** | [dgc-git](https://github.com/dgc-git) |
| **维护者** | [dgc-git](https://github.com/dgc-git) |
| **联系方式** | GitHub Issues / PR（见[第 14 节](#14-贡献指南)） |
