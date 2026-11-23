output "region" {
  description = "部署区域。"
  value       = var.region
}

output "bucket_name" {
  description = "演示桶名称。"
  value       = huaweicloud_obs_bucket.demo.bucket
}

output "bucket_host" {
  description = "桶的内网访问域名。两条路径都用这个域名，区别只在它解析到哪里。"
  value       = local.obs_bucket_domain
}

output "client_instance_id" {
  description = "客户端云服务器 ID。在控制台用「远程登录」进入，执行 obs-check 验证。"
  value       = huaweicloud_compute_instance.client.id
}

output "client_private_ip" {
  description = "客户端云服务器内网地址。"
  value       = var.client_private_ip
}

output "gateway_endpoint_id" {
  description = "网关型终端节点 ID（路径一）；未启用时为空。"
  value       = var.enable_gateway_path ? huaweicloud_vpcep_endpoint.obs_gateway[0].id : null
}

output "gateway_endpoint_service_name" {
  description = "所引用的网关型终端节点服务名称；未启用时为空。"
  value       = var.enable_gateway_path ? huaweicloud_vpcep_endpoint.obs_gateway[0].service_name : null
}

output "interface_endpoint_ip" {
  description = <<-EOT
    接口型终端节点的内网地址（路径二）。
    在客户端把桶域名指向这个地址，即可切换到路径二。
  EOT
  value       = var.enable_interface_path ? var.endpoint_ip : null
}

output "interface_endpoint_service_name" {
  description = "自建的接口型终端节点服务名称，可供其他 VPC 或账号按名称查找并连接。"
  value       = var.enable_interface_path ? huaweicloud_vpcep_service.obs_relay[0].service_name : null
}

output "relay_instance_id" {
  description = "转发节点云服务器 ID（路径二的后端）。"
  value       = var.enable_interface_path ? huaweicloud_compute_instance.relay[0].id : null
}

output "verify_command" {
  description = "登录客户端后执行的验证命令。"
  value       = "obs-check"
}
