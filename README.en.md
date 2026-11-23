# distributed-x-infrastructure-private-obs-access

<img src="https://img.shields.io/badge/License-MIT--0-blue.svg" alt="License">
![License](https://img.shields.io/badge/license-MIT-green)
![Huawei Cloud](https://img.shields.io/badge/cloud-Huawei%20Cloud-orange)
![Build](https://img.shields.io/badge/terraform-validate%20passed-blue)

## 1. Overview

### Introduction

This practice demonstrates how to let an ECS read from and write to Object Storage Service (OBS) securely from a private subnet **with no public egress**: no EIP is bound, no NAT gateway is attached, and the route table has no route to the public network.

It presents two comparable private access paths and explains their implementation and access control in detail:

- **Path 1 · gateway-type endpoint**: the cloud platform injects a route directly to the OBS private network into the route table; access is limited to this VPC.
- **Path 2 · interface-type endpoint**: a fixed private NIC is placed in the subnet, consumable across VPCs / accounts, with a kernel layer-4 forwarding node handling traffic.

Target users: architects and operations staff who need to bring object storage inside the cloud private network for compliance or security reasons and want to understand the differences between the two endpoint types.

---

## 2. Table of Contents

- [1. Overview](#1-overview)
- [2. Table of Contents](#2-table-of-contents)
- [3. Architecture Diagram](#3-architecture-diagram)
- [4. Highlights](#4-highlights)
- [5. Cloud Services Used](#5-cloud-services-used)
- [6. Prerequisites](#6-prerequisites)
- [7. Quick Start](#7-quick-start)
- [8. Step-by-Step Deployment](#8-step-by-step-deployment)
- [9. Usage / Verification](#9-usage--verification)
- [10. Cleanup](#10-cleanup)
- [11. Detailed Explanation](#11-detailed-explanation)
- [12. Dependencies](#12-dependencies)
- [13. FAQ / Troubleshooting](#13-faq--troubleshooting)
- [14. Contributing](#14-contributing)
- [15. License](#15-license)
- [16. Contact / Maintainers](#16-contact--maintainers)

---

## 3. Architecture Diagram

```mermaid
flowchart TB
subgraph VPC["Virtual Private Cloud 10.1.0.0/16 · default route table"]
direction TB
subgraph SN["Business subnet 10.1.1.0/24 · no EIP · no NAT"]
C["Client ECS<br/>10.1.1.10 · agency bound"]
IE["Interface-type endpoint<br/>10.1.1.100"]
R["Forwarding node ECS<br/>10.1.1.20 · layer-4 forwarding"]
C -->|Path 1| GW
C -.->|Path 2 edit hosts| IE
IE -. Source address implemented as 198.19.128.0/17 .-> R
end
end
GW["Gateway-type endpoint<br/>route injection · direct"]
R -->|Path 1| GW
GW --> OBS["Object Storage Service OBS (private address)"]
```

- **Path 1**: client → gateway-type endpoint → object storage (direct).
- **Path 2**: client → interface-type endpoint → forwarding node → gateway-type endpoint → object storage.

---

## 4. Highlights

- **Zero public egress**: no NAT gateway and no EIP are created, keeping object storage access entirely inside the cloud private network.
- **Two comparable types**: the same code provides both gateway-type and interface-type paths, making selection differences easy to understand.
- **Forwarding node with no external dependencies**: path 2 forwarding is done by kernel netfilter with no software packages installed — the subnet has no egress, so packages cannot be installed anyway, which also verifies that "there really is no public egress".
- **No long-term keys**: the client ECS obtains temporary credentials from instance metadata through an agency, with automatic rotation.
- **Built-in regional availability check**: if no gateway-type OBS endpoint service is found in the current region, `terraform plan` stops immediately with a reason in Chinese.
- **Lean network**: no NAT / EIP / load balancer is created.

---

## 5. Cloud Services Used

This practice uses the following Huawei Cloud services:

| Service | Purpose |
|---|---|
| VPC | Private subnet (no NAT/EIP) |
| ECS (Elastic Cloud Server) | Client / path-2 forwarding node |
| OBS (Object Storage Service) | Demo bucket and objects |
| VPC Endpoint (VPCEP) | Gateway-type + interface-type access paths |
| IAM (Agency) | Instance agency granting temporary OBS credentials |

> ⚠️ **Known limitation (found at runtime)**: creating path 1 (gateway-type endpoint) under the current account in `cn-south-1` fails — the Huawei Cloud backend fails to inject the route for the OBS gateway-type endpoint of this account, the endpoint enters `failed` with no clear error message. This is an **account/region-level limitation, not a configuration defect**. Therefore `enable_gateway_path` defaults to `false` and **path 2 (interface-type relay)** is the primary, verified deployment. To enable path 1, set `enable_gateway_path = true` and retry; if it still fails, keep path 2 or open a ticket with Huawei Cloud operations. See "IV. Known Environment Limitations".

---

## 6. Prerequisites

| Item | Requirement |
|---|---|
| Terraform | >= 1.3.0 (validated with 1.9.8 in this practice) |
| Account permissions | Administrator permissions are required to create an agency |
| Region | The region has the **gateway-type** OBS endpoint service available (default `cn-south-1`) |
| Quotas | At least 2 ECS instances, 1 VPC, 2 security groups, 2 endpoints |
| Credentials | Huawei Cloud AK / SK; **never write them into any file**, provide them only through environment variables |

---

## 7. Quick Start

```bash
# 1) Configure access keys AK/SK (environment variables only, never write to files)
export HW_ACCESS_KEY=<HW_ACCESS_KEY>
export HW_SECRET_KEY=<HW_SECRET_KEY>
export HW_REGION_NAME=cn-south-1
export TF_VAR_ecs_admin_password='<YOUR_PASSWORD>' # 8–26 characters, with at least three of uppercase/lowercase/digits/special characters

# 2) Deploy
cd infra
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# 3) Log in to the client (console remote VNC login, user root, password set above), then verify:
obs-check
```

> ⚠️ The environment variable names are `HW_ACCESS_KEY` / `HW_SECRET_KEY`, **not** `HW_ACCESS_KEY_ID` / `HW_SECRET_ACCESS_KEY`. If the names are wrong, the Provider does not report "credentials missing"; instead it falls back to querying instance metadata at `169.254.169.254` and reports an unintelligible 502.

---

## 8. Step-by-Step Deployment

1. **Prepare credentials** (see [Section 7](#7-quick-start)). Before `terraform plan`, check the flavor to make sure it matches the defaults:
```bash
terraform show tfplan | grep -E "flavor_id|system_disk_type|system_disk_size"
```
Only `s6.small.1` / `SAS` / `40` should appear.

2. **Create resources**: `terraform apply tfplan`, which takes about 3–5 minutes.

3. **Confirm key outputs**:
```
bucket_host = "obsep-demo-xxxxxxxx.obs.cn-south-1.myhuaweicloud.com"
client_private_ip = "10.1.1.10"
gateway_endpoint_service_name = "com.myhuaweicloud.cn-south-1.obs"
interface_endpoint_ip = "10.1.1.100"
verify_command = "obs-check"
```

4. **Log in to the client**: console → Elastic Cloud Server → `obsep-client` → Remote Login (CloudShell or VNC), user `root`.

---

## 9. Usage / Verification

After logging in to the client, verify **path 1 (gateway-type endpoint)**:

```bash
obs-check
```

Key points of the expected output:

```
Resolved address : 100.125.x.x # private address, not public
Active path : Path 1 · gateway-type endpoint (route injection, direct)
Temporary credential acquisition : successful (issued by the agency, automatically rotated within validity)
HTTP status code : 200
Peer address : 100.125.x.x
--- Object content ---
Reached the bucket without leaving the private network.
Public network unreachable, as expected.
```

**Verify that the endpoint policy takes effect** (the policy allows reads only; writes should be blocked):

```bash
. /etc/obs-demo/env
curl -sS -X PUT -d "test" -o /dev/null -w "%{http_code}\n" "https://$BUCKET_HOST/write-test.txt"
# Expected: 403
```

**Verify path 2 (interface-type endpoint)**:

```bash
sed -i 's/^#10\.1\.1\.100/10.1.1.100/' /etc/hosts
obs-check
# The resolved address becomes 10.1.1.100, the peer address becomes 10.1.1.100, HTTP is still 200, no certificate error
# Switch back to path 1:
sed -i 's/^10\.1\.1\.100/#10.1.1.100/' /etc/hosts
```

After deployment, follow these steps to verify that the business functionality works before considering the delivery complete.

---

## 10. Cleanup

```bash
cd infra
terraform destroy
```

The bucket has `force_destroy = true`, so objects in it are deleted as well; destroy will not fail due to a "bucket not empty" error and leave leftover resources. After completion, confirm in the console that the ECS instances, disks, VPC endpoints, and object storage have all been released.

---

## 11. Detailed Explanation

### 11.1 Why no custom route table is needed

The VPC default route table contains only local routes, so subnets are private by default. When a gateway-type endpoint is created without specifying `routetables`, the cloud platform injects the route into the default route table. This practice deliberately does not create a custom route table — custom route tables are quota-limited and require a ticket to enable, offering no extra benefit in this scenario.

### 11.2 Gateway-type endpoint policy

The policy and the agency permissions are **intersected**: the agency grants read/write, but write operations through this endpoint are blocked by the policy (see the 403 verification in Section 9).

### 11.3 Why path 2 needs a forwarding node

Object storage provides only **gateway-type** endpoints in the preset public endpoint service; there is no interface type. To obtain the form with "a fixed private address + consumable across VPCs", an ECS must be published as an interface-type endpoint service (layer-4 forwarding, without TLS termination; the certificate is presented by object storage, and `enable_dns` is set to `false`).

### 11.4 Two network details to remember

- **Source/destination check must be disabled on the forwarding node NIC** (`source_dest_check = false`), otherwise packets are silently dropped at the NIC layer and connections time out with no logs.
- **The forwarding node security group must allow `198.19.128.0/17`** (the source address is implemented as this network when the endpoint forwards traffic); and **the VPC CIDR must not overlap with this network**.

### 11.5 Permission design

The client ECS has no long-term key; it is bound to an agency and obtains temporary credentials through instance metadata. Object storage is a **global service**, so permissions must be granted at the domain level (`domain_roles = ["OBS OperateAccess"]`); granting them via `project_role` results in a 403 at runtime.

### 11.6 Remote access

Neither the client nor the forwarding node has a public address; login uses the console "Remote Login (VNC)", which goes through the management plane and does not traverse the VPC network, so no endpoints / security group rules need to be opened for them.

### 11.7 Applicability Boundaries

| Item | This Practice | Production Recommendation |
|---|---|---|
| Forwarding node availability | A single ECS | Multiple ECS instances + a shared load balancer as the endpoint service backend (`server_type = LB`) |
| Forwarding target convergence | Timer re-resolves every 5 minutes | Shorten the interval or use a proxy that supports domain-name backends |
| Monitoring | None | Integrate Cloud Eye and set alarms on port liveness and forwarding rules |
| Bucket policy | Private ACL only | Add a bucket policy restricting requests to those from specified endpoints |
| Login method | Initial password injected by a variable | Switch to a key pair and disable password login |

> When all accessing parties are in the same VPC, **do not** deploy path 2 just "to look more complete" — simply set `enable_interface_path` to `false`.

---

## 12. Dependencies

- [Terraform](https://www.terraform.io/) >= 1.3.0 and [huaweicloud provider](https://registry.terraform.io/providers/huaweicloud/huaweicloud/latest) >= 1.60.0
- Architecture references from official Huawei Cloud documentation: VPC Endpoint (VPCEP), Object Storage Service (OBS), Identity and Access Management (IAM agency)

---

## 13. FAQ / Troubleshooting

**Q: `obs-check` hangs until timeout (not an error)?** This happens mostly on path 2; check in order:
| Check Item | Command / Location |
|---|---|
| Is the forwarding target resolved? | Log in to `obsep-relay`, `cat /var/lib/obs-relay/target` (empty means the built-in DNS did not work) |
| Is the forwarding rule present? | `iptables -t nat -L OBS_RELAY -n` (there should be one DNAT rule) |
| Is source/destination check disabled? | Console → ECS → NIC → Source/Destination Check (enabled means silent packet loss) |
| Is `198.19.128.0/17` allowed in the security group? | Console → security group `obsep-proxy-sg` |
| Endpoint status | Console → VPC Endpoint (should be "Accepted") |

**Q: Plan reports `no gateway-type OBS endpoint service`?** The current region does not have the gateway-type OBS endpoint service available; switch to a region where it is available (default `cn-south-1`) or change `var.region`.

**Q: Apply reports `unexpected state 'failed'` with `last error: %!s(<nil>)`?** The Huawei Cloud backend failed to inject the route after the gateway-type endpoint was created (entering `failed`). Under the current account in `cn-south-1` this is an account/region-level limitation, not a configuration defect. Path 1 has been made optional (`enable_gateway_path` defaults to `false`), with path 2 as the primary deployment; to enable path 1, set `enable_gateway_path = true` and retry; if it still fails, open a ticket or keep path 2.

**Q: The client reports 403 when obtaining credentials?** The agency permissions were granted via `project_role` instead of `domain_roles`; object storage is a global service and must be granted at the domain level.

**Q: The `obs-check` command does not exist?** The initialization script has not finished yet; wait about 1 minute, or check `journalctl -t obs-demo`.

---

## 14. Contributing

Improvements via Issues / Pull Requests are welcome. Before submitting, run `terraform fmt` and `terraform validate`, and make sure no public egress is introduced (unless explicitly stated).

---

## 15. License

This practice is licensed under the **MIT No Attribution** license. See the [`LICENSE`](LICENSE) file in the repository root for details.

This practice is released under the [MIT license](LICENSE).

---

## 16. Contact / Maintainers
| Item | Content |
|---|---|
| **Creator** | [dgc-git](https://github.com/dgc-git) |
| **Maintainer** | [dgc-git](https://github.com/dgc-git) |
| **Contact** | GitHub Issues / PR (see [Section 14](#14-contributing)) |
