# 部署指南

## 1. 部署前须知

> 部署前请确认目标区域具备所需云服务配额与权限。

**部署完成后请按 docs/ 第 8 节执行 `terraform destroy` 并确认无残留资源。**

## 2. 前提条件

| 项 | 要求 |
|---|---|
| Terraform | ≥ 1.3.0 |
| 账号权限 | 创建委托需要管理员权限 |
| 区域 | 该区域已开放**网关型**的对象存储终端节点服务。默认 `cn-south-1` |
| 配额 | 至少 2 台云服务器、1 个 VPC、2 个安全组、2 个终端节点 |

代码里已经内置了区域可用性校验：如果当前区域查不到网关型的对象存储终端节点服务
`terraform plan` 会直接以可读的中文原因中断，不会等到 apply 才报底层错误。

> **路径一（网关型终端节点）默认关闭**（`enable_gateway_path = false`）。
> 在 cn-south-1 的当前账号下，该终端节点的路由注入会在华为云端失败、进入 `failed`
> 属账号/区域级限制，非配置缺陷。路径二是默认验证路径；如需启用路径一
> 先把 `enable_gateway_path = true` 试一次，仍 failed 则维持路径二或提工单。

## 3. 配置访问密钥

凭据只从环境变量注入，不写进任何文件。

```bash
export HW_ACCESS_KEY=<HW_ACCESS_KEY>
export HW_SECRET_KEY=<HW_SECRET_KEY>
export HW_REGION_NAME=cn-south-1

# 云服务器初始密码，仅用于控制台远程登录
export TF_VAR_ecs_admin_password='<YOUR_PASSWORD>'
```

> 环境变量名是 `HW_ACCESS_KEY` / `HW_SECRET_KEY`，**不是** `HW_ACCESS_KEY_ID` /
> `HW_SECRET_ACCESS_KEY`。名字写错时 Provider 不会报「凭据缺失」
> 而是退化去查实例元数据 `169.254.169.254`，报一个看不懂的 502。

密码需满足复杂度要求：8–26 位，包含大写字母、小写字母、数字、特殊字符中的至少三类。

## 4. 部署

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars # 按需修改

terraform init
terraform plan -out=tfplan
```

**看一眼 plan 输出里的规格字段再继续**：

```bash
terraform show tfplan | grep -E "flavor_id|system_disk_type|system_disk_size"
```

应当只出现 `s6.small.1` / `SAS` / `40`。出现其他值说明 tfvars 改动带来了规格变化
请重新核对配置与配额是否满足需求。

确认无误后：

```bash
terraform apply tfplan
```

约 3–5 分钟完成。输出示例：

```
bucket_host = "obsep-demo-a1b2c3d4.obs.cn-south-1.myhuaweicloud.com"
bucket_name = "obsep-demo-a1b2c3d4"
client_instance_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
client_private_ip = "10.1.1.10"
gateway_endpoint_id = null # 仅当 enable_gateway_path = true 时有值
gateway_endpoint_service_name = null # 仅当 enable_gateway_path = true 时有值
interface_endpoint_ip = "10.1.1.100"
interface_endpoint_service_name = "cn-south-1.obsep-obs.xxxxxxxx-...."
relay_instance_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
verify_command = "obs-check"
```

> 默认 `enable_gateway_path = false`，所以 `gateway_endpoint_id` / `gateway_endpoint_service_name`
> 输出为 `null`。把该变量设为 `true` 且账号支持时，这两个输出才会有值。

## 5. 登录客户端

客户端没有公网地址，也没有跳板机。用控制台的远程登录：

1. 控制台 → 弹性云服务器 → 找到 `obsep-client`
2. 点「远程登录」→「CloudShell 登录」或「其他方式 · VNC」
3. 用户名 `root`，密码是 `TF_VAR_ecs_admin_password` 设置的值

这条通道走管理面，不经过 VPC 网络，所以不需要弹性公网 IP
也不需要为它开任何安全组规则。

> 首次登录如果 `obs-check` 命令不存在，说明初始化脚本还没跑完
> 等 1 分钟，或看 `journalctl -t obs-demo`。

## 6. 验证路径一（网关型终端节点）

> **前置**：`enable_gateway_path = true` 且账号具备该能力。默认关闭，因为 cn-south-1 当前账号下
> 该终端节点创建会失败（详见 「四、已知环境限制」）。
> 若未开启或创建 failed，本节可跳过，直接看路径二。

```bash
obs-check
```

预期输出：

```
桶域名 : obsep-demo-a1b2c3d4.obs.cn-south-1.myhuaweicloud.com
当前解析地址 : 100.125.x.x
生效路径 : 路径一 · 网关型终端节点（路由注入，直达）

--- 实例委托 ---
临时凭据获取 : 成功（由委托下发，有效期内自动轮换）

--- 取一次对象 ---
HTTP 状态码 : 200
对端地址 : 100.125.x.x
--- 对象内容 ---
Reached the bucket without leaving the private network.

--- 确认没有公网出口 ---
公网不可达，符合预期。
```

三个要点：

- **解析地址是 `100.125.x.x`** —— 内网地址，不是公网地址。这是内置 DNS 的功劳。
- **公网不可达** —— 证明这台机器确实没有出口，对象存储是经终端节点访问到的。
- **HTTP 200** —— 委托下发的临时凭据生效了。

### 验证终端节点策略生效

> 本节仅在 `enable_gateway_policy = true` 时才有意义（且该区域 OBS 网关服务的
> `enable_policy` 必须为 `true`，否则策略根本传不进去、终端节点会 failed）。
> 默认 `enable_gateway_policy = false`，所以默认不会演示策略拦截。

网关型终端节点的策略只放通了读取。试一次写入：

```bash
. /etc/obs-demo/env
curl -sS -X PUT -d "test" -o /dev/null -w "%{http_code}\n" \
"https://$BUCKET_HOST/write-test.txt"
```

预期返回 **403**。委托本身有写权限，是终端节点策略把它拦下的 —— 两者取交集。

## 7. 验证路径二（接口型终端节点）

> 这是**默认验证路径**：路径一在当前账号受限，路径二是完整可用的替代。

切换只需要改一行 hosts：

```bash
sed -i 's/^#10\.1\.1\.100/10.1.1.100/' /etc/hosts
obs-check
```

预期输出的差异：

```
当前解析地址 : 10.1.1.100
生效路径 : 路径二 · 接口型终端节点（经转发节点中转）
...
HTTP 状态码 : 200
对端地址 : 10.1.1.100
```

**对象内容与状态码完全一致，对端地址变了。** 这说明报文确实换了一条路：
客户端 → 接口型终端节点 → 转发节点 → 对象存储。

注意此时**没有出现证书错误**。因为转发节点做的是四层转发
客户端用的仍是对象存储的原始域名，证书由对象存储自己出示。

切回路径一：

```bash
sed -i 's/^10\.1\.1\.100/#10.1.1.100/' /etc/hosts
```

### 路径二排障

如果 `obs-check` 卡住直到超时（不是报错，是卡住），按顺序查：

| 检查项 | 命令 / 位置 | 说明 |
|---|---|---|
| 转发节点的转发目标解析出来了吗 | 登录 `obsep-relay`，`cat /var/lib/obs-relay/target` | 空文件说明内置 DNS 没通 |
| 转发规则在不在 | `iptables -t nat -L OBS_RELAY -n` | 应有一条 DNAT |
| 网卡源/目的检查关了吗 | 控制台 → 云服务器 → 网卡 → 源/目的检查 | 开着会静默丢包，是超时的最常见原因 |
| 安全组放通 `198.19.128.0/17` 了吗 | 控制台 → 安全组 `obsep-proxy-sg` | 终端节点转发时会把源地址改写成这个网段 |
| 终端节点状态 | 控制台 → VPC 终端节点 | 应为「已接受」 |

## 8. 回收

```bash
terraform destroy
```

桶设了 `force_destroy = true`，桶内对象会一并删除，不会因为「桶非空」导致
destroy 失败而留下残留资源。

destroy 完成后，到控制台确认这几类资源均已释放：
弹性云服务器、云硬盘、VPC 终端节点、对象存储。
